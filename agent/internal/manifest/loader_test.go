package manifest

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
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

func makeResp(status int, body string) *http.Response {
	return &http.Response{
		StatusCode: status,
		Body:       io.NopCloser(strings.NewReader(body)),
	}
}

func TestFetchAndCacheRoundTrip(t *testing.T) {
	root := t.TempDir()
	body := `{
		"success": true,
		"data": {
			"id": "mod-1",
			"name": "nginx",
			"priority": 100,
			"effective_priority": 100,
			"digest": "sha256:aaaa",
			"init_start": "systemctl start nginx.service",
			"config": {"units": ["nginx.service", "php-fpm.service"]}
		}
	}`
	c := &stubClient{resp: makeResp(200, body)}

	m, err := FetchAndCache(c, root, "mod-1")
	if err != nil {
		t.Fatalf("FetchAndCache: %v", err)
	}
	if m.ID != "mod-1" || m.Name != "nginx" {
		t.Errorf("unexpected manifest: %+v", m)
	}
	if c.path != "/api/v1/system/node_api/modules/mod-1" {
		t.Errorf("path: %q", c.path)
	}

	// Cache file should exist.
	cached := filepath.Join(root, "mod-1", "manifest.json")
	if _, err := os.Stat(cached); err != nil {
		t.Errorf("cache file missing: %v", err)
	}

	// Round-trip via LoadFromDisk.
	got, err := LoadFromDisk(root, "mod-1")
	if err != nil {
		t.Fatalf("LoadFromDisk: %v", err)
	}
	if got.ID != m.ID || got.Name != m.Name {
		t.Errorf("disk read differs: %+v", got)
	}
}

func TestLoadFromDiskMissing(t *testing.T) {
	root := t.TempDir()
	_, err := LoadFromDisk(root, "nope")
	if !os.IsNotExist(err) {
		t.Errorf("expected ErrNotExist, got %v", err)
	}
}

func TestLoadOrFetchPrefersDisk(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "mod-2")
	os.MkdirAll(dir, 0o755)
	cached := Manifest{ID: "mod-2", Name: "from-disk"}
	body, _ := json.Marshal(cached)
	os.WriteFile(filepath.Join(dir, "manifest.json"), body, 0o644)

	c := &stubClient{err: errors.New("network down — should not be called")}
	m, err := LoadOrFetch(c, root, "mod-2", 0)
	if err != nil {
		t.Fatalf("LoadOrFetch: %v", err)
	}
	if m.Name != "from-disk" {
		t.Errorf("expected disk read, got %+v", m)
	}
	if c.path != "" {
		t.Errorf("client should not be called: path=%q", c.path)
	}
}

func TestLoadOrFetchFallsBackOnMissing(t *testing.T) {
	root := t.TempDir()
	body := `{"success":true,"data":{"id":"mod-3","name":"from-net"}}`
	c := &stubClient{resp: makeResp(200, body)}

	m, err := LoadOrFetch(c, root, "mod-3", 0)
	if err != nil {
		t.Fatalf("LoadOrFetch: %v", err)
	}
	if m.Name != "from-net" {
		t.Errorf("expected net fetch, got %+v", m)
	}
}

func TestLoadOrFetchStaleness(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "mod-4")
	os.MkdirAll(dir, 0o755)

	// Cache an old manifest.
	body, _ := json.Marshal(Manifest{ID: "mod-4", Name: "stale"})
	cachePath := filepath.Join(dir, "manifest.json")
	os.WriteFile(cachePath, body, 0o644)
	old := time.Now().Add(-1 * time.Hour)
	os.Chtimes(cachePath, old, old)

	netBody := `{"success":true,"data":{"id":"mod-4","name":"fresh"}}`
	c := &stubClient{resp: makeResp(200, netBody)}

	// staleAfter = 5min, cache is 1hr old → fetch.
	m, err := LoadOrFetch(c, root, "mod-4", 5*time.Minute)
	if err != nil {
		t.Fatalf("LoadOrFetch: %v", err)
	}
	if m.Name != "fresh" {
		t.Errorf("expected fresh fetch, got %+v", m)
	}
}

func TestUnitsExplicit(t *testing.T) {
	m := &Manifest{
		Config: map[string]any{
			"units": []any{"nginx.service", "php-fpm.service"},
		},
	}
	got := m.Units()
	if len(got) != 2 || got[0] != "nginx.service" || got[1] != "php-fpm.service" {
		t.Errorf("got %v", got)
	}
}

func TestUnitsLegacyParse(t *testing.T) {
	cases := []struct {
		in   string
		want []string
	}{
		{"systemctl start nginx.service", []string{"nginx.service"}},
		{"systemctl restart sshd", []string{"sshd"}},
		{"systemctl reload php-fpm", []string{"php-fpm"}},
		{"true && systemctl start a; systemctl start b", nil}, // too complex
		{"", nil},
		{"echo hi", nil},
	}
	for _, tc := range cases {
		m := &Manifest{InitStart: tc.in}
		got := m.Units()
		if len(got) != len(tc.want) {
			t.Errorf("Units(%q): got %v, want %v", tc.in, got, tc.want)
			continue
		}
		for i := range got {
			if got[i] != tc.want[i] {
				t.Errorf("Units(%q)[%d]: got %q, want %q", tc.in, i, got[i], tc.want[i])
			}
		}
	}
}

func TestFetchAndCacheError(t *testing.T) {
	root := t.TempDir()
	c := &stubClient{resp: makeResp(404, `{"error":"not found"}`)}

	if _, err := FetchAndCache(c, root, "missing"); err == nil {
		t.Errorf("expected error for 404")
	}
}

func TestFetchAndCacheRequiresClient(t *testing.T) {
	if _, err := FetchAndCache(nil, "", "mod"); err == nil {
		t.Errorf("expected error for nil client")
	}
}

func TestFetchAndCacheRequiresID(t *testing.T) {
	c := &stubClient{}
	if _, err := FetchAndCache(c, "", ""); err == nil {
		t.Errorf("expected error for empty moduleID")
	}
}
