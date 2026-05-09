package runtime

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/transport"
)

func TestHeartbeater_Send_HappyPath(t *testing.T) {
	var received atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/system/node_api/status/heartbeat" || r.Method != http.MethodPost {
			http.Error(w, "wrong route", http.StatusNotFound)
			return
		}
		received.Add(1)
		var p HeartbeatPayload
		if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		if p.BootID == "" || p.AgentVersion == "" {
			http.Error(w, "missing required fields", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"success":true,"data":{"acknowledged":true,"tasks_pending":2,"next_poll_seconds":15}}`))
	}))
	defer srv.Close()

	c := &transport.Client{Client: srv.Client(), PlatformURL: srv.URL, InstanceID: "i-1"}
	h := &Heartbeater{
		Client: c,
		BuildPayload: func() HeartbeatPayload {
			return HeartbeatPayload{
				BootID:        "boot-test",
				AgentVersion:  "0.1.0",
				Architecture:  "amd64",
				ModuleDigests: map[string]string{"m1": "sha256:1"},
				MountState:    "mounted",
			}
		},
	}
	resp, err := h.Send(context.Background())
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	if !resp.Success {
		t.Errorf("Success = false")
	}
	if resp.Data.PendingTasks != 2 {
		t.Errorf("PendingTasks = %d", resp.Data.PendingTasks)
	}
	if resp.Data.NextPollSeconds != 15 {
		t.Errorf("NextPollSeconds = %d", resp.Data.NextPollSeconds)
	}
	if got := received.Load(); got != 1 {
		t.Errorf("server received %d POSTs, want 1", got)
	}
}

func TestHeartbeater_Send_PlatformError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(503)
		_, _ = w.Write([]byte(`{"success":false,"error":"upstream down"}`))
	}))
	defer srv.Close()

	c := &transport.Client{Client: srv.Client(), PlatformURL: srv.URL}
	h := &Heartbeater{
		Client:       c,
		BuildPayload: func() HeartbeatPayload { return HeartbeatPayload{BootID: "x", AgentVersion: "y"} },
	}
	_, err := h.Send(context.Background())
	if err == nil {
		t.Fatal("expected error on platform 503")
	}
}

func TestHeartbeater_Run_RespectsCtxCancel(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"success":true,"data":{"acknowledged":true,"next_poll_seconds":0}}`))
	}))
	defer srv.Close()

	c := &transport.Client{Client: srv.Client(), PlatformURL: srv.URL}
	h := &Heartbeater{
		Client:       c,
		BuildPayload: func() HeartbeatPayload { return HeartbeatPayload{BootID: "x", AgentVersion: "y"} },
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		h.Run(ctx, 50*time.Millisecond, nil)
		close(done)
	}()
	time.Sleep(75 * time.Millisecond)
	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Run did not exit within 2s of ctx cancel")
	}
}

func TestHeartbeater_Run_HonorsNextPollHint(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		w.Header().Set("Content-Type", "application/json")
		// Tell the agent to poll every 10ms — much faster than the 1s default
		_, _ = w.Write([]byte(`{"success":true,"data":{"acknowledged":true,"next_poll_seconds":0}}`))
	}))
	defer srv.Close()

	c := &transport.Client{Client: srv.Client(), PlatformURL: srv.URL}
	h := &Heartbeater{
		Client:       c,
		BuildPayload: func() HeartbeatPayload { return HeartbeatPayload{BootID: "x", AgentVersion: "y"} },
	}

	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	h.Run(ctx, 30*time.Millisecond, nil)

	got := calls.Load()
	if got < 3 {
		t.Errorf("expected several heartbeats in 200ms with default 30ms, got %d", got)
	}
}
