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

func TestMetadataPinNeverOverridesLocalPin(t *testing.T) {
	// metadata is spoofable: a pin it asserts must never displace a local (BOOT) pin
	r := &Resolver{Strategies: []Strategy{
		&CloudStrategy{Client: &fakeMeta{data: metaKV + "CA_FINGERPRINT=" + pinB + "\n"}},
		bootCfg(t, "SERVER=https://boot\nCA_FINGERPRINT="+pinA+"\n"),
	}}
	id, err := r.Resolve(context.Background())
	if err != nil || id.CAFingerprint != pinA {
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

func TestMetadataRefusalTerminalWithoutLocalKey(t *testing.T) {
	console := &spyStrategy{id: &Identity{InstanceUUID: "u", BootstrapToken: "k"}}
	claim := &ClaimStrategy{BootStrategy: &spyStrategy{err: ErrNotFound}}
	r := &Resolver{Interactive: true, Strategies: []Strategy{
		&CloudStrategy{Client: &fakeMeta{data: `{"version":1,"garbage":true}`}},
		bootCfg(t, "SERVER=https://boot\n"), // tokenless: no key
		&ConsolePromptStrategy{Open: func() (ConsoleTTY, error) { atomic.AddInt32(&console.called, 1); return nil, errors.New("x") }},
		claim,
	}}
	_, err := r.Resolve(context.Background())
	if !errors.Is(err, ErrProvisionRefused) {
		t.Fatalf("cloud v1 refusal stays terminal: %v", err)
	}
	if console.called != 0 {
		t.Fatal("must not fall through to the console prompt")
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

func TestMediaStaysBehindMetadataAndNeverSuppliesPin(t *testing.T) {
	// a media hit after a pinless metadata hit is skipped (stick never attaches a pin)
	r := &Resolver{Strategies: []Strategy{
		&CloudStrategy{Client: &fakeMeta{data: metaKV}},
		&MediaScanStrategy{},
	}}
	id, err := r.Resolve(context.Background())
	if err != nil || id.InstanceUUID != "meta-uuid" || id.CAFingerprint != "" {
		t.Fatalf("%v %v", id, err)
	}
}
