package enroll

import (
	"context"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestGenerateKeypair_BuildCSR_RoundTrip(t *testing.T) {
	kp, err := GenerateKeypair()
	if err != nil {
		t.Fatalf("GenerateKeypair: %v", err)
	}
	if len(kp.Private) == 0 || len(kp.Public) == 0 {
		t.Fatal("empty keypair")
	}

	subject := "test-instance-uuid-1234"
	csrPEM, err := BuildCSR(kp, subject)
	if err != nil {
		t.Fatalf("BuildCSR: %v", err)
	}

	block, _ := pem.Decode(csrPEM)
	if block == nil || block.Type != "CERTIFICATE REQUEST" {
		t.Fatalf("CSR PEM block type = %q", block.Type)
	}
	csr, err := x509.ParseCertificateRequest(block.Bytes)
	if err != nil {
		t.Fatalf("ParseCertificateRequest: %v", err)
	}
	if csr.Subject.CommonName != subject {
		t.Errorf("CSR CN = %q, want %q", csr.Subject.CommonName, subject)
	}
	if err := csr.CheckSignature(); err != nil {
		t.Fatalf("CSR self-signature did not verify: %v", err)
	}
}

func TestBuildCSR_RejectsEmptyArgs(t *testing.T) {
	if _, err := BuildCSR(nil, "x"); err == nil {
		t.Error("expected error on nil keypair")
	}
	kp, _ := GenerateKeypair()
	if _, err := BuildCSR(kp, ""); err == nil {
		t.Error("expected error on empty subject")
	}
}

func TestPrivatePEM(t *testing.T) {
	kp, _ := GenerateKeypair()
	pemBytes, err := kp.PrivatePEM()
	if err != nil {
		t.Fatalf("PrivatePEM: %v", err)
	}
	block, _ := pem.Decode(pemBytes)
	if block == nil || block.Type != "PRIVATE KEY" {
		t.Fatalf("PrivatePEM block type = %q", block.Type)
	}
	if _, err := x509.ParsePKCS8PrivateKey(block.Bytes); err != nil {
		t.Errorf("ParsePKCS8PrivateKey: %v", err)
	}
}

// fakePlatform is an httptest server that mimics the platform's enrollment
// endpoint. Returns success-shaped responses for valid tokens, 422 for
// invalid ones.
func fakePlatform(t *testing.T, validToken string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/api/v1/system/node_api/enroll" {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		var body struct {
			BootstrapToken string `json:"bootstrap_token"`
			CSRPEM         string `json:"csr_pem"`
			AgentVersion   string `json:"agent_version"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, "bad body", http.StatusBadRequest)
			return
		}
		if body.BootstrapToken != validToken {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(422)
			_, _ = w.Write([]byte(`{"success":false,"error":"invalid token","code":"UNPROCESSABLE_ENTITY"}`))
			return
		}
		if !strings.Contains(body.CSRPEM, "BEGIN CERTIFICATE REQUEST") {
			w.WriteHeader(422)
			_, _ = w.Write([]byte(`{"success":false,"error":"missing csr"}`))
			return
		}

		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{
		  "success": true,
		  "data": {
		    "cert_pem": "-----BEGIN CERTIFICATE-----\nFAKEFAKEFAKE\n-----END CERTIFICATE-----\n",
		    "ca_chain_pem": "-----BEGIN CERTIFICATE-----\nFAKE-CA-FAKE\n-----END CERTIFICATE-----\n",
		    "instance_id": "fake-instance-uuid",
		    "mtls_subject": "fake-instance-uuid",
		    "not_after": "2026-12-31T23:59:59Z",
		    "certificate_id": "fake-cert-id"
		  }
		}`))
	}))
}

// caPEMForFakePlatform extracts the test server's TLS cert as a PEM bundle
// the Client can trust. Used only for the production-shaped buildHTTPClient
// test below; httptest.Server (HTTP, not HTTPS) doesn't need this.
func caPEMForFakePlatform(srv *httptest.Server) []byte {
	if srv.Certificate() == nil {
		return nil
	}
	return pem.EncodeToMemory(&pem.Block{
		Type:  "CERTIFICATE",
		Bytes: srv.Certificate().Raw,
	})
}

func TestClient_Enroll_HappyPath(t *testing.T) {
	srv := fakePlatform(t, "good-token")
	defer srv.Close()

	c := &Client{
		PlatformURL:  srv.URL,
		CABundlePEM:  []byte("dummy"), // bypassed when HTTPClient overridden
		AgentVersion: "test-0.1",
		HTTPClient:   srv.Client(),    // httptest provides one
	}
	id, err := c.Enroll(context.Background(), EnrollRequest{
		BootstrapToken: "good-token",
		Subject:        "test-instance-uuid",
		DMIUUID:        "dmi-1234",
	})
	if err != nil {
		t.Fatalf("Enroll: %v", err)
	}
	if id.InstanceID != "fake-instance-uuid" {
		t.Errorf("InstanceID = %q", id.InstanceID)
	}
	if !strings.Contains(string(id.CertPEM), "BEGIN CERTIFICATE") {
		t.Errorf("CertPEM = %q", id.CertPEM)
	}
	if id.NotAfter.IsZero() {
		t.Errorf("NotAfter should have parsed RFC3339")
	}
}

func TestClient_Enroll_BadToken(t *testing.T) {
	srv := fakePlatform(t, "good-token")
	defer srv.Close()

	c := &Client{
		PlatformURL: srv.URL, CABundlePEM: []byte("dummy"), HTTPClient: srv.Client(),
	}
	_, err := c.Enroll(context.Background(), EnrollRequest{
		BootstrapToken: "wrong-token", Subject: "x",
	})
	if err == nil || !strings.Contains(err.Error(), "validation failed") {
		t.Errorf("expected validation failure, got %v", err)
	}
}

func TestClient_Enroll_RejectsEmptyArgs(t *testing.T) {
	c := &Client{}
	if _, err := c.Enroll(context.Background(), EnrollRequest{}); err == nil {
		t.Error("expected error with empty Client + Request")
	}

	c2 := &Client{PlatformURL: "https://x", CABundlePEM: []byte("y")}
	if _, err := c2.Enroll(context.Background(), EnrollRequest{}); err == nil {
		t.Error("expected error with empty token + subject")
	}
}

func TestClient_buildHTTPClient_RejectsBadCA(t *testing.T) {
	c := &Client{PlatformURL: "https://x", CABundlePEM: []byte("not a CA")}
	if _, err := c.buildHTTPClient(); err == nil {
		t.Error("expected error on unparseable CA")
	}
}

func TestSave_WritesAllFiles(t *testing.T) {
	dir := t.TempDir()
	paths := PathsUnder(dir)

	kp, _ := GenerateKeypair()
	id := &EnrolledIdentity{
		Keypair:       kp,
		CertPEM:       []byte("CERT-PEM"),
		CAChainPEM:    []byte("CA-CHAIN"),
		CABundlePEM:   []byte("CA-BUNDLE"),
		InstanceID:    "inst-1",
		MTLSSubject:   "inst-1",
		CertificateID: "cert-1",
	}
	if err := Save(id, paths); err != nil {
		t.Fatalf("Save: %v", err)
	}

	for label, p := range map[string]string{
		"key": paths.Key, "cert": paths.Cert, "ca_chain": paths.CAChain,
		"ca_bundle": paths.CABundle, "meta": paths.Meta,
	} {
		fi, err := os.Stat(p)
		if err != nil {
			t.Errorf("Save did not write %s (%s): %v", label, p, err)
			continue
		}
		if fi.Mode().Perm() == 0 {
			t.Errorf("%s has zero permissions", label)
		}
	}
	// Key file should be 0600
	if fi, err := os.Stat(paths.Key); err == nil && fi.Mode().Perm() != 0o600 {
		t.Errorf("key mode = %v, want 0600", fi.Mode().Perm())
	}

	// Round-trip the meta JSON
	metaBytes, _ := os.ReadFile(paths.Meta)
	if !strings.Contains(string(metaBytes), `"instance_id":"inst-1"`) {
		t.Errorf("meta missing instance_id; got: %s", metaBytes)
	}
}

// caPEMForFakePlatform / base64 imports are kept for completeness even if
// the current test suite doesn't exercise the TLS-pinning path against a
// real https httptest server. Adding that test is a small follow-up; for
// now buildHTTPClient is unit-covered for the rejection path.
var _ = caPEMForFakePlatform
var _ = filepath.Join
var _ = base64.StdEncoding
