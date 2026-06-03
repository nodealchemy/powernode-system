package runtime

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

type fakeRTFetcher struct{ base string }

func (f fakeRTFetcher) GetJSON(path string) (*http.Response, error) {
	return http.Get(f.base + path)
}

func TestFetchIsolationRuntimes(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != isolationRuntimesPath {
			t.Errorf("unexpected path %q", r.URL.Path)
		}
		_, _ = w.Write([]byte(`{"data":{"runtimes":["gvisor"]}}`))
	}))
	defer srv.Close()

	got := fetchIsolationRuntimes(fakeRTFetcher{base: srv.URL})
	if len(got) != 1 || got[0] != "gvisor" {
		t.Fatalf("expected [gvisor], got %v", got)
	}
}

func TestFetchIsolationRuntimes_EmptyOnError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	if got := fetchIsolationRuntimes(fakeRTFetcher{base: srv.URL}); len(got) != 0 {
		t.Fatalf("expected empty on 500, got %v", got)
	}
}
