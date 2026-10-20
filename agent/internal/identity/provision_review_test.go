package identity

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// --- strict JSON: duplicates, case variants, nulls, nesting, 1.0, ports ----

func TestProvisionRejectsRawShapes(t *testing.T) {
	pki := newTestPKI(t)
	base := func(extra string) string {
		return `{"version":1,"server":"https://platform.example.test","instance_id":"0198f3a2-7b1c-7d2e-9a4f-1234567890ab",` +
			`"key":"` + testKey + `","ca_fingerprint":"` + pki.caFP + `","issued_at":"2026-10-20T10:00:00Z",` +
			`"expires_at":"2026-10-20T11:00:00Z","purpose":"usb"` + extra + `}`
	}
	cases := map[string]string{
		"duplicate key":        base(`,"key":"other-key"`),
		"duplicate version":    base(`,"version":1`),
		"case variant extra":   base(`,"Ca_Fingerprint":"` + pki.caFP + `"`),
		"upper-case extra":     base(`,"CA_FINGERPRINT":"` + pki.caFP + `"`),
		"nested object value":  base(`,"ca_pem":{"a":1}`),
		"array value":          base(`,"ca_pem":["x"]`),
		"explicit null ca_pem": base(`,"ca_pem":null`),
		"version 1.0":          strings.Replace(base(""), `"version":1`, `"version":1.0`, 1),
		"version 1e0":          strings.Replace(base(""), `"version":1`, `"version":1e0`, 1),
		"explicit null key":    strings.Replace(base(""), `"key":"`+testKey+`"`, `"key":null`, 1),
		"port out of range":    strings.Replace(base(""), "platform.example.test", "platform.example.test:99999", 1),
		"port zero":            strings.Replace(base(""), "platform.example.test", "platform.example.test:0", 1),
		"server with space":    strings.Replace(base(""), "platform.example.test", "platform.example.test/a b", 1),
		"top-level array":      `[` + base("") + `]`,
	}
	for name, doc := range cases {
		t.Run(name, func(t *testing.T) {
			_, err := ParseProvisionDocument([]byte(doc))
			if err == nil {
				t.Fatal("expected rejection")
			}
			if strings.Contains(err.Error(), testKey) {
				t.Fatalf("error leaks the key: %v", err)
			}
		})
	}
	if _, err := ParseProvisionDocument([]byte(strings.Replace(base(""), "platform.example.test", "platform.example.test:8443", 1))); err != nil {
		t.Fatalf("valid port refused: %v", err)
	}
}

// --- resolver: refusal is terminal, pins carried across sources ------------

func TestResolverRefusedV1IsTerminal(t *testing.T) {
	pki := newTestPKI(t)
	dir := t.TempDir()
	badV1 := filepath.Join(dir, "bad.json")
	os.WriteFile(badV1, []byte(v1Doc(pki, func(d map[string]any) { delete(d, "ca_fingerprint") })), 0o600)
	legacy := filepath.Join(dir, "legacy.cfg")
	os.WriteFile(legacy, []byte("ID=legacy-uuid\nKEY=legacy-key\nSERVER=https://p.example.com\n"), 0o600)

	r := &Resolver{Strategies: []Strategy{
		&LocalIdentityStrategy{Path: badV1},
		&LocalIdentityStrategy{Path: legacy},
	}}
	id, err := r.Resolve(context.Background())
	if err == nil {
		t.Fatalf("fell through a refused v1 document to %+v", id)
	}
	if id != nil {
		t.Fatalf("returned an identity alongside the refusal: %+v", id)
	}
}

func TestResolverCarriesPinFromLaterV1Source(t *testing.T) {
	pki := newTestPKI(t)
	dir := t.TempDir()
	cmdline := filepath.Join(dir, "cmdline")
	os.WriteFile(cmdline, []byte("powernode.instance_uuid=cmd-uuid powernode.bootstrap_token=cmd-key powernode.platform_url=https://p.example.com"), 0o600)
	v1 := filepath.Join(dir, "identity.json")
	os.WriteFile(v1, []byte(v1Doc(pki, nil)), 0o600)

	r := &Resolver{Strategies: []Strategy{&CmdlineStrategy{Path: cmdline}, &LocalIdentityStrategy{Path: v1}}}
	id, err := r.Resolve(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if id.InstanceUUID != "cmd-uuid" || id.CAFingerprint != pki.caFP {
		t.Fatalf("pin not enforced on the source that supplied the key: %+v", id)
	}
}

func TestResolverLaterRefusedV1AfterPinlessHitIsTerminal(t *testing.T) {
	pki := newTestPKI(t)
	dir := t.TempDir()
	cmdline := filepath.Join(dir, "cmdline")
	os.WriteFile(cmdline, []byte("powernode.instance_uuid=u powernode.bootstrap_token=k powernode.platform_url=https://p.example.com"), 0o600)
	bad := filepath.Join(dir, "bad.json")
	os.WriteFile(bad, []byte(v1Doc(pki, func(d map[string]any) { d["version"] = 2 })), 0o600)
	r := &Resolver{Strategies: []Strategy{&CmdlineStrategy{Path: cmdline}, &LocalIdentityStrategy{Path: bad}}}
	if _, err := r.Resolve(context.Background()); err == nil {
		t.Fatal("a refused v1 document was ignored because a pinless source came first")
	}
}

func TestResolverPinlessSourcesStayPinless(t *testing.T) {
	dir := t.TempDir()
	cmdline := filepath.Join(dir, "cmdline")
	os.WriteFile(cmdline, []byte("powernode.instance_uuid=u powernode.bootstrap_token=k powernode.platform_url=https://p.example.com"), 0o600)
	r := &Resolver{Strategies: []Strategy{&CmdlineStrategy{Path: cmdline}}}
	id, err := r.Resolve(context.Background())
	if err != nil || id.CAFingerprint != "" {
		t.Fatalf("%+v %v", id, err)
	}
}

// --- claim: the HTTPClient override cannot bypass a pin ---------------------

func TestClaimHTTPClientOverrideIgnoredWhenPinned(t *testing.T) {
	override := &http.Client{}
	s := &ClaimStrategy{HTTPClient: override}
	if got := s.httpClient(&Identity{CAFingerprint: "sha256:" + strings.Repeat("a", 64), CABundlePEM: "x"}); got == override {
		t.Fatal("override used despite a pin")
	}
	if got := s.httpClient(&Identity{}); got != override {
		t.Fatal("override should still apply when there is no pin")
	}
}

// --- chain building: intermediates, anchors, hostname ----------------------

type chainPKI struct {
	rootPEM, interPEM string
	rootFP            string
	server            tls.Certificate
}

func newChainPKI(t *testing.T, dnsName string) chainPKI {
	t.Helper()
	mk := func(cn string, parent *x509.Certificate, parentKey *ecdsa.PrivateKey, ca bool, dns string) (*x509.Certificate, *ecdsa.PrivateKey, []byte) {
		k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		tpl := &x509.Certificate{
			SerialNumber: big.NewInt(time.Now().UnixNano()), Subject: pkix.Name{CommonName: cn},
			NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
			BasicConstraintsValid: true, IsCA: ca,
		}
		if ca {
			tpl.KeyUsage = x509.KeyUsageCertSign
		} else {
			tpl.KeyUsage = x509.KeyUsageDigitalSignature
			tpl.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}
			tpl.DNSNames = []string{dns}
			if dns == "localhost" {
				tpl.IPAddresses = []net.IP{net.ParseIP("127.0.0.1")}
			}
		}
		signer, signKey := tpl, k
		if parent != nil {
			signer, signKey = parent, parentKey
		}
		der, err := x509.CreateCertificate(rand.Reader, tpl, signer, &k.PublicKey, signKey)
		if err != nil {
			t.Fatal(err)
		}
		c, _ := x509.ParseCertificate(der)
		return c, k, der
	}
	root, rk, rootDER := mk("root", nil, nil, true, "")
	inter, ik, interDER := mk("inter", root, rk, true, "")
	_, lk, leafDER := mk("leaf", inter, ik, false, dnsName)
	sum := sha256.Sum256(rootDER)
	enc := func(der []byte) string {
		return string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
	}
	return chainPKI{
		rootPEM: enc(rootDER), interPEM: enc(interDER), rootFP: "sha256:" + hex.EncodeToString(sum[:]),
		server: tls.Certificate{Certificate: [][]byte{leafDER}, PrivateKey: lk}, // LEAF ONLY
	}
}

func serveTLS(t *testing.T, cert tls.Certificate) *httptest.Server {
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	srv.TLS = &tls.Config{Certificates: []tls.Certificate{cert}}
	srv.StartTLS()
	t.Cleanup(srv.Close)
	return srv
}

func getWith(t *testing.T, url string, cfg *tls.Config) error {
	c := &http.Client{Transport: &http.Transport{TLSClientConfig: cfg}, Timeout: 5 * time.Second}
	resp, err := c.Get(url)
	if err == nil {
		resp.Body.Close()
	}
	return err
}

func TestPinnedTLSLeafOnlyServerWithIntermediateInBundle(t *testing.T) {
	p := newChainPKI(t, "localhost")
	srv := serveTLS(t, p.server)
	// bundle ordered anchor-last: [intermediate, root]; pin = root (last)
	cfg, err := PinnedTLSConfig([]byte(p.interPEM+p.rootPEM), p.rootFP, srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	if err := getWith(t, srv.URL, cfg); err != nil {
		t.Fatalf("leaf-only server with intermediate in ca_pem refused: %v", err)
	}
}

func TestPinnedTLSStillVerifiesHostname(t *testing.T) {
	p := newChainPKI(t, "some-other-host.example")
	srv := serveTLS(t, p.server)
	cfg, _ := PinnedTLSConfig([]byte(p.interPEM+p.rootPEM), p.rootFP, srv.URL)
	if err := getWith(t, srv.URL, cfg); err == nil {
		t.Fatal("certificate for a different host was accepted")
	}
}

func TestPinnedTLSExtraBundleCertsDoNotBecomeAnchorsWhenRootPresent(t *testing.T) {
	p := newChainPKI(t, "localhost")
	srv := serveTLS(t, p.server)
	// Bundle trusts ONLY the intermediate as a bare anchor plus an unrelated root:
	// with a self-signed root present the intermediate is not an anchor, so a
	// pin of the (present but non-issuing) other root cannot be satisfied by it.
	other := newChainPKI(t, "localhost")
	cfg, _ := PinnedTLSConfig([]byte(p.interPEM+other.rootPEM), other.rootFP, srv.URL)
	if err := getWith(t, srv.URL, cfg); err == nil {
		t.Fatal("chain accepted without reaching a self-signed anchor")
	}
}
