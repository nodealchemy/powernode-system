package a2a

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"testing"
)

type stubAnnouncer struct {
	path   string
	body   []byte
	status int
}

func (s *stubAnnouncer) PostJSON(path string, body []byte) (*http.Response, error) {
	s.path, s.body = path, body
	code := s.status
	if code == 0 {
		code = http.StatusOK
	}
	return &http.Response{StatusCode: code, Body: io.NopCloser(bytes.NewReader([]byte(`{"data":{}}`)))}, nil
}

func TestAnnounce(t *testing.T) {
	a := &stubAnnouncer{}
	if err := Announce(a, []string{"ping", "inference.generate"}, []string{"[fd00::2]:7777"}); err != nil {
		t.Fatal(err)
	}
	if a.path != PeerAnnouncePath {
		t.Fatalf("path = %q, want %q", a.path, PeerAnnouncePath)
	}
	var payload struct {
		Capabilities map[string]any `json:"capabilities"`
		Skills       []string       `json:"skills"`
		Addresses    []string       `json:"addresses"`
	}
	if err := json.Unmarshal(a.body, &payload); err != nil {
		t.Fatal(err)
	}
	if len(payload.Skills) != 2 || payload.Skills[1] != "inference.generate" {
		t.Fatalf("skills: %v", payload.Skills)
	}
	if payload.Capabilities["inference"] != true || payload.Capabilities["a2a"] != true {
		t.Fatalf("capabilities: %v", payload.Capabilities)
	}
	if len(payload.Addresses) != 1 || payload.Addresses[0] != "[fd00::2]:7777" {
		t.Fatalf("addresses: %v", payload.Addresses)
	}
}

func TestAnnounce_InferenceFlagFalse(t *testing.T) {
	a := &stubAnnouncer{}
	_ = Announce(a, []string{"ping", "describe"}, nil)
	var payload struct {
		Capabilities map[string]any `json:"capabilities"`
	}
	_ = json.Unmarshal(a.body, &payload)
	if payload.Capabilities["inference"] != false {
		t.Fatalf("inference flag should be false without inference.* skills: %v", payload.Capabilities)
	}
}

func TestAnnounce_ErrorStatus(t *testing.T) {
	a := &stubAnnouncer{status: http.StatusInternalServerError}
	if err := Announce(a, []string{"ping"}, nil); err == nil {
		t.Fatal("expected error on non-2xx announce status")
	}
}

func TestHasInferenceSkill(t *testing.T) {
	if !hasInferenceSkill([]string{"ping", "inference.embed"}) {
		t.Fatal("expected true when an inference.* skill is present")
	}
	if hasInferenceSkill([]string{"ping", "describe"}) {
		t.Fatal("expected false with no inference.* skill")
	}
}
