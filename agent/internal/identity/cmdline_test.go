package identity

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// selfSignedPEM returns a self-signed CA PEM and its pin.
func selfSignedPEM(t *testing.T, cn string) (string, string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tpl := &x509.Certificate{
		SerialNumber:          big.NewInt(time.Now().UnixNano()),
		Subject:               pkix.Name{CommonName: cn},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(24 * time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign,
	}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	c, _ := x509.ParseCertificate(der)
	return string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})), CertFingerprint(c)
}

func writeCmdline(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "cmdline")
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func caServer(t *testing.T, body string, hits *int32) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if hits != nil {
			atomic.AddInt32(hits, 1)
		}
		fmt.Fprint(w, body)
	}))
	t.Cleanup(srv.Close)
	return srv
}

func cmdlineWith(extra string) string {
	return "console=ttyS0 powernode.instance_uuid=test-uuid-1 powernode.bootstrap_token=tok-xyz powernode.platform_url=https://p.example.com " + extra
}

func TestCmdlineCAPEMURLMatchingPinIsAccepted(t *testing.T) {
	ca, pin := selfSignedPEM(t, "ca-a")
	srv := caServer(t, ca, nil)
	s := &CmdlineStrategy{
		Path:   writeCmdline(t, cmdlineWith("powernode.ca_fingerprint="+pin+" powernode.ca_pem_url="+srv.URL+"/ca.pem")),
		Client: srv.Client(),
	}
	id, err := s.Discover(context.Background())
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}
	if id.CABundlePEM != ca || id.CAFingerprint != pin {
		t.Errorf("CA not adopted: pin=%q pem=%q", id.CAFingerprint, id.CABundlePEM)
	}
}

func TestCmdlineCAPEMURLMismatchIsTerminalRefusal(t *testing.T) {
	_, pin := selfSignedPEM(t, "ca-pinned")
	other, _ := selfSignedPEM(t, "ca-attacker")
	srv := caServer(t, other, nil)
	s := &CmdlineStrategy{
		Path:   writeCmdline(t, cmdlineWith("powernode.ca_fingerprint="+pin+" powernode.ca_pem_url="+srv.URL)),
		Client: srv.Client(),
	}
	id, err := s.Discover(context.Background())
	if id != nil || !errors.Is(err, ErrProvisionRefused) {
		t.Fatalf("want ErrProvisionRefused, got id=%v err=%v", id, err)
	}
}

func TestCmdlineMalformedPinIsRefusedAndNothingFetched(t *testing.T) {
	ca, _ := selfSignedPEM(t, "ca-b")
	var hits int32
	srv := caServer(t, ca, &hits)
	s := &CmdlineStrategy{
		Path:   writeCmdline(t, cmdlineWith("powernode.ca_fingerprint=sha256:zz powernode.ca_pem_url="+srv.URL)),
		Client: srv.Client(),
	}
	_, err := s.Discover(context.Background())
	if !errors.Is(err, ErrProvisionRefused) {
		t.Fatalf("want ErrProvisionRefused, got %v", err)
	}
	if atomic.LoadInt32(&hits) != 0 {
		t.Error("fetched despite a malformed pin")
	}
}

func TestCmdlineCAPEMURLWithoutPinIsRefusedAndNothingFetched(t *testing.T) {
	ca, _ := selfSignedPEM(t, "ca-c")
	var hits int32
	srv := caServer(t, ca, &hits)
	s := &CmdlineStrategy{
		Path:   writeCmdline(t, cmdlineWith("powernode.ca_pem_url="+srv.URL)),
		Client: srv.Client(),
	}
	_, err := s.Discover(context.Background())
	if !errors.Is(err, ErrProvisionRefused) {
		t.Fatalf("want ErrProvisionRefused, got %v", err)
	}
	if atomic.LoadInt32(&hits) != 0 {
		t.Error("fetched without a pin")
	}
}

func TestCmdlineCAPEMURLOversizeBodyIsRefused(t *testing.T) {
	ca, pin := selfSignedPEM(t, "ca-d")
	srv := caServer(t, ca+strings.Repeat("#", provisionMaxCAPEM+1), nil)
	s := &CmdlineStrategy{
		Path:   writeCmdline(t, cmdlineWith("powernode.ca_fingerprint="+pin+" powernode.ca_pem_url="+srv.URL)),
		Client: srv.Client(),
	}
	if _, err := s.Discover(context.Background()); !errors.Is(err, ErrProvisionRefused) {
		t.Fatalf("want ErrProvisionRefused for an oversize body, got %v", err)
	}
}

func TestCmdlineCAPEMURLBadSchemeIsRefused(t *testing.T) {
	_, pin := selfSignedPEM(t, "ca-e")
	s := &CmdlineStrategy{Path: writeCmdline(t, cmdlineWith("powernode.ca_fingerprint="+pin+" powernode.ca_pem_url=file:///etc/passwd"))}
	if _, err := s.Discover(context.Background()); !errors.Is(err, ErrProvisionRefused) {
		t.Fatalf("want ErrProvisionRefused, got %v", err)
	}
}

func TestCmdlineCAPEMURLFetchFailureIsNotAnAcceptance(t *testing.T) {
	_, pin := selfSignedPEM(t, "ca-f")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Error(w, "no", 500) }))
	defer srv.Close()
	s := &CmdlineStrategy{
		Path:   writeCmdline(t, cmdlineWith("powernode.ca_fingerprint="+pin+" powernode.ca_pem_url="+srv.URL)),
		Client: srv.Client(),
	}
	id, err := s.Discover(context.Background())
	if id != nil || err == nil {
		t.Fatalf("want an error and no identity, got id=%v err=%v", id, err)
	}
}

func TestCmdlineLegacyInlineCAPEMStillRead(t *testing.T) {
	s := &CmdlineStrategy{Path: writeCmdline(t, cmdlineWith("powernode.ca_pem=LEGACY"))}
	id, err := s.Discover(context.Background())
	if err != nil || id.CABundlePEM != "LEGACY" {
		t.Fatalf("legacy ca_pem lost: id=%v err=%v", id, err)
	}
}
