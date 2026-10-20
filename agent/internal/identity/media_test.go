package identity

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

// Fake machine for the media scan: a sysfs block tree, a dev tree of plain
// files, a mountinfo file and an injectable mount function that "mounts" a
// fixture directory by copying it. Nothing here touches a real block device or
// a real system path.

type fakeDisk struct {
	removable bool
	usb       bool     // the sysfs device path runs through a usbN hub, whatever the flags say
	parts     []string // partition names; empty means the whole device is the candidate
}

type fakeMedia struct {
	fs    string            // the only filesystem type that mounts
	files map[string]string // relative path -> content
	links map[string]string // relative path -> symlink target
}

type mountCall struct{ dev, fstype, opts, data string }

type fakeMachine struct {
	t               *testing.T
	root            string
	mu              sync.Mutex
	media           map[string]fakeMedia // device name -> content
	calls           []mountCall
	unmounts        []string
	detaches        []bool
	sniffs          []string
	events          []string // "ro:<dev>" / "mount:<dev>" in call order
	logs            []string
	unmountErrFirst bool // first non-detach unmount fails
	gateDevs        map[string]chan struct{}
	gate            chan struct{} // when set, Mount blocks until closed and IGNORES ctx (a wedged syscall)
	roErr           error
}

func newFakeMachine(t *testing.T) *fakeMachine {
	t.Helper()
	m := &fakeMachine{t: t, root: t.TempDir(), media: map[string]fakeMedia{}}
	for _, d := range []string{"sys/block", "dev/disk/by-label", "run"} {
		if err := os.MkdirAll(filepath.Join(m.root, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	m.writeMountInfo()
	return m
}

func (m *fakeMachine) path(rel ...string) string {
	return filepath.Join(append([]string{m.root}, rel...)...)
}

func (m *fakeMachine) addDisk(name string, d fakeDisk) {
	m.t.Helper()
	dir := m.path("sys/block", name)
	if d.usb {
		real := m.path("sys/devices/pci0000:00/usb1/1-1/block", name)
		if err := os.MkdirAll(real, 0o755); err != nil {
			m.t.Fatal(err)
		}
		if err := os.Symlink(real, dir); err != nil {
			m.t.Fatal(err)
		}
	} else if err := os.MkdirAll(dir, 0o755); err != nil {
		m.t.Fatal(err)
	}
	rem := "0\n"
	if d.removable {
		rem = "1\n"
	}
	m.write(filepath.Join(dir, "removable"), rem)
	m.write(m.path("dev", name), "")
	for _, p := range d.parts {
		if err := os.MkdirAll(filepath.Join(dir, p), 0o755); err != nil {
			m.t.Fatal(err)
		}
		m.write(filepath.Join(dir, p, "partition"), "1\n")
		m.write(m.path("dev", p), "")
	}
}

func (m *fakeMachine) label(label, dev string) {
	m.t.Helper()
	if err := os.Symlink("../../"+dev, m.path("dev/disk/by-label", label)); err != nil {
		m.t.Fatal(err)
	}
}

func (m *fakeMachine) write(p, content string) {
	m.t.Helper()
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		m.t.Fatal(err)
	}
}

func (m *fakeMachine) writeMountInfo(mounts ...string) {
	var b strings.Builder
	b.WriteString("22 1 0:21 / /proc rw - proc proc rw\n")
	for i, src := range mounts {
		b.WriteString("3" + string(rune('0'+i)) + " 1 8:1 / /mnt" + string(rune('0'+i)) + " rw - ext4 " + src + " rw\n")
	}
	m.write(m.path("proc-mountinfo"), b.String())
}

func (m *fakeMachine) mount(ctx context.Context, src, target, fstype, opts, data string) error {
	if m.gate != nil {
		<-m.gate
	}
	dev := filepath.Base(src)
	if ch, ok := m.gateDevs[dev]; ok {
		<-ch
	}
	m.mu.Lock()
	m.calls = append(m.calls, mountCall{dev, fstype, opts, data})
	m.events = append(m.events, "mount:"+dev)
	med, ok := m.media[dev]
	m.mu.Unlock()
	if !ok || med.fs != fstype {
		return errors.New("wrong fs type")
	}
	for rel, content := range med.files {
		p := filepath.Join(target, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
			return err
		}
	}
	for rel, to := range med.links {
		p := filepath.Join(target, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			return err
		}
		if err := os.Symlink(to, p); err != nil {
			return err
		}
	}
	return nil
}

func (m *fakeMachine) unmount(target string, detach bool) error {
	m.mu.Lock()
	m.unmounts = append(m.unmounts, target)
	m.detaches = append(m.detaches, detach)
	m.events = append(m.events, fmt.Sprintf("unmount:detach=%v", detach))
	fail := m.unmountErrFirst && !detach
	m.mu.Unlock()
	if fail {
		return errors.New("busy")
	}
	return os.RemoveAll(target) // the fake "media" lives in the dir
}

func (m *fakeMachine) sniff(dev string) string {
	name := filepath.Base(dev)
	m.mu.Lock()
	defer m.mu.Unlock()
	m.sniffs = append(m.sniffs, name)
	return m.media[name].fs
}

func (m *fakeMachine) setRO(dev string) (func() error, error) {
	name := filepath.Base(dev)
	m.mu.Lock()
	defer m.mu.Unlock()
	m.events = append(m.events, "ro:"+name)
	if m.roErr != nil {
		return nil, m.roErr
	}
	return func() error {
		m.mu.Lock()
		defer m.mu.Unlock()
		m.events = append(m.events, "restore:"+name)
		return nil
	}, nil
}

func (m *fakeMachine) strategy(known ...string) *MediaScanStrategy {
	return &MediaScanStrategy{
		SysBlock:    m.path("sys/block"),
		DevRoot:     m.path("dev"),
		MountInfo:   m.path("proc-mountinfo"),
		MountRoot:   m.path("run/media"),
		StagePath:   m.path("run/powernode/identity.cfg"),
		Budget:      5 * time.Second,
		EnumWait:    -1,
		KnownIDs:    func(context.Context) []string { return known },
		Settle:      func(context.Context, time.Duration) {},
		Mount:       m.mount,
		Unmount:     m.unmount,
		Sniff:       m.sniff,
		SetReadOnly: m.setRO,
		Enrolled:    func() bool { return false },
		Logf: func(f string, a ...any) {
			m.mu.Lock()
			m.logs = append(m.logs, strings.TrimSpace(fmt.Sprintf(f, a...)))
			m.mu.Unlock()
		},
	}
}

func (m *fakeMachine) devOrder() []string { return append([]string(nil), m.sniffs...) }

const (
	idA = "0198f3a2-7b1c-7d2e-9a4f-1234567890ab"
	idB = "0198f3a2-7b1c-7d2e-9a4f-1234567890cd"
)

func docFor(pki testPKI, id, issued string) string {
	return v1Doc(pki, func(d map[string]any) {
		d["instance_id"] = id
		d["issued_at"] = issued
		d["expires_at"] = "2030-01-01T00:00:00Z"
	})
}

func vfatWith(content string) fakeMedia {
	return fakeMedia{fs: "vfat", files: map[string]string{"powernode-provision.cfg": content}}
}

func TestMediaScanProbeOrderAndRootExclusion(t *testing.T) {
	m := newFakeMachine(t)
	m.addDisk("sda", fakeDisk{removable: true, parts: []string{"sda1", "sda2"}}) // root, even though removable
	m.addDisk("sdb", fakeDisk{removable: true, parts: []string{"sdb1"}})         // USB stick
	m.addDisk("sdc", fakeDisk{})                                                 // extra disk
	m.addDisk("sdd", fakeDisk{parts: []string{"sdd1"}})                          // cidata labelled
	m.addDisk("sr0", fakeDisk{removable: true})                                  // optical
	m.addDisk("sde", fakeDisk{parts: []string{"sde1"}})                          // BOOT partition of the image
	m.addDisk("loop0", fakeDisk{removable: true})
	m.addDisk("ram0", fakeDisk{})
	m.label("cidata", "sdd1")
	m.label("BOOT", "sde1")
	m.writeMountInfo("/dev/sda2")
	_, err := m.strategy().Discover(context.Background())
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("want ErrNotFound, got %v", err)
	}
	want := []string{"sdd1", "sr0", "sdc", "sdb1"} // fixed media first, USB last
	if got := m.devOrder(); !reflect.DeepEqual(got, want) {
		t.Fatalf("probe order = %v, want %v", got, want)
	}
}

func TestMediaScanMountsOnceWithTheSniffedTypeAndFlags(t *testing.T) {
	for fs, wantData := range map[string]string{"vfat": "", "exfat": "", "iso9660": "", "ext4": "noload"} {
		m := newFakeMachine(t)
		m.addDisk("sdb", fakeDisk{removable: true, parts: []string{"sdb1"}})
		m.media["sdb1"] = fakeMedia{fs: fs}
		if _, err := m.strategy().Discover(context.Background()); !errors.Is(err, ErrNotFound) {
			t.Fatalf("%s: got %v", fs, err)
		}
		if len(m.calls) != 1 {
			t.Fatalf("%s: want exactly one mount, got %v", fs, m.calls)
		}
		c := m.calls[0]
		if c.fstype != fs || c.opts != "ro,nosuid,nodev,noexec" || c.data != wantData {
			t.Fatalf("%s: mount = %+v", fs, c)
		}
	}
}

func TestMediaScanReadsRootFileThenFallbackPath(t *testing.T) {
	pki := newTestPKI(t)
	for name, files := range map[string]map[string]string{
		"root":     {"powernode-provision.cfg": docFor(pki, idA, "2026-10-20T10:00:00Z")},
		"fallback": {"powernode/provision.cfg": docFor(pki, idA, "2026-10-20T10:00:00Z")},
	} {
		m := newFakeMachine(t)
		m.addDisk("sdb", fakeDisk{removable: true, parts: []string{"sdb1"}})
		m.media["sdb1"] = fakeMedia{fs: "exfat", files: files}
		id, err := m.strategy().Discover(context.Background())
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if id.InstanceUUID != idA || id.BootstrapToken != testKey || id.CAFingerprint != pki.caFP || id.CloudProvider != "media-scan" {
			t.Fatalf("%s: identity %+v", name, id)
		}
	}
}

func TestMediaScanPrefersKnownInstanceID(t *testing.T) {
	pki := newTestPKI(t)
	m := newFakeMachine(t)
	m.addDisk("sdb", fakeDisk{removable: true, parts: []string{"sdb1"}})
	m.addDisk("sdc", fakeDisk{removable: true, parts: []string{"sdc1"}})
	m.media["sdb1"] = vfatWith(docFor(pki, idA, "2026-10-20T09:00:00Z"))
	m.media["sdc1"] = vfatWith(docFor(pki, idB, "2026-10-20T10:00:00Z")) // newer, but not the known one
	id, err := m.strategy(strings.ToUpper(idA)).Discover(context.Background())
	if err != nil || id.InstanceUUID != idA {
		t.Fatalf("id=%+v err=%v", id, err)
	}
}

func TestMediaScanPrefersNewestIssuedAtWithoutKnownMatch(t *testing.T) {
	pki := newTestPKI(t)
	m := newFakeMachine(t)
	m.addDisk("sdb", fakeDisk{removable: true, parts: []string{"sdb1"}})
	m.addDisk("sdc", fakeDisk{removable: true, parts: []string{"sdc1"}})
	m.media["sdb1"] = vfatWith(docFor(pki, idA, "2026-10-20T09:00:00Z"))
	m.media["sdc1"] = vfatWith(docFor(pki, idB, "2026-10-20T10:00:00+00:00"))
	id, err := m.strategy("11111111-1111-1111-1111-111111111111").Discover(context.Background())
	if err != nil || id.InstanceUUID != idB {
		t.Fatalf("id=%+v err=%v", id, err)
	}
}

func TestMediaScanRefusesAmbiguityLoggingOnlyDeviceNames(t *testing.T) {
	pki := newTestPKI(t)
	m := newFakeMachine(t)
	m.addDisk("sdb", fakeDisk{removable: true, parts: []string{"sdb1"}})
	m.addDisk("sdc", fakeDisk{removable: true, parts: []string{"sdc1"}})
	m.media["sdb1"] = vfatWith(docFor(pki, idA, "2026-10-20T10:00:00Z"))
	m.media["sdc1"] = vfatWith(docFor(pki, idB, "2026-10-20T10:00:00Z"))
	id, err := m.strategy().Discover(context.Background())
	if id != nil || !errors.Is(err, ErrProvisionRefused) {
		t.Fatalf("id=%+v err=%v", id, err)
	}
	for _, s := range append(m.logs, err.Error()) {
		for _, secret := range []string{testKey, idA, idB, "platform.example.test", pki.caFP} {
			if strings.Contains(s, secret) {
				t.Fatalf("output leaks %q: %q", secret, s)
			}
		}
	}
	if !strings.Contains(err.Error(), "sdb1") || !strings.Contains(err.Error(), "sdc1") {
		t.Fatalf("refusal should name the devices: %v", err)
	}
	if _, serr := os.Stat(m.path("run/powernode/identity.cfg")); !os.IsNotExist(serr) {
		t.Fatal("nothing may be staged on refusal")
	}
}

func TestMediaScanIdenticalDuplicatesAreNotAmbiguous(t *testing.T) {
	pki := newTestPKI(t)
	doc := docFor(pki, idA, "2026-10-20T10:00:00Z")
	m := newFakeMachine(t)
	m.addDisk("sdb", fakeDisk{removable: true, parts: []string{"sdb1"}})
	m.addDisk("sdc", fakeDisk{removable: true, parts: []string{"sdc1"}})
	m.media["sdb1"] = vfatWith(doc)
	m.media["sdc1"] = vfatWith(doc)
	if id, err := m.strategy().Discover(context.Background()); err != nil || id.InstanceUUID != idA {
		t.Fatalf("id=%+v err=%v", id, err)
	}
}

func TestMediaScanStrictRefusalIsTerminal(t *testing.T) {
	pki := newTestPKI(t)
	bad := map[string]string{
		"no pin":      v1Doc(pki, func(d map[string]any) { delete(d, "ca_fingerprint") }),
		"legacy kv":   "ID=" + idA + "\nKEY=" + testKey + "\nSERVER=https://platform.example.test\n",
		"unknown key": v1Doc(pki, func(d map[string]any) { d["extra"] = "x" }),
		"empty":       "",
	}
	for name, content := range bad {
		m := newFakeMachine(t)
		m.addDisk("sdb", fakeDisk{removable: true, parts: []string{"sdb1"}})
		m.addDisk("sdc", fakeDisk{removable: true, parts: []string{"sdc1"}})
		m.media["sdb1"] = vfatWith(content)
		m.media["sdc1"] = vfatWith(docFor(pki, idA, "2026-10-20T10:00:00Z")) // a good one must not rescue it
		s := m.strategy()
		_, err := s.Discover(context.Background())
		if !errors.Is(err, ErrProvisionRefused) {
			t.Fatalf("%s: want ErrProvisionRefused, got %v", name, err)
		}
		for _, o := range append(m.logs, err.Error()) {
			if strings.Contains(o, testKey) || strings.Contains(o, idA) {
				t.Fatalf("%s: output leaks document content: %q", name, o)
			}
		}
		// And the Resolver treats it as terminal: the next strategy never runs.
		next := &stubStrategy{id: &Identity{InstanceUUID: "fallback"}}
		r := &Resolver{Strategies: []Strategy{s, next}}
		if _, err := r.Resolve(context.Background()); !errors.Is(err, ErrProvisionRefused) || next.called {
			t.Fatalf("%s: resolver err=%v next-called=%v", name, err, next.called)
		}
	}
}

type stubStrategy struct {
	id     *Identity
	called bool
}

func (s *stubStrategy) Name() string { return "stub" }
func (s *stubStrategy) Discover(context.Context) (*Identity, error) {
	s.called = true
	return s.id, nil
}

func TestMediaScanStagesIdentityCfgAt0600AndUnmounts(t *testing.T) {
	pki := newTestPKI(t)
	doc := docFor(pki, idA, "2026-10-20T10:00:00Z")
	m := newFakeMachine(t)
	m.addDisk("sdb", fakeDisk{removable: true, parts: []string{"sdb1"}})
	m.media["sdb1"] = vfatWith(doc + "\n")
	if _, err := m.strategy().Discover(context.Background()); err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(m.path("run/powernode/identity.cfg"))
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != 0o600 {
		t.Fatalf("staged mode = %o", st.Mode().Perm())
	}
	// The staged file is what LocalIdentityStrategy reads on an agent restart.
	id, err := (&LocalIdentityStrategy{Path: m.path("run/powernode/identity.cfg")}).Discover(context.Background())
	if err != nil || id.InstanceUUID != idA || id.BootstrapToken != testKey {
		t.Fatalf("staged file does not re-parse: %+v %v", id, err)
	}
	if len(m.unmounts) != 1 {
		t.Fatalf("unmounts = %v", m.unmounts)
	}
	if _, err := os.Stat(m.unmounts[0]); !os.IsNotExist(err) {
		t.Fatal("mount point not cleaned up")
	}
}

func TestMediaScanNeverFollowsSymlinksOnTheMedia(t *testing.T) {
	pki := newTestPKI(t)
	outside := filepath.Join(t.TempDir(), "host-file")
	if err := os.WriteFile(outside, []byte(docFor(pki, idA, "2026-10-20T10:00:00Z")), 0o600); err != nil {
		t.Fatal(err)
	}
	m := newFakeMachine(t)
	m.addDisk("sdb", fakeDisk{removable: true, parts: []string{"sdb1"}})
	m.media["sdb1"] = fakeMedia{fs: "vfat", links: map[string]string{
		"powernode-provision.cfg": outside,
		"powernode":               filepath.Dir(outside),
	}}
	if _, err := m.strategy().Discover(context.Background()); !errors.Is(err, ErrNotFound) {
		t.Fatalf("symlinked file must be ignored, got %v", err)
	}
}

func TestMediaScanWaitsForLateEnumerationWithinBudget(t *testing.T) {
	pki := newTestPKI(t)
	m := newFakeMachine(t)
	s := m.strategy()
	s.EnumWait = 3 * time.Second
	s.EnumPoll = 10 * time.Millisecond
	go func() {
		time.Sleep(80 * time.Millisecond)
		m.addDisk("sdb", fakeDisk{removable: true, parts: []string{"sdb1"}})
	}()
	m.media["sdb1"] = vfatWith(docFor(pki, idA, "2026-10-20T10:00:00Z"))
	if id, err := s.Discover(context.Background()); err != nil || id.InstanceUUID != idA {
		t.Fatalf("id=%+v err=%v", id, err)
	}
}

func TestMediaScanTotalBudgetBoundsAHungMount(t *testing.T) {
	m := newFakeMachine(t)
	m.addDisk("sdb", fakeDisk{removable: true, parts: []string{"sdb1"}})
	m.media["sdb1"] = fakeMedia{fs: "vfat"}
	m.gate = make(chan struct{})
	defer close(m.gate)
	s := m.strategy()
	s.Budget = 150 * time.Millisecond
	start := time.Now()
	_, err := s.Discover(context.Background())
	if !errors.Is(err, ErrNotFound) || time.Since(start) > 2*time.Second {
		t.Fatalf("err=%v after %v", err, time.Since(start))
	}
}

func TestMediaScanSitsBeforeClaimInDefaultResolver(t *testing.T) {
	idx := func(match func(Strategy) bool) int {
		for i, s := range DefaultResolver().Strategies {
			if match(s) {
				return i
			}
		}
		return -1
	}
	media := idx(func(s Strategy) bool { _, ok := s.(*MediaScanStrategy); return ok })
	run := idx(func(s Strategy) bool {
		l, ok := s.(*LocalIdentityStrategy)
		return ok && l.Path == "/run/powernode/identity.cfg"
	})
	claim := idx(func(s Strategy) bool { _, ok := s.(*ClaimStrategy); return ok })
	if media < 0 || !(run < media && media < claim) {
		t.Fatalf("media=%d run=%d claim=%d", media, run, claim)
	}
}
