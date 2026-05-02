package transport

import (
	"net/http"
	"testing"
)

// setAuth attaches a Bearer JWT header iff the client has an InstanceToken.
// This is the agent's belt-and-suspenders auth path — mTLS material is
// already on the underlying http.Transport; the JWT is the legacy fallback
// the platform consumes when no reverse-proxy mTLS termination is configured.
func TestSetAuth_AttachesBearerWhenTokenPresent(t *testing.T) {
	c := &Client{InstanceToken: "abc.def.ghi"}
	req, _ := http.NewRequest(http.MethodGet, "http://x", nil)
	c.setAuth(req)
	got := req.Header.Get("Authorization")
	if got != "Bearer abc.def.ghi" {
		t.Fatalf("expected 'Bearer abc.def.ghi', got %q", got)
	}
}

func TestSetAuth_NoHeaderWhenTokenEmpty(t *testing.T) {
	c := &Client{InstanceToken: ""}
	req, _ := http.NewRequest(http.MethodGet, "http://x", nil)
	c.setAuth(req)
	if got := req.Header.Get("Authorization"); got != "" {
		t.Fatalf("expected no Authorization header, got %q", got)
	}
}

func TestTrimSpace(t *testing.T) {
	cases := map[string]string{
		"":             "",
		"abc":          "abc",
		"  abc  ":      "abc",
		"\nabc\n":      "abc",
		"\t abc \r\n":  "abc",
		"abc\nxyz":     "abc\nxyz", // interior whitespace preserved
	}
	for in, want := range cases {
		if got := trimSpace(in); got != want {
			t.Errorf("trimSpace(%q): got %q, want %q", in, got, want)
		}
	}
}
