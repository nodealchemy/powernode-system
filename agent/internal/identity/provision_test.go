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
	"encoding/json"
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

const testKey = "not-a-real-enrol-key"

type testPKI struct {
	caPEM  string
	caFP   string
	server tls.Certificate
}

func newTestPKI(t *testing.T) testPKI {
	t.Helper()
	caKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	caTpl := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "test-ca"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign,
	}
	caDER, err := x509.CreateCertificate(rand.Reader, caTpl, caTpl, &caKey.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	caCert, _ := x509.ParseCertificate(caDER)
	leafKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	leafTpl := &x509.Certificate{
		SerialNumber: big.NewInt(2), Subject: pkix.Name{CommonName: "localhost"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		DNSNames: []string{"localhost"}, IPAddresses: []net.IP{net.ParseIP("127.0.0.1")},
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	leafDER, err := x509.CreateCertificate(rand.Reader, leafTpl, caCert, &leafKey.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(caDER)
	return testPKI{
		caPEM:  string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER})),
		caFP:   "sha256:" + hex.EncodeToString(sum[:]),
		server: tls.Certificate{Certificate: [][]byte{leafDER}, PrivateKey: leafKey},
	}
}

func v1Doc(pki testPKI, mutate func(map[string]any)) string {
	d := map[string]any{
		"version":        1,
		"server":         "https://platform.example.test",
		"instance_id":    "0198f3a2-7b1c-7d2e-9a4f-1234567890ab",
		"key":            testKey,
		"ca_fingerprint": pki.caFP,
		"issued_at":      "2026-10-20T10:00:00Z",
		"expires_at":     "2026-10-20T11:00:00Z",
		"purpose":        "disk_image_enroll",
	}
	if mutate != nil {
		mutate(d)
	}
	b, _ := json.Marshal(d)
	return string(b)
}

func TestProvisionV1Parsed(t *testing.T) {
	pki := newTestPKI(t)
	id, err := ParseProvisionDocument([]byte(v1Doc(pki, func(d map[string]any) { d["ca_pem"] = pki.caPEM })))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if id.InstanceUUID != "0198f3a2-7b1c-7d2e-9a4f-1234567890ab" || id.BootstrapToken != testKey ||
		id.PlatformURL != "https://platform.example.test" || id.CAFingerprint != pki.caFP || id.CABundlePEM != pki.caPEM {
		t.Fatalf("unexpected identity: %+v", id)
	}
}

func TestProvisionV1WithoutCAPEMParses(t *testing.T) {
	pki := newTestPKI(t)
	id, err := ParseProvisionDocument([]byte(v1Doc(pki, nil)))
	if err != nil || id.CABundlePEM != "" {
		t.Fatalf("err=%v id=%+v", err, id)
	}
}

func TestProvisionRejects(t *testing.T) {
	pki := newTestPKI(t)
	other := newTestPKI(t)
	cases := map[string]func(map[string]any){
		"unknown key":             func(d map[string]any) { d["extra"] = "x" },
		"missing pin":             func(d map[string]any) { delete(d, "ca_fingerprint") },
		"empty pin":               func(d map[string]any) { d["ca_fingerprint"] = "" },
		"bad pin format":          func(d map[string]any) { d["ca_fingerprint"] = "sha1:abcd" },
		"uppercase pin":           func(d map[string]any) { d["ca_fingerprint"] = strings.ToUpper(pki.caFP) },
		"wrong version":           func(d map[string]any) { d["version"] = 2 },
		"missing version":         func(d map[string]any) { delete(d, "version") },
		"string version":          func(d map[string]any) { d["version"] = "1" },
		"http server":             func(d map[string]any) { d["server"] = "http://platform.example.test" },
		"server userinfo":         func(d map[string]any) { d["server"] = "https://u:p@platform.example.test" },
		"server not a url":        func(d map[string]any) { d["server"] = "not a url" },
		"bad uuid":                func(d map[string]any) { d["instance_id"] = "nope" },
		"missing key":             func(d map[string]any) { delete(d, "key") },
		"key with newline":        func(d map[string]any) { d["key"] = "abc\ndef" },
		"key control char":        func(d map[string]any) { d["key"] = "abc\x01def" },
		"key too long":            func(d map[string]any) { d["key"] = strings.Repeat("a", 513) },
		"bad issued_at":           func(d map[string]any) { d["issued_at"] = "yesterday" },
		"expires before issue":    func(d map[string]any) { d["expires_at"] = "2026-10-20T09:00:00Z" },
		"missing purpose":         func(d map[string]any) { delete(d, "purpose") },
		"purpose unprintable":     func(d map[string]any) { d["purpose"] = "a\tb" },
		"ca_pem not matching pin": func(d map[string]any) { d["ca_pem"] = other.caPEM },
		"ca_pem garbage":          func(d map[string]any) { d["ca_pem"] = "-----BEGIN CERTIFICATE-----\nZZZ" },
		"ca_pem too large":        func(d map[string]any) { d["ca_pem"] = strings.Repeat("A", 70*1024) },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			_, err := ParseProvisionDocument([]byte(v1Doc(pki, mutate)))
			if err == nil {
				t.Fatal("expected rejection")
			}
			if strings.Contains(err.Error(), testKey) {
				t.Fatalf("error leaks the key: %v", err)
			}
		})
	}
	if _, err := ParseProvisionDocument([]byte(v1Doc(pki, nil) + " {}")); err == nil {
		t.Error("trailing data accepted")
	}
	if _, err := ParseProvisionDocument([]byte(strings.Repeat(" ", 200*1024) + v1Doc(pki, nil))); err == nil {
		t.Error("oversized document accepted")
	}
}

func TestPinMismatchRefusesAndMatchEnrols(t *testing.T) {
	pki := newTestPKI(t)
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) }))
	srv.TLS = &tls.Config{Certificates: []tls.Certificate{pki.server}}
	srv.StartTLS()
	defer srv.Close()

	get := func(caPEM, pin string) error {
		cfg, err := PinnedTLSConfig([]byte(caPEM), pin)
		if err != nil {
			return err
		}
		c := &http.Client{Transport: &http.Transport{TLSClientConfig: cfg}, Timeout: 5 * time.Second}
		resp, err := c.Get(srv.URL)
		if err == nil {
			resp.Body.Close()
		}
		return err
	}
	if err := get(pki.caPEM, pki.caFP); err != nil {
		t.Fatalf("matching pin refused: %v", err)
	}
	wrong := "sha256:" + strings.Repeat("0", 64)
	if err := get(pki.caPEM, wrong); err == nil {
		t.Fatal("pin mismatch was accepted")
	}
	// A pin with NO ca bundle must still be enforced (system roots reject the
	// test CA, so this also errors; the point is it never succeeds).
	if err := get("", pki.caFP); err == nil {
		t.Fatal("pin without a trusting root was accepted")
	}
	if _, err := PinnedTLSConfig([]byte(pki.caPEM), "bogus"); err == nil {
		t.Fatal("malformed pin accepted")
	}
}

func TestLegacyKeyValueStillRead(t *testing.T) {
	p := filepath.Join(t.TempDir(), "identity.cfg")
	body := "ID=legacy-uuid\nKEY=legacy-key\nSERVER=https://p.legacy.example.com\n"
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	id, err := (&LocalIdentityStrategy{Path: p}).Discover(context.Background())
	if err != nil || id.InstanceUUID != "legacy-uuid" || id.BootstrapToken != "legacy-key" || id.CAFingerprint != "" {
		t.Fatalf("legacy read broke: id=%+v err=%v", id, err)
	}
}

func TestLegacyKeyValueCarriesOptionalPin(t *testing.T) {
	pki := newTestPKI(t)
	p := filepath.Join(t.TempDir(), "identity.cfg")
	body := "ID=legacy-uuid\nKEY=k\nSERVER=https://p.example.com\nCA_FINGERPRINT=" + pki.caFP + "\n"
	os.WriteFile(p, []byte(body), 0o600)
	id, err := (&LocalIdentityStrategy{Path: p}).Discover(context.Background())
	if err != nil || id.CAFingerprint != pki.caFP {
		t.Fatalf("pin not carried: %+v %v", id, err)
	}
	os.WriteFile(p, []byte("ID=u\nKEY=k\nSERVER=https://p\nCA_FINGERPRINT=garbage\n"), 0o600)
	if _, err := (&LocalIdentityStrategy{Path: p}).Discover(context.Background()); err == nil {
		t.Fatal("malformed legacy pin accepted")
	}
}

func TestLocalIdentityReadsV1JSONFile(t *testing.T) {
	pki := newTestPKI(t)
	p := filepath.Join(t.TempDir(), "identity.json")
	os.WriteFile(p, []byte(v1Doc(pki, nil)), 0o600)
	id, err := (&LocalIdentityStrategy{Path: p}).Discover(context.Background())
	if err != nil || id.CAFingerprint != pki.caFP || id.BootstrapToken != testKey {
		t.Fatalf("v1 file: %+v %v", id, err)
	}
}

func TestV1DocumentWithBadContentIsNotSilentlyDowngradedToLegacy(t *testing.T) {
	pki := newTestPKI(t)
	bad := v1Doc(pki, func(d map[string]any) { delete(d, "ca_fingerprint") })
	if _, err := parseUserData(bad); err == nil {
		t.Fatal("v1-shaped doc without pin fell through to legacy parsing")
	}
}

func TestParseUserDataV1AndLegacyJSON(t *testing.T) {
	pki := newTestPKI(t)
	id, err := parseUserData(v1Doc(pki, nil))
	if err != nil || id.CAFingerprint != pki.caFP {
		t.Fatalf("v1 user-data: %+v %v", id, err)
	}
	id, err = parseUserData(`{"instance_uuid":"u","bootstrap_token":"t","platform_url":"https://p"}`)
	if err != nil || id.InstanceUUID != "u" {
		t.Fatalf("legacy json: %+v %v", id, err)
	}
}
