package identity

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type fakeCloud struct {
	userData string
	detected int
}

func (f *fakeCloud) Name() string                             { return "fake" }
func (f *fakeCloud) Detect(context.Context) bool              { f.detected++; return true }
func (f *fakeCloud) UserData(context.Context) (string, error) { return f.userData, nil }

// A network (cloud metadata) source must never be consulted after a pinless
// local hit: 169.254.169.254 over HTTP is spoofable and cannot veto or supply
// a pin.
func TestResolverSkipsCloudSourcesAfterLocalHit(t *testing.T) {
	pki := newTestPKI(t)
	dir := t.TempDir()
	cmdline := filepath.Join(dir, "cmdline")
	os.WriteFile(cmdline, []byte("powernode.instance_uuid=u powernode.bootstrap_token=k powernode.platform_url=https://p.example.com"), 0o600)
	cloud := &fakeCloud{userData: v1Doc(pki, nil)}
	r := &Resolver{Strategies: []Strategy{&CmdlineStrategy{Path: cmdline}, &CloudStrategy{Client: cloud}}}
	id, err := r.Resolve(context.Background())
	if err != nil || id.CAFingerprint != "" {
		t.Fatalf("a network source supplied a pin: %+v %v", id, err)
	}
	if cloud.detected != 0 {
		t.Fatal("cloud metadata was probed after a local hit")
	}
	bad := &fakeCloud{userData: `{"version":2}`}
	r = &Resolver{Strategies: []Strategy{&CmdlineStrategy{Path: cmdline}, &CloudStrategy{Client: bad}}}
	if _, err := r.Resolve(context.Background()); err != nil {
		t.Fatalf("a spoofed network source vetoed a local identity: %v", err)
	}
}

// Any "{" user-data that is not a well-formed legacy JSON object is judged by
// the strict parser, and its refusal is terminal when no local source yields a
// key (a local source, the legacy /etc file included, outranks a spoofable
// refusal: see TestMetadataRefusalDoesNotVetoLegacyEtc).
func TestCloudUserDataMalformedV1IsTerminal(t *testing.T) {
	pki := newTestPKI(t)
	good := v1Doc(pki, nil)
	cases := map[string]string{
		"syntax error":      `{"version":1,`,
		"capital Version":   `{"Version":1}`,
		"upper VERSION":     strings.Replace(good, `"version"`, `"VERSION"`, 1),
		"version string":    strings.Replace(good, `"version":1`, `"version":"1"`, 1),
		"just a brace":      `{`,
		"duplicate version": strings.Replace(good, `"version":1`, `"version":1,"version":1`, 1),
	}
	dir := t.TempDir()
	for name, ud := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := parseUserData(ud); !errors.Is(err, ErrProvisionRefused) {
				t.Fatalf("parseUserData err = %v, want ErrProvisionRefused", err)
			}
			r := &Resolver{Strategies: []Strategy{&CloudStrategy{Client: &fakeCloud{userData: ud}}, &LocalIdentityStrategy{Path: filepath.Join(dir, "absent.cfg")}}}
			if id, err := r.Resolve(context.Background()); err == nil {
				t.Fatalf("fell through to %+v", id)
			}
		})
	}
	// well-formed legacy JSON (no version key in any case) is still legacy
	if id, err := parseUserData(`{"instance_uuid":"u","bootstrap_token":"t","platform_url":"https://p"}`); err != nil || id.InstanceUUID != "u" {
		t.Fatalf("legacy JSON broke: %+v %v", id, err)
	}
}

// No self-signed CA in the bundle: every cert is an anchor (the shape of a
// persisted pin-only bundle that holds just an intermediate).
func TestPinnedTLSBundleWithoutSelfSignedCAUsesAllCertsAsAnchors(t *testing.T) {
	p := newChainPKI(t, "localhost")
	srv := serveTLS(t, p.server) // leaf only
	blk, _ := pem.Decode([]byte(p.interPEM))
	sum := sha256.Sum256(blk.Bytes)
	interFP := "sha256:" + hex.EncodeToString(sum[:])
	cfg, err := PinnedTLSConfig([]byte(p.interPEM), interFP, srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	if err := getWith(t, srv.URL, cfg); err != nil {
		t.Fatalf("intermediate-only bundle (fallback anchors) refused: %v", err)
	}
	if cfg, _ = PinnedTLSConfig([]byte(p.interPEM), p.rootFP, srv.URL); getWith(t, srv.URL, cfg) == nil {
		t.Fatal("pin of a cert not in the chain accepted")
	}
}

func TestServerURLRuleExcludesQueryFragmentAndDotHost(t *testing.T) {
	for _, bad := range []string{"https://..", "https://.", "https://-x", "https://p.example.test?x=1", "https://p.example.test/a?b", "https://p.example.test/#f", "https://p.example.test#f"} {
		if checkServerURL(bad) == nil {
			t.Errorf("%q accepted", bad)
		}
	}
	for _, ok := range []string{"https://p.example.test", "https://p.example.test:8443/base/x", "https://[::1]:8443/"} {
		if err := checkServerURL(ok); err != nil {
			t.Errorf("%q refused: %v", ok, err)
		}
	}
}
