package a2a

import (
	"crypto/ed25519"
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"testing"
)

type fakeFetcher struct{ base string }

func (f fakeFetcher) GetJSON(path string) (*http.Response, error) {
	return http.Get(f.base + path)
}

func TestRefreshKeys(t *testing.T) {
	pub, _, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	pubB64 := base64.StdEncoding.EncodeToString(pub)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != CapabilityKeysPath {
			t.Errorf("unexpected path %q", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":{"keys":[{"handle":"a2a-cap-acct-x","public_key_b64":"` + pubB64 + `","algorithm":"ED25519"}]}}`))
	}))
	defer srv.Close()

	v := NewVerifier()
	n, err := RefreshKeys(v, fakeFetcher{base: srv.URL})
	if err != nil {
		t.Fatalf("refresh: %v", err)
	}
	if n != 1 {
		t.Fatalf("expected 1 key trusted, got %d", n)
	}
	handles := v.TrustedHandles()
	if len(handles) != 1 || handles[0] != "a2a-cap-acct-x" {
		t.Fatalf("expected [a2a-cap-acct-x], got %v", handles)
	}
}

func TestRefreshKeys_BadStatus(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()
	if _, err := RefreshKeys(NewVerifier(), fakeFetcher{base: srv.URL}); err == nil {
		t.Fatal("expected error on non-200")
	}
}
