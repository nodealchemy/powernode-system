package identity

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"io"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func eventually(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

// H1 -------------------------------------------------------------------

func TestMediaScanSetsBlockDeviceReadOnlyBeforeEveryMount(t *testing.T) {
	m := newFakeMachine(t)
	m.addDisk("sdb", fakeDisk{removable: true, parts: []string{"sdb1"}})
	m.addDisk("sdc", fakeDisk{})
	m.media["sdb1"] = fakeMedia{fs: "ext4"}
	m.media["sdc"] = fakeMedia{fs: "vfat"}
	_, _ = m.strategy().Discover(context.Background())
	idx := func(ev string) int {
		for i, e := range m.events {
			if e == ev {
				return i
			}
		}
		return -1
	}
	for _, d := range []string{"sdb1", "sdc"} {
		if ro, mt := idx("ro:"+d), idx("mount:"+d); ro < 0 || mt < 0 || ro > mt {
			t.Fatalf("%s: BLKROSET must precede the mount: %v", d, m.events)
		}
	}
}

func TestMediaScanNeverMountsWhenBLKROSETFails(t *testing.T) {
	m := newFakeMachine(t)
	m.addDisk("sdb", fakeDisk{removable: true, parts: []string{"sdb1"}})
	m.media["sdb1"] = fakeMedia{fs: "ext4", files: map[string]string{"powernode-provision.cfg": "{}"}}
	m.roErr = errors.New("EPERM")
	if _, err := m.strategy().Discover(context.Background()); !errors.Is(err, ErrNotFound) {
		t.Fatalf("got %v", err)
	}
	if len(m.calls) != 0 {
		t.Fatalf("mounted a device that could not be made read-only: %v", m.calls)
	}
}

// H2 / M3 -------------------------------------------------------------

func TestMediaScanLateMountIsDetachedAfterTheBudget(t *testing.T) {
	m := newFakeMachine(t)
	m.addDisk("sdb", fakeDisk{removable: true, parts: []string{"sdb1"}})
	m.media["sdb1"] = fakeMedia{fs: "vfat"}
	m.gate = make(chan struct{}) // a mount syscall that ignores cancellation
	s := m.strategy()
	s.Budget = 100 * time.Millisecond
	if _, err := s.Discover(context.Background()); !errors.Is(err, ErrNotFound) {
		t.Fatalf("got %v", err)
	}
	m.mu.Lock()
	n := len(m.unmounts)
	m.mu.Unlock()
	if n != 0 {
		t.Fatal("nothing is mounted yet")
	}
	close(m.gate) // the wedged mount finally completes
	eventually(t, "late mount to be unmounted", func() bool {
		m.mu.Lock()
		defer m.mu.Unlock()
		return len(m.unmounts) == 1 && m.detaches[0]
	})
}

func TestMediaScanHungPostMountReadIsAbandonedAndDetached(t *testing.T) {
	m := newFakeMachine(t)
	m.addDisk("sdb", fakeDisk{removable: true, parts: []string{"sdb1"}})
	m.media["sdb1"] = vfatWith("{}")
	hang := make(chan struct{})
	s := m.strategy()
	s.Budget = 150 * time.Millisecond
	s.Read = func(string) ([]byte, bool, error) { <-hang; return nil, false, nil }
	start := time.Now()
	_, err := s.Discover(context.Background())
	if !errors.Is(err, ErrNotFound) || time.Since(start) > 2*time.Second {
		t.Fatalf("err=%v after %v", err, time.Since(start))
	}
	close(hang)
	eventually(t, "detach unmount after the read returned", func() bool {
		m.mu.Lock()
		defer m.mu.Unlock()
		return len(m.detaches) >= 1 && m.detaches[len(m.detaches)-1]
	})
}

func TestMediaScanUnmountFallsBackToDetach(t *testing.T) {
	pki := newTestPKI(t)
	m := newFakeMachine(t)
	m.addDisk("sdb", fakeDisk{removable: true, parts: []string{"sdb1"}})
	m.media["sdb1"] = vfatWith(docFor(pki, idA, "2026-10-20T10:00:00Z"))
	m.unmountErrFirst = true
	if _, err := m.strategy().Discover(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(m.detaches) != 2 || m.detaches[0] || !m.detaches[1] {
		t.Fatalf("unmount attempts (detach flags) = %v", m.detaches)
	}
}

// H3 --------------------------------------------------------------------

func TestMediaScanIsSkippedEntirelyOnAnEnrolledNode(t *testing.T) {
	pki := newTestPKI(t)
	m := newFakeMachine(t)
	m.addDisk("sdb", fakeDisk{removable: true, parts: []string{"sdb1"}})
	m.media["sdb1"] = vfatWith("garbage that would refuse") // a hostile stick
	s := m.strategy()
	s.Enrolled = func() bool { return true }
	settled := false
	s.Settle = func(context.Context, time.Duration) { settled = true }
	_ = pki
	_, err := s.Discover(context.Background())
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("an enrolled node must not be vetoed by media: %v", err)
	}
	if settled || len(m.sniffs) != 0 || len(m.events) != 0 {
		t.Fatalf("enrolled node touched devices: settled=%v sniffs=%v events=%v", settled, m.sniffs, m.events)
	}
}

func TestPKIEnrolledNeedsAUsableCertAndKey(t *testing.T) {
	dir := t.TempDir()
	if pkiEnrolled([]string{dir}) {
		t.Fatal("empty dir is not enrolled")
	}
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "n"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour)}
	der, _ := x509.CreateCertificate(rand.Reader, tpl, tpl, &key.PublicKey, key)
	kder, _ := x509.MarshalECPrivateKey(key)
	os.WriteFile(filepath.Join(dir, "node.crt"), pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644)
	if pkiEnrolled([]string{dir}) {
		t.Fatal("cert without key is not enrolled")
	}
	os.WriteFile(filepath.Join(dir, "node.key"), pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: kder}), 0o600)
	if !pkiEnrolled([]string{t.TempDir(), dir}) {
		t.Fatal("usable cert+key must count as enrolled")
	}
	os.WriteFile(filepath.Join(dir, "node.crt"), []byte("junk"), 0o644)
	if pkiEnrolled([]string{dir}) {
		t.Fatal("unparseable cert is not enrolled")
	}
}

func TestResolverNeverRunsMediaScanAfterAPinlessHit(t *testing.T) {
	pki := newTestPKI(t)
	m := newFakeMachine(t)
	m.addDisk("sdb", fakeDisk{removable: true, parts: []string{"sdb1"}})
	m.media["sdb1"] = vfatWith(docFor(pki, idB, "2026-10-20T10:00:00Z")) // an attacker pin
	first := &stubStrategy{id: &Identity{InstanceUUID: idA}}
	r := &Resolver{Strategies: []Strategy{first, m.strategy()}}
	id, err := r.Resolve(context.Background())
	if err != nil || id.InstanceUUID != idA || id.CAFingerprint != "" {
		t.Fatalf("id=%+v err=%v", id, err)
	}
	if len(m.sniffs) != 0 {
		t.Fatal("media scan ran after a pinless hit")
	}
}

// M1 --------------------------------------------------------------------

func docWith(pki testPKI, id, issued, server, fp string) string {
	return v1Doc(pki, func(d map[string]any) {
		d["instance_id"] = id
		d["issued_at"] = issued
		d["expires_at"] = "2030-01-01T00:00:00Z"
		if server != "" {
			d["server"] = server
		}
		if fp != "" {
			d["ca_fingerprint"] = fp
		}
	})
}

const otherPin = "sha256:0000000000000000000000000000000000000000000000000000000000000001"

func TestMediaScanRefusesConflictingServerOrPin(t *testing.T) {
	pki := newTestPKI(t)
	for name, other := range map[string]string{
		"server": docWith(pki, idA, "2026-10-20T10:00:00Z", "https://evil.example.test", ""),
		"pin":    docWith(pki, idA, "2026-10-20T10:00:00Z", "", otherPin),
	} {
		// two removable sticks disagree: no non-removable source to prefer
		m := newFakeMachine(t)
		m.addDisk("sdb", fakeDisk{removable: true, parts: []string{"sdb1"}})
		m.addDisk("sdc", fakeDisk{removable: true, parts: []string{"sdc1"}})
		m.media["sdb1"] = vfatWith(docFor(pki, idA, "2026-10-20T09:00:00Z"))
		m.media["sdc1"] = vfatWith(other) // newer, even
		_, err := m.strategy().Discover(context.Background())
		if !errors.Is(err, ErrProvisionRefused) {
			t.Fatalf("%s: want refusal, got %v", name, err)
		}
		for _, o := range append(m.logs, err.Error()) {
			if strings.Contains(o, "evil.example") || strings.Contains(o, testKey) {
				t.Fatalf("%s: leak: %q", name, o)
			}
		}
	}
}

func TestMediaScanRefusesConflictBetweenNonRemovableSources(t *testing.T) {
	pki := newTestPKI(t)
	m := newFakeMachine(t)
	m.addDisk("sdd", fakeDisk{parts: []string{"sdd1"}})
	m.addDisk("sdc", fakeDisk{})
	m.label("cidata", "sdd1")
	m.media["sdd1"] = vfatWith(docFor(pki, idA, "2026-10-20T09:00:00Z"))
	m.media["sdc"] = vfatWith(docWith(pki, idA, "2026-10-20T09:00:00Z", "", otherPin))
	if _, err := m.strategy().Discover(context.Background()); !errors.Is(err, ErrProvisionRefused) {
		t.Fatalf("got %v", err)
	}
}

func TestMediaScanReadsAllCandidatesBeforeDeciding(t *testing.T) {
	pki := newTestPKI(t)
	doc := docFor(pki, idA, "2026-10-20T09:00:00Z")
	m := newFakeMachine(t)
	m.addDisk("sdb", fakeDisk{removable: true, parts: []string{"sdb1"}})
	m.addDisk("sdc", fakeDisk{removable: true})
	m.media["sdb1"] = vfatWith(doc)
	m.media["sdc"] = vfatWith(doc)
	id, err := m.strategy().Discover(context.Background())
	if err != nil || id.InstanceUUID != idA {
		t.Fatalf("id=%+v err=%v", id, err)
	}
	if len(m.calls) != 2 {
		t.Fatalf("no early stop: mounts=%v", m.calls)
	}
}
func TestSniffFSMagics(t *testing.T) {
	mk := func(size int, set func(b []byte)) []byte { b := make([]byte, size); set(b); return b }
	cases := map[string][]byte{
		"vfat":    mk(512, func(b []byte) { copy(b[82:], "FAT32   "); b[510], b[511] = 0x55, 0xAA }),
		"vfat16":  mk(512, func(b []byte) { copy(b[54:], "FAT16   "); b[510], b[511] = 0x55, 0xAA }),
		"exfat":   mk(512, func(b []byte) { copy(b[3:], "EXFAT   "); b[510], b[511] = 0x55, 0xAA }),
		"iso9660": mk(0x8006, func(b []byte) { copy(b[0x8001:], "CD001") }),
		"ext4":    mk(2048, func(b []byte) { b[1080], b[1081] = 0x53, 0xEF }),
		"":        mk(0x8006, func(b []byte) { copy(b[3:], "NTFS    "); b[510], b[511] = 0x55, 0xAA }),
	}
	want := map[string]string{"vfat": "vfat", "vfat16": "vfat", "exfat": "exfat", "iso9660": "iso9660", "ext4": "ext4", "": ""}
	for name, hdr := range cases {
		if got := sniffFSType(hdr); got != want[name] {
			t.Errorf("%s: sniff = %q, want %q", name, got, want[name])
		}
	}
	if sniffFSType(nil) != "" {
		t.Error("empty header must not match")
	}
}

// L1 --------------------------------------------------------------------

func TestMediaScanIgnoresSymlinkedFileAndSymlinkedDirectorySeparately(t *testing.T) {
	pki := newTestPKI(t)
	outDir := t.TempDir()
	os.WriteFile(filepath.Join(outDir, "provision.cfg"), []byte(docFor(pki, idA, "2026-10-20T10:00:00Z")), 0o600)
	os.WriteFile(filepath.Join(outDir, "powernode-provision.cfg"), []byte(docFor(pki, idA, "2026-10-20T10:00:00Z")), 0o600)
	for name, links := range map[string]map[string]string{
		"file link": {"powernode-provision.cfg": filepath.Join(outDir, "powernode-provision.cfg")},
		"dir link":  {"powernode": outDir},
	} {
		m := newFakeMachine(t)
		m.addDisk("sdb", fakeDisk{removable: true, parts: []string{"sdb1"}})
		m.media["sdb1"] = fakeMedia{fs: "vfat", links: links}
		if _, err := m.strategy().Discover(context.Background()); !errors.Is(err, ErrNotFound) {
			t.Fatalf("%s must be ignored, got %v", name, err)
		}
	}
}

func TestReadMediaFileOnlyOpensRegularFiles(t *testing.T) {
	dir := t.TempDir()
	if err := syscall.Mkfifo(filepath.Join(dir, "powernode-provision.cfg"), 0o600); err != nil {
		t.Skip("mkfifo unavailable")
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		if _, found, err := readMediaFile(dir); found || err != nil {
			t.Errorf("fifo must be skipped: found=%v err=%v", found, err)
		}
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("reading a fifo blocked")
	}
}

func TestMediaScanRefusesOversizedFileEvenWhenPaddingIsWhitespace(t *testing.T) {
	pki := newTestPKI(t)
	m := newFakeMachine(t)
	m.addDisk("sdb", fakeDisk{parts: []string{"sdb1"}})
	pad := strings.Repeat(" ", provisionMaxDocBytes)
	m.media["sdb1"] = vfatWith(docFor(pki, idA, "2026-10-20T10:00:00Z") + pad)
	_, err := m.strategy().Discover(context.Background())
	if !errors.Is(err, ErrProvisionRefused) {
		t.Fatalf("oversized file must be refused, got %v", err)
	}
}

type endlessReader struct{ n int }

func (r *endlessReader) Read(p []byte) (int, error) {
	r.n += len(p)
	for i := range p {
		p[i] = ' '
	}
	return len(p), nil
}

func TestReadCappedBoundsTheReadWithoutTrustingFstat(t *testing.T) {
	r := &endlessReader{}
	if _, err := readCapped(r); err == nil {
		t.Fatal("endless input must be refused")
	}
	if r.n > provisionMaxDocBytes+64*1024 {
		t.Fatalf("read %d bytes, the cap is not enforced", r.n)
	}
	got, err := readCapped(io.LimitReader(bytes.NewReader([]byte("abc")), 10))
	if err != nil || string(got) != "abc" {
		t.Fatalf("%q %v", got, err)
	}
}

// L2 --------------------------------------------------------------------

func TestMediaScanExcludesDisksBehindDevRootAndDeviceMapper(t *testing.T) {
	pki := newTestPKI(t)
	m := newFakeMachine(t)
	m.addDisk("sda", fakeDisk{parts: []string{"sda1", "sda2"}}) // root behind /dev/root
	m.addDisk("sdb", fakeDisk{parts: []string{"sdb1"}})         // behind dm-0
	m.addDisk("sdc", fakeDisk{})                                // genuinely free
	m.addDisk("dm-0", fakeDisk{})
	os.MkdirAll(m.path("sys/block/dm-0/slaves/sdb1"), 0o755)
	os.MkdirAll(m.path("dev/mapper"), 0o755)
	os.Symlink("../dm-0", m.path("dev/mapper/vg-data"))
	os.MkdirAll(m.path("sys/dev/block"), 0o755)
	os.Symlink("../../block/sda/sda2", m.path("sys/dev/block/8:2"))
	os.WriteFile(m.path("proc-mountinfo"), []byte(
		"30 1 8:2 / / rw - ext4 /dev/root rw\n"+
			"31 1 253:0 / /data rw - ext4 /dev/mapper/vg-data rw\n"), 0o644)
	for _, d := range []string{"sda1", "sda2", "sdb1", "sdc"} {
		m.media[d] = vfatWith(docFor(pki, idA, "2026-10-20T10:00:00Z"))
	}
	if _, err := m.strategy().Discover(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(m.sniffs, ","); got != "sdc" {
		t.Fatalf("probed %q, only sdc is free", got)
	}
}
