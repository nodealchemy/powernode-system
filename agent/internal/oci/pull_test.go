package oci

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type stubClient struct {
	resp *http.Response
	err  error
	path string
}

func (s *stubClient) GetJSON(path string) (*http.Response, error) {
	s.path = path
	if s.err != nil {
		return nil, s.err
	}
	return s.resp, nil
}

func makeJSONResp(status int, body string) *http.Response {
	return &http.Response{
		StatusCode: status,
		Body:       io.NopCloser(strings.NewReader(body)),
	}
}

func sha256Hex(data []byte) string {
	h := sha256.Sum256(data)
	return hex.EncodeToString(h[:])
}

func TestFetchManifestSuccess(t *testing.T) {
	body := `{
		"success": true,
		"data": {
			"file": {"name": "module.cfs", "size": 1024, "checksum": "abc",
			         "download_url": "/files/modules/m1"},
			"oci": {"ref": "registry.example/mod@sha256:def", "digest": "sha256:def"}
		}
	}`
	c := &stubClient{resp: makeJSONResp(200, body)}
	p := &Puller{Transport: c, Cache: t.TempDir()}

	ref, err := p.FetchManifest("m1")
	if err != nil {
		t.Fatalf("FetchManifest: %v", err)
	}
	if ref.Digest != "def" {
		t.Errorf("Digest: got %q want %q", ref.Digest, "def")
	}
	if ref.OCIRef != "registry.example/mod@sha256:def" {
		t.Errorf("OCIRef: got %q", ref.OCIRef)
	}
	if ref.DownloadURL != "/files/modules/m1" {
		t.Errorf("DownloadURL: got %q", ref.DownloadURL)
	}
	if ref.Size != 1024 {
		t.Errorf("Size: got %d", ref.Size)
	}
}

func TestFetchManifestFallsBackToChecksum(t *testing.T) {
	// No oci.digest, but file.checksum present — use checksum as digest.
	body := `{"success": true, "data": {
		"file": {"name": "m.cfs", "size": 100, "checksum": "abc123",
		         "download_url": "/files/modules/m2"},
		"oci": {}
	}}`
	c := &stubClient{resp: makeJSONResp(200, body)}
	p := &Puller{Transport: c, Cache: t.TempDir()}

	ref, err := p.FetchManifest("m2")
	if err != nil {
		t.Fatalf("FetchManifest: %v", err)
	}
	if ref.Digest != "abc123" {
		t.Errorf("Digest: got %q want abc123", ref.Digest)
	}
}

func TestFetchManifestNoDigestErrors(t *testing.T) {
	body := `{"success": true, "data": {
		"file": {"name": "m.cfs"}, "oci": {}
	}}`
	c := &stubClient{resp: makeJSONResp(200, body)}
	p := &Puller{Transport: c, Cache: t.TempDir()}

	if _, err := p.FetchManifest("m3"); err == nil {
		t.Errorf("expected error for missing digest")
	}
}

func TestFetchManifestPathFormat(t *testing.T) {
	c := &stubClient{resp: makeJSONResp(200, `{"data":{"file":{"checksum":"a"}}}`)}
	p := &Puller{Transport: c, Cache: t.TempDir()}

	_, _ = p.FetchManifest("module-uuid-1")
	if c.path != "/api/v1/system/node_api/modules/module-uuid-1/download" {
		t.Errorf("path: got %q", c.path)
	}
}

func TestPullStreamsAndVerifies(t *testing.T) {
	payload := []byte("composefs blob content goes here")
	digest := sha256Hex(payload)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Write(payload)
	}))
	defer srv.Close()

	cache := t.TempDir()
	p := &Puller{
		HTTPClient:  srv.Client(),
		PlatformURL: srv.URL,
		Cache:       cache,
	}
	ref := &ModuleArtifactRef{
		ModuleID:    "mod-1",
		Digest:      digest,
		DownloadURL: "/blob/test",
		Size:        int64(len(payload)),
	}

	cfsPath, bundlePath, err := p.Pull(ref)
	if err != nil {
		t.Fatalf("Pull: %v", err)
	}
	got, err := os.ReadFile(cfsPath)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if string(got) != string(payload) {
		t.Errorf("payload mismatch")
	}
	if !strings.HasSuffix(cfsPath, digest+".cfs") {
		t.Errorf("cfsPath: %q does not end with digest.cfs", cfsPath)
	}
	if !strings.HasSuffix(bundlePath, digest+".cosign-bundle") {
		t.Errorf("bundlePath: %q", bundlePath)
	}
}

func TestPullDigestMismatchDeletesTmp(t *testing.T) {
	payload := []byte("real content")
	wrongDigest := strings.Repeat("0", 64)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write(payload)
	}))
	defer srv.Close()

	cache := t.TempDir()
	p := &Puller{HTTPClient: srv.Client(), PlatformURL: srv.URL, Cache: cache}
	ref := &ModuleArtifactRef{
		ModuleID:    "mod-bad",
		Digest:      wrongDigest,
		DownloadURL: "/blob/bad",
	}
	if _, _, err := p.Pull(ref); err == nil {
		t.Errorf("expected digest mismatch error")
	}

	// Cache dir must contain no leftover .tmp or .cfs file from the failed pull.
	entries, _ := os.ReadDir(cache)
	for _, e := range entries {
		if strings.Contains(e.Name(), ".tmp") {
			t.Errorf("temp file leaked: %s", e.Name())
		}
		if strings.HasSuffix(e.Name(), ".cfs") {
			t.Errorf("cfs file should not exist after digest mismatch: %s", e.Name())
		}
	}
}

func TestPullIdempotentReturnsCached(t *testing.T) {
	payload := []byte("the good payload")
	digest := sha256Hex(payload)
	cache := t.TempDir()

	// Pre-seed cache file at the expected path.
	digestFs := sanitizeDigest(digest)
	cached := filepath.Join(cache, digestFs+".cfs")
	if err := os.WriteFile(cached, payload, 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}

	hits := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		w.Write(payload)
	}))
	defer srv.Close()

	p := &Puller{HTTPClient: srv.Client(), PlatformURL: srv.URL, Cache: cache}
	ref := &ModuleArtifactRef{ModuleID: "m", Digest: digest, DownloadURL: "/blob/x"}

	if _, _, err := p.Pull(ref); err != nil {
		t.Fatalf("Pull: %v", err)
	}
	if hits != 0 {
		t.Errorf("expected idempotent cache hit; server got %d hits", hits)
	}
}

func TestPullEmptyRefRejected(t *testing.T) {
	p := &Puller{Cache: t.TempDir()}
	if _, _, err := p.Pull(&ModuleArtifactRef{}); err == nil {
		t.Errorf("expected error for empty digest")
	}
}

func TestPullMissingURLRejected(t *testing.T) {
	p := &Puller{Cache: t.TempDir()}
	ref := &ModuleArtifactRef{Digest: "abc", ModuleID: "m"}
	if _, _, err := p.Pull(ref); err == nil {
		t.Errorf("expected error for missing download_url + PlatformURL")
	}
}

func TestPullSizeMismatchRejects(t *testing.T) {
	payload := []byte("content")
	digest := sha256Hex(payload)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write(payload)
	}))
	defer srv.Close()

	p := &Puller{HTTPClient: srv.Client(), PlatformURL: srv.URL, Cache: t.TempDir()}
	ref := &ModuleArtifactRef{
		ModuleID:    "m",
		Digest:      digest,
		DownloadURL: "/blob/x",
		Size:        9999, // wrong size
	}
	if _, _, err := p.Pull(ref); err == nil {
		t.Errorf("expected size mismatch error")
	}
}

func TestAbsoluteURL(t *testing.T) {
	cases := []struct {
		base, in, want string
	}{
		{"https://api.example.com", "/files/m", "https://api.example.com/files/m"},
		{"https://api.example.com/", "files/m", "https://api.example.com/files/m"},
		{"https://api.example.com", "https://other/m", "https://other/m"},
		{"", "https://other/m", "https://other/m"},
		{"", "/relative", ""},
		{"https://api.example.com", "", ""},
	}
	for _, tc := range cases {
		got := absoluteURL(tc.base, tc.in)
		if got != tc.want {
			t.Errorf("absoluteURL(%q, %q): got %q want %q", tc.base, tc.in, got, tc.want)
		}
	}
}
