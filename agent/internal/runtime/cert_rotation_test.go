package runtime

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/powernode/platform/extensions/system/agent/internal/enroll"
	"github.com/powernode/platform/extensions/system/agent/internal/transport"
)

// mintCert returns a self-signed Ed25519 cert + key PEM with the
// caller-specified validity window. Used to seed the on-disk PKI for
// test setup AND to build the response body the test server returns
// during a simulated rotation.
func mintCert(t *testing.T, subject string, notBefore, notAfter time.Time) (certPEM, keyPEM []byte) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("genkey: %v", err)
	}
	tmpl := x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()),
		Subject:      pkix.Name{CommonName: subject},
		NotBefore:    notBefore,
		NotAfter:     notAfter,
		KeyUsage:     x509.KeyUsageDigitalSignature,
	}
	der, err := x509.CreateCertificate(rand.Reader, &tmpl, &tmpl, pub, priv)
	if err != nil {
		t.Fatalf("create cert: %v", err)
	}
	certPEM = pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyDER, err := x509.MarshalPKCS8PrivateKey(priv)
	if err != nil {
		t.Fatalf("marshal key: %v", err)
	}
	keyPEM = pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER})
	return certPEM, keyPEM
}

// writePKIFiles seeds a directory with the cert/key/chain/bundle
// files transport.LoadFromPKIDir expects. Returns PKIPaths pointing at
// the seeded dir.
func writePKIFiles(t *testing.T, dir, subject string, notBefore, notAfter time.Time) enroll.PKIPaths {
	t.Helper()
	certPEM, keyPEM := mintCert(t, subject, notBefore, notAfter)

	paths := enroll.PathsUnder(dir)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	mustWrite(t, paths.Cert, certPEM, 0o644)
	mustWrite(t, paths.Key, keyPEM, 0o600)
	mustWrite(t, paths.CAChain, certPEM, 0o644)  // self-signed; chain = leaf
	mustWrite(t, paths.CABundle, certPEM, 0o644) // same for tests
	mustWrite(t, paths.Meta, []byte(`{"instance_id":"test-instance"}`), 0o644)
	return paths
}

func mustWrite(t *testing.T, path string, body []byte, mode os.FileMode) {
	t.Helper()
	if err := os.WriteFile(path, body, mode); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

func TestRefreshDeadline(t *testing.T) {
	notBefore := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	notAfter := time.Date(2026, 1, 11, 0, 0, 0, 0, time.UTC) // 10 days

	certPEM, _ := mintCert(t, "subject", notBefore, notAfter)
	block, _ := pem.Decode(certPEM)
	cert, _ := x509.ParseCertificate(block.Bytes)

	got := refreshDeadline(cert, 0.75)
	want := notBefore.Add(time.Duration(7.5 * float64(24*time.Hour)))
	if !got.Equal(want) {
		t.Errorf("refreshDeadline: got %v want %v", got, want)
	}
}

func TestNewCertRotatorRequiresFields(t *testing.T) {
	cases := []struct {
		name string
		mut  func(*CertRotator)
	}{
		{"missing PKIPaths.Cert", func(r *CertRotator) { r.PKIPaths.Cert = "" }},
		{"missing PlatformURL", func(r *CertRotator) { r.PlatformURL = "" }},
		{"missing Transport", func(r *CertRotator) { r.Transport = nil }},
		{"missing Subject", func(r *CertRotator) { r.Subject = "" }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			base := &CertRotator{
				PKIPaths:    enroll.PathsUnder("/tmp"),
				PlatformURL: "https://platform",
				Transport:   transport.NewSwappableClient(&transport.Client{}),
				Subject:     "subj",
			}
			tc.mut(base)
			if _, err := NewCertRotator(base); err == nil {
				t.Errorf("expected error for %s", tc.name)
			}
		})
	}
}

func TestNewCertRotatorAppliesDefaults(t *testing.T) {
	r, err := NewCertRotator(&CertRotator{
		PKIPaths:    enroll.PathsUnder("/tmp"),
		PlatformURL: "https://platform",
		Transport:   transport.NewSwappableClient(&transport.Client{}),
		Subject:     "subj",
	})
	if err != nil {
		t.Fatalf("NewCertRotator: %v", err)
	}
	if r.RefreshAt != defaultRefreshAt {
		t.Errorf("RefreshAt: got %v", r.RefreshAt)
	}
	if r.CheckInterval != defaultCheckInterval {
		t.Errorf("CheckInterval: got %v", r.CheckInterval)
	}
	if r.Now == nil {
		t.Errorf("Now should default to time.Now")
	}
	if r.OnError == nil {
		t.Errorf("OnError should default to noop")
	}
}

func TestCheckAndRotateNoOpsWhenFresh(t *testing.T) {
	dir := t.TempDir()
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	// Cert is fresh — issued just now, expires in 90 days.
	paths := writePKIFiles(t, dir, "subj", now, now.Add(90*24*time.Hour))

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Errorf("rotation endpoint should NOT be called for fresh cert")
		w.WriteHeader(500)
	}))
	defer srv.Close()

	c := &transport.Client{Client: srv.Client(), PlatformURL: srv.URL}
	swap := transport.NewSwappableClient(c)

	r, _ := NewCertRotator(&CertRotator{
		PKIPaths:    paths,
		PlatformURL: srv.URL,
		Transport:   swap,
		Subject:     "subj",
		Now:         func() time.Time { return now.Add(time.Hour) }, // 1h after issue, way before 75% of 90d
	})
	if err := r.CheckAndRotate(testCtx()); err != nil {
		t.Errorf("CheckAndRotate fresh cert: %v", err)
	}
}

func TestCheckAndRotateRotatesWhenPastRefreshAt(t *testing.T) {
	dir := t.TempDir()
	notBefore := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	notAfter := notBefore.Add(10 * 24 * time.Hour) // 10-day cert
	paths := writePKIFiles(t, dir, "subj", notBefore, notAfter)

	// Mint the cert the platform will return as the rotation response.
	newNotBefore := notBefore.Add(8 * 24 * time.Hour)
	newNotAfter := newNotBefore.Add(10 * 24 * time.Hour)
	newCertPEM, _ := mintCert(t, "subj", newNotBefore, newNotAfter)

	var hits int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		if r.URL.Path != rotationEndpoint {
			t.Errorf("path: got %q", r.URL.Path)
		}
		body, _ := io.ReadAll(r.Body)
		var got map[string]string
		json.Unmarshal(body, &got)
		if !strings.Contains(got["csr_pem"], "CERTIFICATE REQUEST") {
			t.Errorf("expected CSR in body, got %v", got)
		}

		w.Header().Set("Content-Type", "application/json")
		resp := map[string]any{
			"success": true,
			"data": map[string]any{
				"cert_pem":       string(newCertPEM),
				"ca_chain_pem":   string(newCertPEM),
				"instance_id":    "test-instance",
				"mtls_subject":   "subj",
				"not_after":      newNotAfter.Format(time.RFC3339),
				"certificate_id": "cert-2",
				"instance_token": "fresh-token",
			},
		}
		json.NewEncoder(w).Encode(resp)
	}))
	defer srv.Close()

	c := &transport.Client{Client: srv.Client(), PlatformURL: srv.URL}
	swap := transport.NewSwappableClient(c)
	originalInner := swap.Get()

	// Stub BuildTransport: real LoadFromPKIDir would fail because the
	// test server returns a cert NOT signed against the rotator's
	// locally-generated CSR (a fully-faithful test would require the
	// test server to mint a matching cert; we keep the test focused
	// on the rotator's orchestration). The fake new client lets us
	// observe the swap without the TLS pairing check.
	stubBuild := func(string, enroll.PKIPaths) (*transport.Client, error) {
		return &transport.Client{Client: srv.Client(), PlatformURL: srv.URL + "/rotated"}, nil
	}

	// "Now" = day 8 of 10-day cert: 80% of lifetime, past 75% RefreshAt.
	r, _ := NewCertRotator(&CertRotator{
		PKIPaths:       paths,
		PlatformURL:    srv.URL,
		Transport:      swap,
		Subject:        "subj",
		AgentVersion:   "test",
		Now:            func() time.Time { return notBefore.Add(8 * 24 * time.Hour) },
		BuildTransport: stubBuild,
	})
	if err := r.CheckAndRotate(testCtx()); err != nil {
		t.Fatalf("CheckAndRotate: %v", err)
	}

	if hits != 1 {
		t.Errorf("expected 1 rotation request, got %d", hits)
	}

	// New cert written to disk.
	got, err := os.ReadFile(paths.Cert)
	if err != nil {
		t.Fatalf("read new cert: %v", err)
	}
	if string(got) != string(newCertPEM) {
		t.Errorf("cert on disk doesn't match rotation response")
	}

	// Transport was swapped — Get() returns a different *Client.
	if swap.Get() == originalInner {
		t.Errorf("SwappableClient was not swapped")
	}
	if swap.Get().PlatformURL != srv.URL+"/rotated" {
		t.Errorf("new transport's PlatformURL: %q", swap.Get().PlatformURL)
	}
}

func TestCheckAndRotateSurfacesPlatformError(t *testing.T) {
	dir := t.TempDir()
	notBefore := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	notAfter := notBefore.Add(10 * 24 * time.Hour)
	paths := writePKIFiles(t, dir, "subj", notBefore, notAfter)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, `{"success":false,"error":"cert revoked"}`, 401)
	}))
	defer srv.Close()

	c := &transport.Client{Client: srv.Client(), PlatformURL: srv.URL}
	swap := transport.NewSwappableClient(c)
	r, _ := NewCertRotator(&CertRotator{
		PKIPaths:    paths,
		PlatformURL: srv.URL,
		Transport:   swap,
		Subject:     "subj",
		Now:         func() time.Time { return notBefore.Add(9 * 24 * time.Hour) },
	})
	err := r.CheckAndRotate(testCtx())
	if err == nil {
		t.Errorf("expected error for 401")
	}
	if !strings.Contains(err.Error(), "401") {
		t.Errorf("expected status in error: %v", err)
	}

	// Original cert remains on disk — rotation didn't half-complete.
	got, _ := os.ReadFile(paths.Cert)
	if !strings.Contains(string(got), "CERTIFICATE") {
		t.Errorf("cert disappeared after failed rotation")
	}
}

func TestCheckAndRotateRejectsMissingCertOnDisk(t *testing.T) {
	dir := t.TempDir()
	paths := enroll.PathsUnder(dir)
	r, _ := NewCertRotator(&CertRotator{
		PKIPaths:    paths,
		PlatformURL: "https://platform",
		Transport:   transport.NewSwappableClient(&transport.Client{}),
		Subject:     "subj",
	})
	if err := r.CheckAndRotate(testCtx()); err == nil {
		t.Errorf("expected error for missing cert")
	}
}

func TestCheckAndRotateBadResponseRejected(t *testing.T) {
	dir := t.TempDir()
	notBefore := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	notAfter := notBefore.Add(time.Hour)
	paths := writePKIFiles(t, dir, "subj", notBefore, notAfter)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Return success=true but no cert_pem.
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"success": true, "data": map[string]any{}})
	}))
	defer srv.Close()

	c := &transport.Client{Client: srv.Client(), PlatformURL: srv.URL}
	swap := transport.NewSwappableClient(c)
	r, _ := NewCertRotator(&CertRotator{
		PKIPaths:    paths,
		PlatformURL: srv.URL,
		Transport:   swap,
		Subject:     "subj",
		Now:         func() time.Time { return notBefore.Add(40 * time.Minute) }, // ~67% of 1h, past 75%? no...
	})
	// Force the "past refresh" path: use Now after notBefore + 75%.
	r.Now = func() time.Time { return notBefore.Add(50 * time.Minute) }
	err := r.CheckAndRotate(testCtx())
	if err == nil {
		t.Errorf("expected error for missing cert_pem")
	}
}

// testCtx is a small helper to keep test signatures terse.
func testCtx() context.Context { return context.Background() }
