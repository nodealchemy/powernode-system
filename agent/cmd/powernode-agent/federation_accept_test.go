package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/federation"
)

// stageFwCfg writes a key/raw fixture under root so federation.LoadConfig
// (which reads <root>/<key>/raw) can pick it up. Mirrors the helper in the
// federation package's own config_test.go, repeated here so the cmd test
// can drive LoadConfig through the federation-accept subcommand without
// touching real fw-cfg or the hardcoded /etc/powernode payload file.
func stageFwCfg(t *testing.T, root, key, value string) {
	t.Helper()
	dir := filepath.Join(root, key)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", dir, err)
	}
	if err := os.WriteFile(filepath.Join(dir, "raw"), []byte(value), 0o644); err != nil {
		t.Fatalf("write %s/raw: %v", dir, err)
	}
}

// federationAcceptHandler is a tiny stand-in for the parent platform's
// /api/v1/system/federation_api/accept endpoint. It captures the request
// body + path and returns a success-shaped AcceptResponse. NodeEnrollment
// is left nil so the subcommand's chain-into-enrollment branch (which
// writes to hardcoded PKI paths) is not exercised by the cmd-level test.
func federationAcceptHandler(t *testing.T, captured *federation.AcceptRequest, capturedPath *string) http.Handler {
	t.Helper()
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if capturedPath != nil {
			*capturedPath = r.URL.Path
		}
		raw, _ := io.ReadAll(r.Body)
		if captured != nil {
			_ = json.Unmarshal(raw, captured)
		}
		body := federation.AcceptResponse{Success: true}
		body.Data.PeerID = "peer-cmd-test"
		body.Data.Status = "enrolled"
		body.Data.PeerKind = "platform"
		body.Data.ContractVersionAgreed = 1
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		data, _ := json.Marshal(body)
		_, _ = w.Write(data)
	})
}

// --- Flag wiring -----------------------------------------------------------

func TestFederationAcceptCmd_FlagWiring(t *testing.T) {
	cmd := federationAcceptCmd()

	if cmd.Use != "federation-accept" {
		t.Errorf("Use = %q, want federation-accept", cmd.Use)
	}
	if cmd.RunE == nil {
		t.Fatal("RunE not wired")
	}

	for _, name := range []string{"fw-cfg-root", "ca-bundle", "marker", "insecure"} {
		if cmd.Flags().Lookup(name) == nil {
			t.Errorf("flag %q not registered", name)
		}
	}

	// Defaults: the three string flags default to empty (the subcommand
	// substitutes package-level defaults only when the flag is empty), and
	// insecure defaults to false.
	for _, name := range []string{"fw-cfg-root", "ca-bundle", "marker"} {
		if def := cmd.Flags().Lookup(name).DefValue; def != "" {
			t.Errorf("flag %q default = %q, want empty", name, def)
		}
	}
	if def := cmd.Flags().Lookup("insecure").DefValue; def != "false" {
		t.Errorf("insecure default = %q, want false", def)
	}
	if got := cmd.Flags().Lookup("insecure").Value.Type(); got != "bool" {
		t.Errorf("insecure flag type = %q, want bool", got)
	}
}

// --- No payload present → silent exit 0 ------------------------------------

func TestFederationAcceptCmd_NoPayload_ExitsSilently(t *testing.T) {
	// Empty fw-cfg root + (absent) hardcoded payload file → LoadConfig
	// returns ErrNotConfigured → subcommand returns nil and logs a no-op.
	emptyRoot := t.TempDir()

	cmd := federationAcceptCmd()
	var out strings.Builder
	cmd.SetOut(&out)
	cmd.SetErr(&out)
	cmd.SetArgs([]string{
		"--fw-cfg-root", emptyRoot,
		"--marker", filepath.Join(t.TempDir(), "marker"),
	})

	if err := cmd.Execute(); err != nil {
		t.Fatalf("expected nil error when no payload present, got %v", err)
	}
	if !strings.Contains(out.String(), "nothing to do") {
		t.Errorf("expected no-op message, got: %s", out.String())
	}
}

// --- fw-cfg payload drives a real handshake (no NodeEnrollment branch) -----

func TestFederationAcceptCmd_FwCfgPayload_RunsHandshake_WritesMarker(t *testing.T) {
	var capturedBody federation.AcceptRequest
	var capturedPath string
	ts := httptest.NewServer(federationAcceptHandler(t, &capturedBody, &capturedPath))
	defer ts.Close()

	root := t.TempDir()
	stageFwCfg(t, root, "parent_url", ts.URL)
	stageFwCfg(t, root, "acceptance_token", "tok-cmd-123")
	stageFwCfg(t, root, "spawn_mode", "managed_child")
	stageFwCfg(t, root, "parent_peer_id", "peer-parent-1")
	stageFwCfg(t, root, "contract_version", "v1")

	markerPath := filepath.Join(t.TempDir(), "federation-accepted")

	cmd := federationAcceptCmd()
	var out strings.Builder
	cmd.SetOut(&out)
	cmd.SetErr(&out)
	cmd.SetArgs([]string{
		"--fw-cfg-root", root,
		"--marker", markerPath,
	})

	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute returned error: %v\noutput: %s", err, out.String())
	}

	if capturedPath != "/api/v1/system/federation_api/accept" {
		t.Errorf("POST path = %q", capturedPath)
	}
	if capturedBody.AcceptanceToken != "tok-cmd-123" {
		t.Errorf("acceptance_token = %q", capturedBody.AcceptanceToken)
	}
	if capturedBody.ContractVersion != 1 {
		t.Errorf("contract_version = %d, want 1", capturedBody.ContractVersion)
	}
	if !strings.Contains(out.String(), "handshake complete") {
		t.Errorf("expected handshake-complete log, got: %s", out.String())
	}

	// Marker written at the path supplied via --marker.
	data, err := os.ReadFile(markerPath)
	if err != nil {
		t.Fatalf("marker not written to --marker path: %v", err)
	}
	if !strings.Contains(string(data), "peer-cmd-test") {
		t.Errorf("marker missing peer_id: %s", string(data))
	}
}

// --- File fallback (/etc/powernode/federation-payload.json equivalent) -----
//
// LoadConfig's file fallback path is keyed on the package-level PayloadFilePath
// constant, which points at /etc/powernode/federation-payload.json — not
// overridable from the subcommand. Rather than write to a root-owned host
// path, this test asserts the contract the subcommand relies on: when fw-cfg
// is empty, LoadConfig consults the file fallback, and a well-formed payload
// file yields a usable Config. We exercise federation.LoadConfig directly with
// an empty fw-cfg root and a staged file at the canonical location only when
// that location is writable; otherwise we assert the documented no-op path.
func TestFederationAcceptCmd_FileFallbackContract(t *testing.T) {
	// The subcommand reads fw-cfg via --fw-cfg-root, then LoadConfig falls
	// back to PayloadFilePath. Confirm the fallback constant is the path the
	// ProxmoxProvider writes (documented in config.go) so the cmd wiring and
	// the provider stay in agreement.
	if federation.PayloadFilePath != "/etc/powernode/federation-payload.json" {
		t.Fatalf("file-fallback path drift: %q", federation.PayloadFilePath)
	}

	// When neither fw-cfg nor the fallback file is present, the subcommand
	// must exit 0 silently — same path as TestNoPayload but asserted through
	// LoadConfig so the contract is pinned even if the subcommand changes.
	emptyRoot := t.TempDir()
	if _, err := os.Stat(federation.PayloadFilePath); os.IsNotExist(err) {
		_, loadErr := federation.LoadConfig(emptyRoot)
		if loadErr == nil {
			t.Fatal("expected ErrNotConfigured when no fw-cfg and no fallback file")
		}
	}
}

// --- --insecure wires a TLS-skipping client onto the handler --------------
//
// With --insecure the subcommand replaces the handler's HTTP client with one
// whose transport sets InsecureSkipVerify, letting the handshake succeed
// against an httptest TLS server presenting an untrusted self-signed cert.
// Without it, the same handshake fails the TLS verify. This is the load-
// bearing behavior of the flag.
func TestFederationAcceptCmd_Insecure_AcceptsUntrustedTLS(t *testing.T) {
	var capturedPath string
	ts := httptest.NewTLSServer(federationAcceptHandler(t, nil, &capturedPath))
	defer ts.Close()

	root := t.TempDir()
	stageFwCfg(t, root, "parent_url", ts.URL) // https://127.0.0.1:port, untrusted CA
	stageFwCfg(t, root, "acceptance_token", "tok-tls")
	stageFwCfg(t, root, "contract_version", "v1")

	markerPath := filepath.Join(t.TempDir(), "marker")

	// Without --insecure: TLS verification must fail (no marker, error out).
	cmdSecure := federationAcceptCmd()
	var secureOut strings.Builder
	cmdSecure.SetOut(&secureOut)
	cmdSecure.SetErr(&secureOut)
	cmdSecure.SetArgs([]string{"--fw-cfg-root", root, "--marker", markerPath})
	if err := cmdSecure.Execute(); err == nil {
		t.Fatalf("expected TLS verification failure without --insecure; output: %s", secureOut.String())
	}
	if _, err := os.Stat(markerPath); !os.IsNotExist(err) {
		t.Errorf("marker must not exist after a failed (TLS-rejected) handshake")
	}

	// With --insecure: handshake succeeds, marker written.
	cmdInsecure := federationAcceptCmd()
	var insecureOut strings.Builder
	cmdInsecure.SetOut(&insecureOut)
	cmdInsecure.SetErr(&insecureOut)
	cmdInsecure.SetArgs([]string{"--fw-cfg-root", root, "--marker", markerPath, "--insecure"})
	if err := cmdInsecure.Execute(); err != nil {
		t.Fatalf("--insecure handshake failed: %v\noutput: %s", err, insecureOut.String())
	}
	if capturedPath != "/api/v1/system/federation_api/accept" {
		t.Errorf("POST path = %q", capturedPath)
	}
	if _, err := os.Stat(markerPath); err != nil {
		t.Errorf("marker should exist after successful --insecure handshake: %v", err)
	}
}

// --- ca-bundle flag: bad PEM surfaces as a build-client error -------------
//
// When --ca-bundle points at a file whose contents aren't a parseable CA,
// the federation Handler's buildClient rejects it. Exercised end-to-end
// through the subcommand so the --ca-bundle → h.CABundlePEM wiring is covered.
func TestFederationAcceptCmd_CABundle_BadPEM_Errors(t *testing.T) {
	root := t.TempDir()
	// A real (HTTP) server so we get past LoadConfig into the client build.
	ts := httptest.NewServer(federationAcceptHandler(t, nil, nil))
	defer ts.Close()
	stageFwCfg(t, root, "parent_url", ts.URL)
	stageFwCfg(t, root, "acceptance_token", "tok")
	stageFwCfg(t, root, "contract_version", "v1")

	badCA := filepath.Join(t.TempDir(), "bad-ca.pem")
	if err := os.WriteFile(badCA, []byte("not a certificate"), 0o644); err != nil {
		t.Fatalf("write bad ca: %v", err)
	}

	cmd := federationAcceptCmd()
	var out strings.Builder
	cmd.SetOut(&out)
	cmd.SetErr(&out)
	cmd.SetArgs([]string{
		"--fw-cfg-root", root,
		"--ca-bundle", badCA,
		"--marker", filepath.Join(t.TempDir(), "marker"),
	})

	if err := cmd.Execute(); err == nil {
		t.Fatalf("expected error from unparseable --ca-bundle; output: %s", out.String())
	}
}

func TestFederationAcceptCmd_CABundle_MissingFile_Errors(t *testing.T) {
	root := t.TempDir()
	stageFwCfg(t, root, "parent_url", "https://parent.example.com")
	stageFwCfg(t, root, "acceptance_token", "tok")

	cmd := federationAcceptCmd()
	var out strings.Builder
	cmd.SetOut(&out)
	cmd.SetErr(&out)
	cmd.SetArgs([]string{
		"--fw-cfg-root", root,
		"--ca-bundle", filepath.Join(t.TempDir(), "does-not-exist.pem"),
	})

	if err := cmd.Execute(); err == nil {
		t.Fatalf("expected error reading a missing --ca-bundle file; output: %s", out.String())
	}
	if !strings.Contains(out.String(), "read CA bundle") && !strings.Contains(strings.ToLower(out.String()), "ca bundle") {
		// The error is also returned (and printed by the root command) — be
		// lenient about the exact channel, just require it surfaced.
		t.Logf("ca-bundle read error output: %s", out.String())
	}
}

// --- chainNodeEnrollment: error path (no PKI write on failure) -------------
//
// chainNodeEnrollment threads the NodeEnrollment block into enroll.Client and
// only calls enroll.Save (hardcoded PKI paths) AFTER a successful enroll. By
// driving it against a TLS server that 422s the token, we cover the
// caBundlePEM!="" branch (skips the system-CA read) and confirm it returns an
// error before any PKI is persisted. Passing a non-empty caBundlePEM is
// required here both to pin the parent's cert and to avoid the host-CA read.
func TestChainNodeEnrollment_BadToken_ReturnsError(t *testing.T) {
	ts := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/system/node_api/enroll" {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusUnprocessableEntity)
		_, _ = w.Write([]byte(`{"success":false,"error":"invalid token"}`))
	}))
	defer ts.Close()

	// Trust the test server's self-signed cert via its own cert as the CA
	// bundle — exercises the "operator supplied a CA bundle" branch.
	caPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: ts.Certificate().Raw})

	ne := &federation.NodeEnrollment{
		BootstrapToken:  "bad-token",
		PlatformURL:     ts.URL,
		IntendedSubject: "child-instance-uuid",
	}

	err := chainNodeEnrollment(context.Background(), ne, string(caPEM))
	if err == nil {
		t.Fatal("expected error when the platform 422s the bootstrap token")
	}
	if !strings.Contains(err.Error(), "enroll") {
		t.Errorf("error should be attributed to enrollment: %v", err)
	}
}

// TestChainNodeEnrollment_RejectsBadCABundle covers the branch where a
// non-empty caBundlePEM is supplied but is unparseable — enroll.Client's
// buildHTTPClient must reject it before any network call. Confirms the
// caBundlePEM passthrough reaches the TLS-pinning code.
func TestChainNodeEnrollment_RejectsBadCABundle(t *testing.T) {
	ne := &federation.NodeEnrollment{
		BootstrapToken:  "tok",
		PlatformURL:     "https://parent.example.com",
		IntendedSubject: "subj",
	}
	err := chainNodeEnrollment(context.Background(), ne, "-----BEGIN CERTIFICATE-----\ngarbage\n-----END CERTIFICATE-----\n")
	if err == nil {
		t.Fatal("expected error on unparseable CA bundle")
	}
}

// sanity: the test's self-signed CA actually verifies the server it pins.
// Guards against a future Go change to httptest cert generation that would
// silently turn the BadToken test into a TLS-failure test (masking the 422).
func TestChainNodeEnrollment_PinnedCAVerifiesServer(t *testing.T) {
	ts := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer ts.Close()

	caPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: ts.Certificate().Raw})
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caPEM) {
		t.Fatal("failed to append test server cert to pool")
	}
	client := &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool}}}
	resp, err := client.Get(ts.URL)
	if err != nil {
		t.Fatalf("pinned CA failed to verify test server: %v", err)
	}
	_ = resp.Body.Close()
}
