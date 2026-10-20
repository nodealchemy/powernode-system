package identity

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

const (
	pinA = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	pinB = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
)

// fakeMeta is a MetadataClient fake; it counts probes so a test can assert a
// network source was never consulted.
type fakeMeta struct {
	detect int32
	data   string
	err    error
}

func (f *fakeMeta) Name() string { return "fake" }
func (f *fakeMeta) Detect(context.Context) bool {
	atomic.AddInt32(&f.detect, 1)
	return true
}
func (f *fakeMeta) UserData(context.Context) (string, error) { return f.data, f.err }

func (f *fakeMeta) probed() bool { return atomic.LoadInt32(&f.detect) > 0 }

func bootCfg(t *testing.T, body string) *BootKeyStrategy {
	t.Helper()
	p := filepath.Join(t.TempDir(), "identity.cfg")
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return &BootKeyStrategy{Path: p}
}

const metaKV = "ID=meta-uuid\nKEY=meta-key\nSERVER=https://meta.example.com\n"

type spyStrategy struct {
	called int32
	id     *Identity
	err    error
}

func (s *spyStrategy) Name() string { return "spy" }
func (s *spyStrategy) Discover(context.Context) (*Identity, error) {
	atomic.AddInt32(&s.called, 1)
	return s.id, s.err
}

// The operator's fixed order (design memory:image-distribution-model).
func TestDefaultResolverPrecedenceOrder(t *testing.T) {
	want := []string{
		"kernel-cmdline", "virtio-fw-cfg", "local-identity-cfg:/run/powernode/identity.cfg",
		"cloud-aws", "cloud-gcp", "cloud-azure", "cloud-digitalocean",
		"media-scan", "boot-key", "console-prompt", "claim-poll",
	}
	for _, r := range []*Resolver{DefaultResolver(), InteractiveResolver()} {
		var got []string
		for _, s := range r.Strategies {
			n := s.Name()
			if l, ok := s.(*LocalIdentityStrategy); ok {
				n += ":" + l.Path
			}
			got = append(got, n)
		}
		// the legacy /etc fallback is not one of the eight sources: it trails
		if len(got) != len(want)+1 || got[len(got)-1] != "local-identity-cfg:/etc/identity.cfg" {
			t.Fatalf("got %v", got)
		}
		if g, w := strings.Join(got[:len(want)], ","), strings.Join(want, ","); g != w {
			t.Fatalf("order\n got  %s\n want %s", g, w)
		}
	}
}

func TestBootKeyStrategy(t *testing.T) {
	if _, err := bootCfg(t, "SERVER=https://p\nID=x\n").Discover(context.Background()); !errors.Is(err, ErrNotFound) {
		t.Fatalf("a tokenless BOOT cfg is claim material, not a key: %v", err)
	}
	id, err := bootCfg(t, "SERVER=https://p\nID=x\nKEY=k\n").Discover(context.Background())
	if err != nil || id.InstanceUUID != "x" || id.BootstrapToken != "k" {
		t.Fatalf("%v %v", id, err)
	}
}

func TestMetadataBeatsBootKey(t *testing.T) {
	m := &fakeMeta{data: metaKV}
	r := &Resolver{Strategies: []Strategy{
		&CloudStrategy{Client: m},
		bootCfg(t, "SERVER=https://boot\nID=boot-uuid\nKEY=boot-key\n"),
	}}
	id, err := r.Resolve(context.Background())
	if err != nil || id.InstanceUUID != "meta-uuid" {
		t.Fatalf("first non-empty key wins: %v %v", id, err)
	}
}

func TestBootPinEnforcedOnMetadataWinner(t *testing.T) {
	r := &Resolver{Strategies: []Strategy{
		&CloudStrategy{Client: &fakeMeta{data: metaKV}},
		bootCfg(t, "SERVER=https://boot\nID=boot-uuid\nKEY=boot-key\nCA_FINGERPRINT="+pinA+"\n"),
	}}
	id, err := r.Resolve(context.Background())
	if err != nil || id.InstanceUUID != "meta-uuid" || id.CAFingerprint != pinA {
		t.Fatalf("a pin from any source is enforced on the winner: %v %v", id, err)
	}
}

func TestTokenlessBootPinEnforcedOnMetadataWinner(t *testing.T) {
	r := &Resolver{Strategies: []Strategy{
		&CloudStrategy{Client: &fakeMeta{data: metaKV}},
		bootCfg(t, "SERVER=https://boot\nCA_FINGERPRINT="+pinB+"\n"),
	}}
	id, err := r.Resolve(context.Background())
	if err != nil || id.CAFingerprint != pinB {
		t.Fatalf("%v %v", id, err)
	}
}

func TestLocalHitNeverProbesMetadata(t *testing.T) {
	m := &fakeMeta{data: metaKV + "CA_FINGERPRINT=" + pinB + "\n"}
	r := &Resolver{Strategies: []Strategy{
		consoleStubStrategy{id: &Identity{InstanceUUID: "u", BootstrapToken: "k"}},
		&CloudStrategy{Client: m},
	}}
	id, err := r.Resolve(context.Background())
	if err != nil || id.InstanceUUID != "u" || id.CAFingerprint != "" || m.probed() {
		t.Fatalf("network metadata must neither be consulted nor supply a pin: %v %v probed=%v", id, err, m.probed())
	}
}

func TestMetadataRefusalDoesNotVetoBootKey(t *testing.T) {
	m := &fakeMeta{data: `{"version":1,"garbage":true}`}
	r := &Resolver{Strategies: []Strategy{
		&CloudStrategy{Client: m},
		bootCfg(t, "SERVER=https://boot\nID=boot-uuid\nKEY=boot-key\n"),
	}}
	id, err := r.Resolve(context.Background())
	if err != nil || id.InstanceUUID != "boot-uuid" {
		t.Fatalf("a spoofed metadata refusal must not veto a local BOOT key: %v %v", id, err)
	}
}

func TestBootKeyBeatsConsoleAndClaim(t *testing.T) {
	prompted := int32(0)
	bs := &spyStrategy{err: ErrNotFound}
	r := &Resolver{Interactive: true, Strategies: []Strategy{
		bootCfg(t, "SERVER=https://boot\nID=boot-uuid\nKEY=boot-key\n"),
		&ConsolePromptStrategy{Open: func() (ConsoleTTY, error) { atomic.AddInt32(&prompted, 1); return nil, errors.New("x") }},
		&ClaimStrategy{BootStrategy: bs},
	}}
	id, err := r.Resolve(context.Background())
	if err != nil || id.InstanceUUID != "boot-uuid" || prompted != 0 || bs.called != 0 {
		t.Fatalf("%v %v prompted=%d claim=%d", id, err, prompted, bs.called)
	}
}

const refusalDoc = `{"version":1,"garbage":true}`

func mediaWinner(t *testing.T, pki testPKI) *MediaScanStrategy {
	t.Helper()
	m := newFakeMachine(t) // temp dirs and fakes only: no real device is touched
	m.addDisk("sdb", fakeDisk{removable: true, parts: []string{"sdb1"}})
	m.media["sdb1"] = vfatWith(docFor(pki, idA, "2026-10-20T10:00:00Z"))
	return m.strategy()
}

func TestBootKeyRequiresServer(t *testing.T) {
	if _, err := bootCfg(t, "ID=x\nKEY=k\n").Discover(context.Background()); !errors.Is(err, ErrNotFound) {
		t.Fatalf("a BOOT key without SERVER cannot be enrolled: %v", err)
	}
}

// H1: a stick's pin is not authoritative; the BOOT pin is consulted and a
// disagreement fails closed.
func TestStickPinConflictingWithBootPinFailsClosed(t *testing.T) {
	pki := newTestPKI(t)
	r := &Resolver{Strategies: []Strategy{
		mediaWinner(t, pki),
		bootCfg(t, "SERVER=https://boot\nID=boot-uuid\nKEY=boot-key\nCA_FINGERPRINT="+pinB+"\n"),
	}}
	if _, err := r.Resolve(context.Background()); !errors.Is(err, ErrProvisionRefused) {
		t.Fatalf("stick pin %s vs BOOT pin must refuse: %v", pki.caFP, err)
	}
}

func TestStickPinAgreeingWithBootPinWins(t *testing.T) {
	pki := newTestPKI(t)
	r := &Resolver{Strategies: []Strategy{
		mediaWinner(t, pki),
		bootCfg(t, "SERVER=https://boot\nCA_FINGERPRINT="+pki.caFP+"\n"),
	}}
	id, err := r.Resolve(context.Background())
	if err != nil || id.InstanceUUID != idA || id.CAFingerprint != pki.caFP {
		t.Fatalf("%v %v", id, err)
	}
}

func TestMetadataPinConflictingWithBootPinFailsClosed(t *testing.T) {
	r := &Resolver{Strategies: []Strategy{
		&CloudStrategy{Client: &fakeMeta{data: metaKV + "CA_FINGERPRINT=" + pinB + "\n"}},
		bootCfg(t, "SERVER=https://boot\nCA_FINGERPRINT="+pinA+"\n"),
	}}
	if _, err := r.Resolve(context.Background()); !errors.Is(err, ErrProvisionRefused) {
		t.Fatalf("a spoofable metadata pin must not displace a local one: %v", err)
	}
}

// M1: two local sources with different pins never pick one silently.
func TestConflictingLocalPinsFailClosed(t *testing.T) {
	r := &Resolver{Strategies: []Strategy{
		consoleStubStrategy{id: &Identity{InstanceUUID: "u", BootstrapToken: "k", CAFingerprint: pinA}},
		bootCfg(t, "SERVER=https://boot\nCA_FINGERPRINT="+pinB+"\n"),
	}}
	if _, err := r.Resolve(context.Background()); !errors.Is(err, ErrProvisionRefused) {
		t.Fatalf("%v", err)
	}
	etc := filepath.Join(t.TempDir(), "identity.cfg")
	os.WriteFile(etc, []byte("ID=e\nKEY=k\nSERVER=https://e\nCA_FINGERPRINT="+pinB+"\n"), 0o600)
	r = &Resolver{Strategies: []Strategy{
		consoleStubStrategy{id: &Identity{InstanceUUID: "u", BootstrapToken: "k", CAFingerprint: pinA}},
		&LocalIdentityStrategy{Path: etc},
	}}
	if _, err := r.Resolve(context.Background()); !errors.Is(err, ErrProvisionRefused) {
		t.Fatalf("/etc pin conflict: %v", err)
	}
	r = &Resolver{Strategies: []Strategy{
		consoleStubStrategy{id: &Identity{InstanceUUID: "u", BootstrapToken: "k", CAFingerprint: pinA}},
		bootCfg(t, "SERVER=https://boot\nCA_FINGERPRINT="+pinA+"\n"),
	}}
	if id, err := r.Resolve(context.Background()); err != nil || id.CAFingerprint != pinA {
		t.Fatalf("equal pins agree: %v %v", id, err)
	}
}

func TestBootRefusalOnPinPathIsTerminal(t *testing.T) {
	r := &Resolver{Strategies: []Strategy{
		consoleStubStrategy{id: &Identity{InstanceUUID: "u", BootstrapToken: "k"}},
		bootCfg(t, refusalDoc),
	}}
	if _, err := r.Resolve(context.Background()); !errors.Is(err, ErrProvisionRefused) {
		t.Fatalf("%v", err)
	}
}

// L2: a keyless earlier source still contributes its pin.
func TestKeylessSourcePinIsEnforced(t *testing.T) {
	r := &Resolver{Strategies: []Strategy{
		consoleStubStrategy{id: &Identity{CAFingerprint: pinA}}, // pin only, no instance
		&CloudStrategy{Client: &fakeMeta{data: metaKV}},
	}}
	id, err := r.Resolve(context.Background())
	if err != nil || id.InstanceUUID != "meta-uuid" || id.CAFingerprint != pinA {
		t.Fatalf("%v %v", id, err)
	}
}

// H2: a (spoofable) metadata refusal is deferred past ALL local sources.
func TestMetadataRefusalTerminalOnlyWithoutAnyLocalKey(t *testing.T) {
	claimBoot := &spyStrategy{err: ErrNotFound}
	r := &Resolver{Strategies: []Strategy{
		&CloudStrategy{Client: &fakeMeta{data: refusalDoc}},
		bootCfg(t, "SERVER=https://boot\n"),
		&ClaimStrategy{BootStrategy: claimBoot},
	}}
	if _, err := r.Resolve(context.Background()); !errors.Is(err, ErrProvisionRefused) {
		t.Fatalf("no local key anywhere: refusal stays terminal: %v", err)
	}
	if claimBoot.called == 0 {
		t.Fatal("local sources, claim included, must be tried before the refusal is returned")
	}
}

func TestMetadataRefusalDoesNotVetoClaim(t *testing.T) {
	r := &Resolver{Strategies: []Strategy{
		&CloudStrategy{Client: &fakeMeta{data: refusalDoc}},
		&ClaimStrategy{BootStrategy: &spyStrategy{id: &Identity{InstanceUUID: "c", BootstrapToken: "k", PlatformURL: "https://p"}}},
	}}
	if id, err := r.Resolve(context.Background()); err != nil || id.InstanceUUID != "c" {
		t.Fatalf("claim-by-ID device vetoed by spoofed metadata: %v %v", id, err)
	}
}

func TestMetadataRefusalDoesNotVetoMedia(t *testing.T) {
	r := &Resolver{Strategies: []Strategy{
		&CloudStrategy{Client: &fakeMeta{data: refusalDoc}},
		mediaWinner(t, newTestPKI(t)),
	}}
	if id, err := r.Resolve(context.Background()); err != nil || id.InstanceUUID != idA {
		t.Fatalf("%v %v", id, err)
	}
}

func TestMetadataRefusalDoesNotVetoConsole(t *testing.T) {
	f := newConsole(t, consoleDoc("")+"\n", bootCfgPinned)
	r := &Resolver{Interactive: true, Strategies: []Strategy{
		&CloudStrategy{Client: &fakeMeta{data: refusalDoc}},
		f.s,
	}}
	if id, err := r.Resolve(context.Background()); err != nil || id.InstanceUUID == "" {
		t.Fatalf("%v %v", id, err)
	}
}

func TestMetadataRefusalDoesNotVetoLegacyEtc(t *testing.T) {
	etc := filepath.Join(t.TempDir(), "identity.cfg")
	os.WriteFile(etc, []byte("ID=e\nKEY=k\nSERVER=https://e\n"), 0o600)
	r := &Resolver{Strategies: []Strategy{
		&CloudStrategy{Client: &fakeMeta{data: refusalDoc}},
		&LocalIdentityStrategy{Path: etc},
	}}
	if id, err := r.Resolve(context.Background()); err != nil || id.InstanceUUID != "e" {
		t.Fatalf("%v %v", id, err)
	}
}

func TestMetadataWinnerSkipsMediaScan(t *testing.T) {
	// media never runs once metadata has a key: nothing for a stick to veto or pin
	r := &Resolver{Strategies: []Strategy{
		&CloudStrategy{Client: &fakeMeta{data: metaKV}},
		&MediaScanStrategy{SysBlock: filepath.Join(t.TempDir(), "none")}, // never reached
	}}
	if id, err := r.Resolve(context.Background()); err != nil || id.InstanceUUID != "meta-uuid" {
		t.Fatalf("%v %v", id, err)
	}
}
