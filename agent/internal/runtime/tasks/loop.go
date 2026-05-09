package tasks

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/fsutil"
)

// DefaultStatePath is where the loop persists its inflight task list
// for crash recovery. Lives under /persist so it survives reboots.
const DefaultStatePath = "/persist/var/lib/powernode/tasks_state.json"

// LoopConfig wires the loop's dependencies.
type LoopConfig struct {
	// Client wraps the typed task endpoints.
	Client *Client
	// Registry resolves command name → handler.
	Registry *Registry
	// Interval is the gap between polls. Default 20s with ±25% jitter.
	Interval time.Duration
	// Concurrency caps simultaneous in-flight tasks. Default 1
	// (matches legacy ipn — most node ops mutate state, parallelism
	// risks deadlock matrices).
	Concurrency int
	// StatePath is where inflight tasks are persisted. Default
	// DefaultStatePath.
	StatePath string
	// OnError surfaces non-fatal loop-stage errors.
	OnError func(stage string, err error)
}

// Loop is the long-running task lease loop. Polls /status/tasks each
// tick, dispatches new tasks to handlers (acknowledge → execute →
// complete/fail), persists inflight state for crash recovery.
type Loop struct {
	cfg LoopConfig

	mu       sync.Mutex
	inflight map[string]inflightTask
	sema     chan struct{} // concurrency limiter
}

type inflightTask struct {
	Command   string         `json:"command"`
	Options   map[string]any `json:"options,omitempty"`
	StartedAt time.Time      `json:"started_at"`
}

type stateFile struct {
	SchemaVersion int                     `json:"schema_version"`
	Inflight      map[string]inflightTask `json:"inflight"`
}

// NewLoop validates required fields and returns a Loop with defaults.
func NewLoop(cfg LoopConfig) (*Loop, error) {
	if cfg.Client == nil {
		return nil, errors.New("NewLoop: Client required")
	}
	if cfg.Registry == nil {
		return nil, errors.New("NewLoop: Registry required")
	}
	if cfg.Interval == 0 {
		cfg.Interval = 20 * time.Second
	}
	if cfg.Concurrency <= 0 {
		cfg.Concurrency = 1
	}
	if cfg.StatePath == "" {
		cfg.StatePath = DefaultStatePath
	}
	if cfg.OnError == nil {
		cfg.OnError = func(string, error) {}
	}
	return &Loop{
		cfg:      cfg,
		inflight: map[string]inflightTask{},
		sema:     make(chan struct{}, cfg.Concurrency),
	}, nil
}

// Run blocks until ctx is canceled. Each tick: list pending tasks,
// dispatch new ones to handlers, surface stage errors via OnError.
//
// Crash recovery: on first tick after a restart, the loop
// reconstructs its inflight state from disk and consults the platform
// for each entry. Tasks the platform reports as terminal are cleared
// from local state; tasks the platform still reports as
// pending/acknowledged/running are re-executed (handlers MUST be
// idempotent).
func (l *Loop) Run(ctx context.Context) {
	if err := l.recoverInflight(ctx); err != nil {
		l.cfg.OnError("task_lease:recovery", err)
	}

	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		if err := l.tick(ctx); err != nil {
			l.cfg.OnError("task_lease", err)
		}

		jitter := time.Duration(rand.Int63n(int64(l.cfg.Interval) / 2))
		sleep := l.cfg.Interval + jitter - l.cfg.Interval/4
		select {
		case <-ctx.Done():
			return
		case <-time.After(sleep):
		}
	}
}

// tick is one poll → dispatch cycle. Visible for tests.
func (l *Loop) tick(ctx context.Context) error {
	tasks, err := l.cfg.Client.ListPending()
	if err != nil {
		return fmt.Errorf("list pending: %w", err)
	}

	for i := range tasks {
		task := tasks[i]
		if l.isInflight(task.ID) {
			continue
		}
		// Acquire concurrency slot before persisting. If the slot is
		// busy, skip this task — next tick picks it up.
		select {
		case l.sema <- struct{}{}:
		default:
			continue
		}
		l.markInflight(&task)
		go l.processTask(ctx, &task)
	}
	return nil
}

// processTask runs one task end-to-end. Acknowledge → execute →
// complete/fail. Releases the concurrency slot AFTER clearing
// inflight state — observers waiting on the semaphore can rely on
// the cleanup being durable when the slot becomes available.
func (l *Loop) processTask(ctx context.Context, task *Task) {
	defer func() {
		l.clearInflight(task.ID)
		<-l.sema
	}()

	if err := l.cfg.Client.Acknowledge(task.ID); err != nil {
		l.cfg.OnError("task_lease:acknowledge:"+task.Command, err)
		return
	}

	handler, ok := l.cfg.Registry.Lookup(task.Command)
	if !ok {
		_ = l.cfg.Client.Fail(task.ID, "unknown_command: "+task.Command)
		return
	}

	result, err := handler.Execute(ctx, task)
	if err != nil {
		_ = l.cfg.Client.Fail(task.ID, err.Error())
		return
	}
	if err := l.cfg.Client.Complete(task.ID, result); err != nil {
		l.cfg.OnError("task_lease:complete:"+task.Command, err)
	}
}

// recoverInflight is called on first Run() to reconstruct inflight
// state from disk. For each entry, ask the platform what state the
// task is in:
//   - terminal (complete/failed/cancelled) → clear local
//   - non-terminal → trust local state; the next tick will re-process
//     based on the platform's current status (handlers idempotent)
//   - 404 → clear local (task no longer exists)
func (l *Loop) recoverInflight(_ context.Context) error {
	body, err := os.ReadFile(l.cfg.StatePath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("read %s: %w", l.cfg.StatePath, err)
	}
	var st stateFile
	if err := json.Unmarshal(body, &st); err != nil {
		// Corrupt state file — start fresh. Better than refusing to run.
		return fmt.Errorf("decode state (starting fresh): %w", err)
	}

	for id, entry := range st.Inflight {
		task, found, err := l.cfg.Client.Get(id)
		if err != nil {
			// Network blip — keep local entry, retry next tick.
			l.mu.Lock()
			l.inflight[id] = entry
			l.mu.Unlock()
			continue
		}
		if !found {
			continue // task gone; drop local entry
		}
		switch task.Status {
		case "complete", "failed", "cancelled", "aborted":
			continue // platform already wrapped it up; drop local
		default:
			l.mu.Lock()
			l.inflight[id] = entry
			l.mu.Unlock()
		}
	}
	return l.persistInflight()
}

// markInflight adds a task to the local inflight map and persists
// to disk. Persistence happens BEFORE the acknowledge POST so that a
// crash between persist + acknowledge means the platform reaper
// catches it (acknowledge is the transactional fence).
func (l *Loop) markInflight(task *Task) {
	l.mu.Lock()
	l.inflight[task.ID] = inflightTask{
		Command:   task.Command,
		Options:   task.Options,
		StartedAt: time.Now().UTC(),
	}
	l.mu.Unlock()
	_ = l.persistInflight()
}

// clearInflight removes a task from the local inflight map.
func (l *Loop) clearInflight(id string) {
	l.mu.Lock()
	delete(l.inflight, id)
	l.mu.Unlock()
	_ = l.persistInflight()
}

// isInflight returns true iff id is currently in the local map.
func (l *Loop) isInflight(id string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	_, ok := l.inflight[id]
	return ok
}

// persistInflight atomically writes the inflight map to disk.
func (l *Loop) persistInflight() error {
	if err := os.MkdirAll(filepath.Dir(l.cfg.StatePath), 0o755); err != nil {
		return fmt.Errorf("mkdir %s: %w", filepath.Dir(l.cfg.StatePath), err)
	}
	l.mu.Lock()
	st := stateFile{SchemaVersion: 1, Inflight: copyInflight(l.inflight)}
	l.mu.Unlock()
	return fsutil.AtomicWriteJSON(l.cfg.StatePath, st, 0o600)
}

func copyInflight(in map[string]inflightTask) map[string]inflightTask {
	out := make(map[string]inflightTask, len(in))
	for k, v := range in {
		out[k] = v
	}
	return out
}
