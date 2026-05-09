package tasks

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

// recordingHTTP is an HTTPClient stub that records every call and
// returns canned responses keyed by HTTP method + path.
type recordingHTTP struct {
	mu        sync.Mutex
	getResp   map[string]string  // path → body
	getStatus map[string]int     // path → status (default 200)
	postResp  map[string]string  // path → body
	postBody  map[string][]byte  // path → most recent post body
	postCalls map[string]int     // path → call count
	getCalls  map[string]int
}

func (r *recordingHTTP) GetJSON(path string) (*http.Response, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.getCalls == nil {
		r.getCalls = map[string]int{}
	}
	r.getCalls[path]++
	body := r.getResp[path]
	status := r.getStatus[path]
	if status == 0 {
		status = http.StatusOK
		if body == "" {
			status = http.StatusNotFound
		}
	}
	return &http.Response{
		StatusCode: status,
		Body:       io.NopCloser(strings.NewReader(body)),
	}, nil
}

func (r *recordingHTTP) PostJSON(path string, body []byte) (*http.Response, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.postBody == nil {
		r.postBody = map[string][]byte{}
		r.postCalls = map[string]int{}
	}
	r.postBody[path] = append([]byte(nil), body...)
	r.postCalls[path]++
	resp := r.postResp[path]
	if resp == "" {
		resp = `{"success":true}`
	}
	return &http.Response{
		StatusCode: http.StatusOK,
		Body:       io.NopCloser(strings.NewReader(resp)),
	}, nil
}

// stubHandler records executions and returns canned results/errors.
type stubHandler struct {
	mu       sync.Mutex
	calls    int
	wantErr  error
	wantRes  Result
	gotTasks []*Task
}

func (s *stubHandler) Execute(_ context.Context, t *Task) (Result, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.calls++
	s.gotTasks = append(s.gotTasks, t)
	if s.wantErr != nil {
		return nil, s.wantErr
	}
	if s.wantRes == nil {
		return Result{"ok": true}, nil
	}
	return s.wantRes, nil
}

func TestLoopProcessesNewTaskFully(t *testing.T) {
	http := &recordingHTTP{
		getResp: map[string]string{
			"/api/v1/system/node_api/status/tasks": `{
				"success":true,"data":{"tasks":[
					{"id":"t1","command":"start","status":"pending","options":{"unit":"nginx.service"}}
				]}
			}`,
		},
	}
	handler := &stubHandler{}
	reg := NewRegistry()
	reg.Register("start", handler)

	dir := t.TempDir()
	loop, err := NewLoop(LoopConfig{
		Client:      NewClient(http),
		Registry:    reg,
		Concurrency: 1,
		StatePath:   filepath.Join(dir, "tasks_state.json"),
	})
	if err != nil {
		t.Fatalf("NewLoop: %v", err)
	}

	if err := loop.tick(context.Background()); err != nil {
		t.Fatalf("tick: %v", err)
	}
	// Drain the in-flight goroutine.
	loop.sema <- struct{}{}
	<-loop.sema

	if handler.calls != 1 {
		t.Errorf("expected handler called once, got %d", handler.calls)
	}
	if got := handler.gotTasks[0].Command; got != "start" {
		t.Errorf("task command: %q", got)
	}
	if c := http.postCalls["/api/v1/system/node_api/status/tasks/t1/acknowledge"]; c != 1 {
		t.Errorf("expected 1 acknowledge call, got %d", c)
	}
	if c := http.postCalls["/api/v1/system/node_api/status/tasks/t1/complete"]; c != 1 {
		t.Errorf("expected 1 complete call, got %d", c)
	}
}

func TestLoopReportsUnknownCommandAsFail(t *testing.T) {
	http := &recordingHTTP{
		getResp: map[string]string{
			"/api/v1/system/node_api/status/tasks": `{
				"success":true,"data":{"tasks":[
					{"id":"x","command":"nonsense","status":"pending"}
				]}
			}`,
		},
	}
	loop, _ := NewLoop(LoopConfig{
		Client:    NewClient(http),
		Registry:  NewRegistry(),
		StatePath: filepath.Join(t.TempDir(), "tasks_state.json"),
	})
	loop.tick(context.Background())
	loop.sema <- struct{}{}
	<-loop.sema

	body := http.postBody["/api/v1/system/node_api/status/tasks/x/fail"]
	if !strings.Contains(string(body), "unknown_command") {
		t.Errorf("expected unknown_command in fail body, got %q", body)
	}
}

func TestLoopHandlerErrorReportsFail(t *testing.T) {
	http := &recordingHTTP{
		getResp: map[string]string{
			"/api/v1/system/node_api/status/tasks": `{
				"success":true,"data":{"tasks":[
					{"id":"e1","command":"flaky","status":"pending"}
				]}
			}`,
		},
	}
	reg := NewRegistry()
	reg.Register("flaky", &stubHandler{wantErr: errors.New("kaboom")})
	loop, _ := NewLoop(LoopConfig{
		Client:    NewClient(http),
		Registry:  reg,
		StatePath: filepath.Join(t.TempDir(), "tasks_state.json"),
	})
	loop.tick(context.Background())
	loop.sema <- struct{}{}
	<-loop.sema

	body := http.postBody["/api/v1/system/node_api/status/tasks/e1/fail"]
	if !strings.Contains(string(body), "kaboom") {
		t.Errorf("expected error message in fail body, got %q", body)
	}
	if http.postCalls["/api/v1/system/node_api/status/tasks/e1/complete"] != 0 {
		t.Errorf("complete should not be called on handler error")
	}
}

func TestLoopSkipsAlreadyInflight(t *testing.T) {
	http := &recordingHTTP{
		getResp: map[string]string{
			"/api/v1/system/node_api/status/tasks": `{
				"success":true,"data":{"tasks":[
					{"id":"t1","command":"start","status":"pending","options":{"unit":"nginx"}}
				]}
			}`,
		},
	}
	reg := NewRegistry()
	handler := &stubHandler{}
	reg.Register("start", handler)
	loop, _ := NewLoop(LoopConfig{
		Client: NewClient(http), Registry: reg,
		Concurrency: 1, StatePath: filepath.Join(t.TempDir(), "tasks_state.json"),
	})

	loop.markInflight(&Task{ID: "t1", Command: "start"})

	loop.tick(context.Background())
	if handler.calls != 0 {
		t.Errorf("expected handler NOT called for inflight task, got %d", handler.calls)
	}
}

func TestLoopPersistsInflightToDisk(t *testing.T) {
	http := &recordingHTTP{
		getResp: map[string]string{
			"/api/v1/system/node_api/status/tasks": `{
				"success":true,"data":{"tasks":[
					{"id":"t1","command":"start","status":"pending"}
				]}
			}`,
		},
	}
	reg := NewRegistry()
	hold := make(chan struct{})
	reg.Register("start", &blockingHandler{hold: hold})

	dir := t.TempDir()
	statePath := filepath.Join(dir, "tasks_state.json")
	loop, _ := NewLoop(LoopConfig{
		Client: NewClient(http), Registry: reg,
		Concurrency: 1, StatePath: statePath,
	})

	loop.tick(context.Background())
	// While the handler is still blocked, the inflight file MUST contain t1.
	body, err := os.ReadFile(statePath)
	if err != nil {
		t.Fatalf("read state: %v", err)
	}
	var st stateFile
	json.Unmarshal(body, &st)
	if _, ok := st.Inflight["t1"]; !ok {
		t.Errorf("expected t1 in inflight, got %+v", st.Inflight)
	}

	close(hold)
	loop.sema <- struct{}{}
	<-loop.sema

	// After completion, inflight cleared.
	body2, _ := os.ReadFile(statePath)
	var st2 stateFile
	json.Unmarshal(body2, &st2)
	if _, ok := st2.Inflight["t1"]; ok {
		t.Errorf("expected t1 cleared, got %+v", st2.Inflight)
	}
}

// blockingHandler holds Execute open until the test signals via hold.
type blockingHandler struct {
	hold chan struct{}
}

func (h *blockingHandler) Execute(_ context.Context, _ *Task) (Result, error) {
	<-h.hold
	return Result{}, nil
}

func TestLoopRecoveryDropsTerminalTasks(t *testing.T) {
	dir := t.TempDir()
	statePath := filepath.Join(dir, "tasks_state.json")
	st := stateFile{
		SchemaVersion: 1,
		Inflight: map[string]inflightTask{
			"old-completed": {Command: "start"},
			"old-running":   {Command: "restart"},
		},
	}
	body, _ := json.Marshal(st)
	os.WriteFile(statePath, body, 0o600)

	http := &recordingHTTP{
		getResp: map[string]string{
			"/api/v1/system/node_api/status/tasks/old-completed": `{"success":true,"data":{"task":{"id":"old-completed","status":"complete"}}}`,
			"/api/v1/system/node_api/status/tasks/old-running":   `{"success":true,"data":{"task":{"id":"old-running","status":"acknowledged"}}}`,
		},
	}
	loop, _ := NewLoop(LoopConfig{
		Client: NewClient(http), Registry: NewRegistry(),
		Concurrency: 1, StatePath: statePath,
	})

	if err := loop.recoverInflight(context.Background()); err != nil {
		t.Fatalf("recoverInflight: %v", err)
	}

	loop.mu.Lock()
	defer loop.mu.Unlock()
	if _, ok := loop.inflight["old-completed"]; ok {
		t.Errorf("terminal task should have been cleared")
	}
	if _, ok := loop.inflight["old-running"]; !ok {
		t.Errorf("non-terminal task should be retained for re-processing")
	}
}

func TestLoopConcurrencyLimit(t *testing.T) {
	tasksJSON := `{"success":true,"data":{"tasks":[
		{"id":"t1","command":"slow","status":"pending"},
		{"id":"t2","command":"slow","status":"pending"},
		{"id":"t3","command":"slow","status":"pending"}
	]}}`
	http := &recordingHTTP{getResp: map[string]string{
		"/api/v1/system/node_api/status/tasks": tasksJSON,
	}}
	reg := NewRegistry()
	hold := make(chan struct{})
	var concurrent atomic.Int32
	var maxConcurrent atomic.Int32
	reg.Register("slow", &observingHandler{
		hold: hold, concurrent: &concurrent, max: &maxConcurrent,
	})
	loop, _ := NewLoop(LoopConfig{
		Client: NewClient(http), Registry: reg,
		Concurrency: 2, StatePath: filepath.Join(t.TempDir(), "tasks_state.json"),
	})
	loop.tick(context.Background())

	// Wait for goroutines to enter the handler.
	for concurrent.Load() < 2 {
	}
	close(hold)

	// Drain.
	for i := 0; i < 2; i++ {
		loop.sema <- struct{}{}
		<-loop.sema
	}

	if maxConcurrent.Load() > 2 {
		t.Errorf("concurrency exceeded limit: %d", maxConcurrent.Load())
	}
}

type observingHandler struct {
	hold       chan struct{}
	concurrent *atomic.Int32
	max        *atomic.Int32
}

func (h *observingHandler) Execute(_ context.Context, _ *Task) (Result, error) {
	now := h.concurrent.Add(1)
	for {
		cur := h.max.Load()
		if now <= cur || h.max.CompareAndSwap(cur, now) {
			break
		}
	}
	<-h.hold
	h.concurrent.Add(-1)
	return Result{}, nil
}

func TestLoopRequiresClient(t *testing.T) {
	if _, err := NewLoop(LoopConfig{Registry: NewRegistry()}); err == nil {
		t.Errorf("expected error for missing Client")
	}
}

func TestLoopRequiresRegistry(t *testing.T) {
	_ = httptest.NewServer
	if _, err := NewLoop(LoopConfig{Client: NewClient(&recordingHTTP{})}); err == nil {
		t.Errorf("expected error for missing Registry")
	}
}
