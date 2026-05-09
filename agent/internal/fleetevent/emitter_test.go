package fleetevent

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type stubClient struct {
	lastPath string
	lastBody []byte
	resp     *http.Response
	err      error
}

func (s *stubClient) PostJSON(path string, body []byte) (*http.Response, error) {
	s.lastPath = path
	s.lastBody = append([]byte(nil), body...)
	if s.err != nil {
		return nil, s.err
	}
	if s.resp != nil {
		return s.resp, nil
	}
	return &http.Response{
		StatusCode: http.StatusNoContent,
		Body:       io.NopCloser(strings.NewReader("")),
	}, nil
}

func TestEmitSingleEvent(t *testing.T) {
	client := &stubClient{}
	e := New(client)

	err := e.Emit(context.Background(), Event{
		Kind:     "module.attached",
		Severity: SeverityLow,
		Payload:  map[string]any{"module_id": "abc"},
	})
	if err != nil {
		t.Fatalf("Emit: %v", err)
	}
	if client.lastPath != "/api/v1/system/node_api/fleet/events" {
		t.Errorf("path: got %q", client.lastPath)
	}

	var got struct {
		Events []Event `json:"events"`
	}
	if err := json.Unmarshal(client.lastBody, &got); err != nil {
		t.Fatalf("decode body: %v", err)
	}
	if len(got.Events) != 1 || got.Events[0].Kind != "module.attached" {
		t.Errorf("body: %s", client.lastBody)
	}
}

func TestEmitBatch(t *testing.T) {
	client := &stubClient{}
	e := New(client)

	events := []Event{
		{Kind: "module.attached", Severity: SeverityLow},
		{Kind: "module.detached", Severity: SeverityMedium},
	}
	if err := e.EmitBatch(context.Background(), events); err != nil {
		t.Fatalf("EmitBatch: %v", err)
	}

	var got struct {
		Events []Event `json:"events"`
	}
	json.Unmarshal(client.lastBody, &got)
	if len(got.Events) != 2 {
		t.Errorf("events count: got %d want 2", len(got.Events))
	}
}

func TestEmitDefaultsSeverityToLow(t *testing.T) {
	client := &stubClient{}
	e := New(client)

	if err := e.Emit(context.Background(), Event{Kind: "test"}); err != nil {
		t.Fatalf("Emit: %v", err)
	}

	var got struct {
		Events []Event `json:"events"`
	}
	json.Unmarshal(client.lastBody, &got)
	if got.Events[0].Severity != SeverityLow {
		t.Errorf("severity defaulted to %q", got.Events[0].Severity)
	}
}

func TestEmitRequiresKind(t *testing.T) {
	client := &stubClient{}
	e := New(client)

	err := e.Emit(context.Background(), Event{Severity: SeverityLow})
	if err == nil {
		t.Errorf("expected error for missing Kind")
	}
}

func TestEmitNonSuccessStatus(t *testing.T) {
	client := &stubClient{
		resp: &http.Response{
			StatusCode: http.StatusInternalServerError,
			Body:       io.NopCloser(strings.NewReader(`{"error":"boom"}`)),
		},
	}
	e := New(client)

	err := e.Emit(context.Background(), Event{Kind: "test", Severity: SeverityLow})
	if err == nil {
		t.Errorf("expected error for 500 status")
	}
}

func TestEmitEmptyBatch(t *testing.T) {
	client := &stubClient{}
	e := New(client)

	if err := e.EmitBatch(context.Background(), nil); err != nil {
		t.Errorf("empty batch should be no-op: %v", err)
	}
	if client.lastBody != nil {
		t.Errorf("empty batch should not send: %s", client.lastBody)
	}
}

func TestEmitNilEmitter(t *testing.T) {
	var e *Emitter
	if err := e.Emit(context.Background(), Event{Kind: "test"}); err == nil {
		t.Errorf("expected error for nil emitter")
	}
}

// TestEmitAgainstHTTPTest exercises the real path with an httptest
// server (verifies pass-through transport works end-to-end).
func TestEmitAgainstHTTPTest(t *testing.T) {
	type batch struct {
		Events []Event `json:"events"`
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var b batch
		if err := json.Unmarshal(body, &b); err != nil {
			http.Error(w, err.Error(), 400)
			return
		}
		if len(b.Events) == 0 {
			http.Error(w, "empty", 400)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()

	client := &shimClient{base: srv.URL, http: srv.Client()}
	e := New(client)
	err := e.Emit(context.Background(), Event{Kind: "ok", Severity: SeverityLow})
	if err != nil {
		t.Fatalf("Emit: %v", err)
	}
}

type shimClient struct {
	base string
	http *http.Client
}

func (s *shimClient) PostJSON(path string, body []byte) (*http.Response, error) {
	req, _ := http.NewRequest(http.MethodPost, s.base+path, strings.NewReader(string(body)))
	req.Header.Set("Content-Type", "application/json")
	return s.http.Do(req)
}
