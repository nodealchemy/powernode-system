package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestEnvOr(t *testing.T) {
	t.Setenv("PN_TEST_ENVOR", "from-env")
	if got := envOr("from-flag", "PN_TEST_ENVOR"); got != "from-flag" {
		t.Fatalf("set flag must win: got %q", got)
	}
	if got := envOr("", "PN_TEST_ENVOR"); got != "from-env" {
		t.Fatalf("empty flag must fall back to env: got %q", got)
	}
	if got := envOr("", "PN_TEST_ENVOR_UNSET"); got != "" {
		t.Fatalf("unset env must yield empty: got %q", got)
	}
}

func TestSplitCSV(t *testing.T) {
	cases := []struct {
		in   string
		want []string
	}{
		{"", nil},
		{"   ", nil},
		{"gvisor", []string{"gvisor"}},
		{"gvisor,kata", []string{"gvisor", "kata"}},
		{" gvisor , kata ,", []string{"gvisor", "kata"}}, // trim + drop empty segment
		{",,", nil},
	}
	for _, c := range cases {
		got := splitCSV(c.in)
		if len(got) != len(c.want) {
			t.Fatalf("splitCSV(%q) = %v, want %v", c.in, got, c.want)
		}
		for i := range got {
			if got[i] != c.want[i] {
				t.Fatalf("splitCSV(%q)[%d] = %q, want %q", c.in, i, got[i], c.want[i])
			}
		}
	}
}

func TestLoadCapabilityToken(t *testing.T) {
	dir := t.TempDir()

	// Bare wire shape.
	bare := filepath.Join(dir, "bare.json")
	mustWrite(t, bare, `{"envelope":"ZW52","signature":"c2ln"}`)
	tok, err := loadCapabilityToken(bare)
	if err != nil {
		t.Fatalf("bare token: %v", err)
	}
	if tok.Envelope != "ZW52" || tok.Signature != "c2ln" {
		t.Fatalf("bare token fields wrong: %+v", tok)
	}

	// Richer mint payload — extra fields must be ignored, envelope+signature picked.
	rich := filepath.Join(dir, "rich.json")
	mustWrite(t, rich, `{"envelope":"ZW52","signature":"c2ln","handle":"cap-1","sub":"a","aud":"b","skill":"inference.ping"}`)
	if _, err := loadCapabilityToken(rich); err != nil {
		t.Fatalf("rich token: %v", err)
	}

	// Missing fields → error.
	missing := filepath.Join(dir, "missing.json")
	mustWrite(t, missing, `{"envelope":"ZW52"}`)
	if _, err := loadCapabilityToken(missing); err == nil {
		t.Fatal("expected error for token missing signature")
	}

	// Bad JSON → error.
	bad := filepath.Join(dir, "bad.json")
	mustWrite(t, bad, `{not json`)
	if _, err := loadCapabilityToken(bad); err == nil {
		t.Fatal("expected error for malformed token JSON")
	}

	// Missing file → error.
	if _, err := loadCapabilityToken(filepath.Join(dir, "nope.json")); err == nil {
		t.Fatal("expected error for missing token file")
	}
}

func TestCertPoolFromFile(t *testing.T) {
	dir := t.TempDir()

	// Missing file → error.
	if _, err := certPoolFromFile(filepath.Join(dir, "nope.crt")); err == nil {
		t.Fatal("expected error for missing CA file")
	}

	// Non-PEM content → error (no parseable certs).
	garbage := filepath.Join(dir, "garbage.crt")
	mustWrite(t, garbage, "not a pem")
	if _, err := certPoolFromFile(garbage); err == nil {
		t.Fatal("expected error for unparseable CA file")
	}

	// Valid self-signed cert PEM → pool.
	good := filepath.Join(dir, "ca.crt")
	mustWrite(t, good, selfSignedCertPEM(t))
	if _, err := certPoolFromFile(good); err != nil {
		t.Fatalf("valid CA file: %v", err)
	}
}

func TestA2ACallCmd_RequiresFlags(t *testing.T) {
	// Missing all required flags → error before any network/cert work.
	cmd := a2aCallCmd()
	cmd.SetArgs([]string{})
	cmd.SilenceUsage = true
	cmd.SilenceErrors = true
	if err := cmd.Execute(); err == nil {
		t.Fatal("expected error when --peer-url/--skill/--token-file are unset")
	}

	// Only peer-url set → still errors (skill + token-file missing).
	cmd = a2aCallCmd()
	cmd.SetArgs([]string{"--peer-url", "https://127.0.0.1:7777"})
	cmd.SilenceUsage = true
	cmd.SilenceErrors = true
	if err := cmd.Execute(); err == nil {
		t.Fatal("expected error when --skill/--token-file are unset")
	}
}

// --- helpers -----------------------------------------------------------------

func mustWrite(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

// selfSignedCertPEM mints a throwaway self-signed cert (test fixture only) so
// certPoolFromFile has parseable PEM to load.
func selfSignedCertPEM(t *testing.T) string {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "test-ca"},
		NotBefore:    time.Unix(0, 0),
		NotAfter:     time.Unix(1<<31-1, 0),
		IsCA:         true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
}
