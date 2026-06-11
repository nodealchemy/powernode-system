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

func TestFetchIsolationConfig(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != isolationRuntimesPath {
			t.Errorf("unexpected path %q", r.URL.Path)
		}
		_, _ = w.Write([]byte(`{"data":{"runtimes":["gvisor"],"default_runtime":"runsc"}}`))
	}))
	defer srv.Close()

	got := fetchIsolationConfig(fakeRTFetcher{base: srv.URL})
	if len(got.Runtimes) != 1 || got.Runtimes[0] != "gvisor" {
		t.Fatalf("expected [gvisor], got %v", got.Runtimes)
	}
	if got.DefaultRuntime != "runsc" {
		t.Fatalf("expected default runtime runsc, got %q", got.DefaultRuntime)
	}
}

func TestFetchIsolationConfig_ZeroOnError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	got := fetchIsolationConfig(fakeRTFetcher{base: srv.URL})
	if len(got.Runtimes) != 0 || got.DefaultRuntime != "" {
		t.Fatalf("expected zero config on 500, got %+v", got)
	}
}
