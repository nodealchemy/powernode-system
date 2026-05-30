package federation

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func acceptResponseBody(peerID, status string) []byte {
	body := AcceptResponse{Success: true}
	body.Data.PeerID = peerID
	body.Data.Status = status
	body.Data.PeerKind = "platform"
	body.Data.ContractVersionAgreed = 1
	body.Data.AcceptedAt = "2026-05-16T20:00:00Z"
	body.Data.HandshakeAt = "2026-05-16T20:00:00Z"
	data, _ := json.Marshal(body)
	return data
}

// acceptResponseBodyWithEnrollment returns a success body that also carries
// the optional node_enrollment block the parent includes for managed_child
// spawns. The cmd-level federation-accept subcommand reads Data.NodeEnrollment
// off the returned AcceptResponse to chain into node-api enrollment; the base
// acceptResponseBody never populates it, so this covers Run's parse of that
// branch.
func acceptResponseBodyWithEnrollment(peerID, token, platformURL, subject string) []byte {
	body := AcceptResponse{Success: true}
	body.Data.PeerID = peerID
	body.Data.Status = "enrolled"
	body.Data.PeerKind = "platform"
	body.Data.ContractVersionAgreed = 1
	body.Data.NodeEnrollment = &NodeEnrollment{
		BootstrapToken:  token,
		PlatformURL:     platformURL,
		IntendedSubject: subject,
		ExpiresAt:       "2026-05-16T22:00:00Z",
	}
	data, _ := json.Marshal(body)
	return data
}

func TestHandlerRun_HappyPath_WritesMarker(t *testing.T) {
	var capturedBody AcceptRequest
	var capturedPath string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		capturedPath = r.URL.Path
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &capturedBody)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(acceptResponseBody("peer-abc-123", "enrolled"))
	}))
	defer ts.Close()

	tmp := t.TempDir()
	markerPath := filepath.Join(tmp, "marker")

	h := &Handler{
		Client:     ts.Client(),
		MarkerPath: markerPath,
		Logf:       func(string, ...any) {},
	}
	cfg := &Config{
		ParentURL:       ts.URL,
		AcceptanceToken: "tok-xyz",
		SpawnMode:       "managed_child",
		ParentPeerID:    "peer-abc-123",
		ContractVersion: "v1",
	}

	if _, err := h.Run(context.Background(), cfg); err != nil {
		t.Fatalf("Run returned error: %v", err)
	}

	if capturedPath != "/api/v1/system/federation_api/accept" {
		t.Errorf("expected POST to /api/v1/system/federation_api/accept, got %s", capturedPath)
	}
	if capturedBody.AcceptanceToken != "tok-xyz" {
		t.Errorf("acceptance_token: got %q", capturedBody.AcceptanceToken)
	}
	if capturedBody.ContractVersion != 1 {
		t.Errorf("contract_version: got %d", capturedBody.ContractVersion)
	}

	// Marker must exist + contain peer_id
	data, err := os.ReadFile(markerPath)
	if err != nil {
		t.Fatalf("marker not written: %v", err)
	}
	if !strings.Contains(string(data), "peer-abc-123") {
		t.Errorf("marker missing peer_id: %s", string(data))
	}
}

func TestHandlerRun_ParsesNodeEnrollment_WhenPresent(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(acceptResponseBodyWithEnrollment(
			"peer-managed-1",
			"bootstrap-tok-abc",
			"https://parent.example.com",
			"child-instance-uuid-7",
		))
	}))
	defer ts.Close()

	h := &Handler{
		Client:     ts.Client(),
		MarkerPath: filepath.Join(t.TempDir(), "marker"),
		Logf:       func(string, ...any) {},
	}
	cfg := &Config{
		ParentURL:       ts.URL,
		AcceptanceToken: "tok",
		SpawnMode:       "managed_child",
		ContractVersion: "v1",
	}

	resp, err := h.Run(context.Background(), cfg)
	if err != nil {
		t.Fatalf("Run returned error: %v", err)
	}
	if resp == nil {
		t.Fatal("Run returned nil response on success")
	}
	// The whole point of returning the parsed response: the cmd layer reads
	// Data.NodeEnrollment to decide whether to chain into node-api enrollment.
	if resp.Data.NodeEnrollment == nil {
		t.Fatal("NodeEnrollment block was not parsed off the accept response")
	}
	ne := resp.Data.NodeEnrollment
	if ne.BootstrapToken != "bootstrap-tok-abc" {
		t.Errorf("BootstrapToken = %q", ne.BootstrapToken)
	}
	if ne.PlatformURL != "https://parent.example.com" {
		t.Errorf("PlatformURL = %q", ne.PlatformURL)
	}
	if ne.IntendedSubject != "child-instance-uuid-7" {
		t.Errorf("IntendedSubject = %q", ne.IntendedSubject)
	}
	if ne.ExpiresAt != "2026-05-16T22:00:00Z" {
		t.Errorf("ExpiresAt = %q", ne.ExpiresAt)
	}
}

func TestHandlerRun_NilNodeEnrollment_OnAutonomousPeer(t *testing.T) {
	// The base success body (no node_enrollment) is what autonomous_peer
	// spawns get — the cmd layer must see a nil NodeEnrollment and skip the
	// enrollment chain. This guards the absent-block path of the same parse.
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(acceptResponseBody("peer-autonomous-1", "enrolled"))
	}))
	defer ts.Close()

	h := &Handler{Client: ts.Client(), MarkerPath: filepath.Join(t.TempDir(), "marker")}
	cfg := &Config{ParentURL: ts.URL, AcceptanceToken: "tok", SpawnMode: "autonomous_peer"}

	resp, err := h.Run(context.Background(), cfg)
	if err != nil {
		t.Fatalf("Run returned error: %v", err)
	}
	if resp == nil {
		t.Fatal("Run returned nil response on success")
	}
	if resp.Data.NodeEnrollment != nil {
		t.Errorf("expected nil NodeEnrollment for autonomous_peer, got %+v", resp.Data.NodeEnrollment)
	}
}

func TestHandlerRun_Idempotent_WhenMarkerPresent(t *testing.T) {
	callCount := 0
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		callCount++
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(acceptResponseBody("never-called", "enrolled"))
	}))
	defer ts.Close()

	tmp := t.TempDir()
	markerPath := filepath.Join(tmp, "marker")
	// Pre-existing marker should short-circuit Run.
	if err := os.WriteFile(markerPath, []byte("{}"), 0o644); err != nil {
		t.Fatalf("seed marker: %v", err)
	}

	h := &Handler{Client: ts.Client(), MarkerPath: markerPath}
	cfg := &Config{ParentURL: ts.URL, AcceptanceToken: "tok"}

	if _, err := h.Run(context.Background(), cfg); err != nil {
		t.Fatalf("Run returned error: %v", err)
	}
	if callCount != 0 {
		t.Errorf("server should not have been called when marker present; got %d calls", callCount)
	}
}

func TestHandlerRun_ReturnsError_OnNon2xx(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"success":false,"error":"acceptance_token not recognized"}`))
	}))
	defer ts.Close()

	tmp := t.TempDir()
	markerPath := filepath.Join(tmp, "marker")

	h := &Handler{Client: ts.Client(), MarkerPath: markerPath}
	cfg := &Config{ParentURL: ts.URL, AcceptanceToken: "bad-tok"}

	_, err := h.Run(context.Background(), cfg)
	if err == nil {
		t.Fatalf("expected error on 401")
	}
	if !strings.Contains(err.Error(), "401") {
		t.Errorf("error should mention status code: %v", err)
	}
	// Marker must NOT exist after failure.
	if _, statErr := os.Stat(markerPath); !os.IsNotExist(statErr) {
		t.Errorf("marker should not exist after failed handshake")
	}
}

func TestHandlerRun_ReturnsError_OnNilConfig(t *testing.T) {
	h := NewHandler()
	h.MarkerPath = filepath.Join(t.TempDir(), "marker")
	if _, err := h.Run(context.Background(), nil); err == nil {
		t.Fatalf("expected error on nil config")
	}
}

func TestHandlerRun_ReturnsError_OnEmptyParentURL(t *testing.T) {
	h := NewHandler()
	h.MarkerPath = filepath.Join(t.TempDir(), "marker")
	cfg := &Config{AcceptanceToken: "tok"}
	if _, err := h.Run(context.Background(), cfg); err == nil {
		t.Fatalf("expected error on empty parent_url")
	}
}

func TestHandlerRun_HonorsCtxCancellation(t *testing.T) {
	// Server that blocks forever — ctx cancel should unblock the client.
	block := make(chan struct{})
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		<-block
	}))
	defer ts.Close()
	defer close(block)

	ctx, cancel := context.WithCancel(context.Background())
	cancel() // pre-cancel so the Do call fails fast

	h := &Handler{Client: ts.Client(), MarkerPath: filepath.Join(t.TempDir(), "marker")}
	cfg := &Config{ParentURL: ts.URL, AcceptanceToken: "tok"}

	_, err := h.Run(ctx, cfg)
	if err == nil {
		t.Fatalf("expected error on cancelled ctx")
	}
}

func TestHandlerRun_HandlesTrailingSlashOnParentURL(t *testing.T) {
	var capturedPath string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		capturedPath = r.URL.Path
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(acceptResponseBody("peer-xyz", "enrolled"))
	}))
	defer ts.Close()

	h := &Handler{Client: ts.Client(), MarkerPath: filepath.Join(t.TempDir(), "marker")}
	cfg := &Config{
		ParentURL:       ts.URL + "/",
		AcceptanceToken: "tok",
		ContractVersion: "v1",
	}

	if _, err := h.Run(context.Background(), cfg); err != nil {
		t.Fatalf("Run failed: %v", err)
	}
	if capturedPath != "/api/v1/system/federation_api/accept" {
		t.Errorf("unexpected path after slash trim: %s", capturedPath)
	}
}

func TestContractVersionInt(t *testing.T) {
	cases := map[string]int{
		"v1": 1, "V1": 1, "1": 1, "v2": 2, "V42": 42, "": 1, "bogus": 1,
	}
	for input, expected := range cases {
		if got := contractVersionInt(input); got != expected {
			t.Errorf("contractVersionInt(%q): expected %d, got %d", input, expected, got)
		}
	}
}
