package runtime

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

// recordingFetch is a Fetch stub that records call count and replays a script
// of results, repeating the final entry once exhausted.
type recordingFetch struct {
	mu      sync.Mutex
	calls   int
	results []error
}

func (r *recordingFetch) fn(context.Context) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.calls++
	if len(r.results) == 0 {
		return nil
	}
	i := r.calls - 1
	if i >= len(r.results) {
		i = len(r.results) - 1
	}
	return r.results[i]
}

func (r *recordingFetch) count() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.calls
}

// waitFor polls cond until true or the deadline expires. Returns false on
// timeout so callers can t.Fatal with their own message.
func waitFor(cond func() bool, d time.Duration) bool {
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if cond() {
			return true
		}
		time.Sleep(time.Millisecond)
	}
	return cond()
}

// THE regression test. This is the ops-hub 2026-07-26 incident: the platform
// is unreachable at boot (heartbeat failing, so the old PostSend-gated sync
// never ran) and then comes up. Keys MUST land without an agent restart and
// without a single successful heartbeat ever occurring — the syncer has no
// heartbeat input at all, which is the structural point of the decoupling.
func TestAuthorizedKeysSyncerRecoversWithoutHeartbeat(t *testing.T) {
	boom := errors.New("Get authorized_keys: no such host")
	rf := &recordingFetch{results: []error{boom, boom, nil}}

	s := &AuthorizedKeysSyncer{
		RetryInterval: time.Millisecond,
		Interval:      time.Millisecond,
		Fetch:         rf.fn,
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = s.Run(ctx) }()

	if !waitFor(func() bool { return rf.count() >= 3 }, 2*time.Second) {
		t.Fatalf("syncer gave up after %d attempts; it must keep retrying until the platform answers", rf.count())
	}
}

// The pre-success cadence must actually be the retry interval, not the steady
// one — otherwise a node with a slow-booting platform waits a full minute for
// SSH access when it could have waited seconds.
func TestAuthorizedKeysSyncerUsesRetryCadenceBeforeFirstSuccess(t *testing.T) {
	rf := &recordingFetch{results: []error{errors.New("down")}} // always fails

	s := &AuthorizedKeysSyncer{
		RetryInterval: 2 * time.Millisecond,
		Interval:      10 * time.Second, // would allow only 1 call if wrongly used
		Fetch:         rf.fn,
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = s.Run(ctx) }()

	if !waitFor(func() bool { return rf.count() >= 5 }, 2*time.Second) {
		t.Fatalf("only %d attempts; pre-success cadence should be RetryInterval, not Interval", rf.count())
	}
}

// Keys must keep converging after the first success so rotations propagate —
// this is the behaviour the old PostSend hook provided and that the decoupling
// must not lose.
func TestAuthorizedKeysSyncerKeepsSyncingAfterSuccess(t *testing.T) {
	rf := &recordingFetch{results: []error{nil}} // always succeeds

	s := &AuthorizedKeysSyncer{
		RetryInterval: time.Hour, // must NOT be used after success
		Interval:      time.Millisecond,
		Fetch:         rf.fn,
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = s.Run(ctx) }()

	if !waitFor(func() bool { return rf.count() >= 3 }, 2*time.Second) {
		t.Fatalf("only %d syncs; key rotation would stop propagating after the first success", rf.count())
	}
}

// A platform down for ten minutes must not emit one identical log line per
// tick. Report on first occurrence and on change only.
func TestAuthorizedKeysSyncerSuppressesRepeatedIdenticalErrors(t *testing.T) {
	rf := &recordingFetch{results: []error{errors.New("same failure")}}

	var mu sync.Mutex
	stages := []string{}
	s := &AuthorizedKeysSyncer{
		RetryInterval: time.Millisecond,
		Interval:      time.Millisecond,
		Fetch:         rf.fn,
		OnError: func(stage string, _ error) {
			mu.Lock()
			stages = append(stages, stage)
			mu.Unlock()
		},
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = s.Run(ctx) }()

	if !waitFor(func() bool { return rf.count() >= 10 }, 2*time.Second) {
		t.Fatalf("expected >=10 attempts, got %d", rf.count())
	}
	cancel()

	mu.Lock()
	defer mu.Unlock()
	if len(stages) != 1 {
		t.Fatalf("expected exactly 1 reported error across %d identical failures, got %d (%v)",
			rf.count(), len(stages), stages)
	}
}

// Recovery after a reported failure is itself worth one line — otherwise the
// log shows a failure and then silence, which reads as "still broken".
func TestAuthorizedKeysSyncerReportsRecovery(t *testing.T) {
	rf := &recordingFetch{results: []error{errors.New("down"), nil}}

	var mu sync.Mutex
	stages := []string{}
	s := &AuthorizedKeysSyncer{
		RetryInterval: time.Millisecond,
		Interval:      time.Millisecond,
		Fetch:         rf.fn,
		OnError: func(stage string, _ error) {
			mu.Lock()
			stages = append(stages, stage)
			mu.Unlock()
		},
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = s.Run(ctx) }()

	ok := waitFor(func() bool {
		mu.Lock()
		defer mu.Unlock()
		return len(stages) >= 2
	}, 2*time.Second)
	cancel()

	mu.Lock()
	defer mu.Unlock()
	if !ok {
		t.Fatalf("expected a failure then a recovery report, got %v", stages)
	}
	if stages[0] != "authorized_keys_sync" || stages[1] != "authorized_keys_sync_recovered" {
		t.Fatalf("expected [authorized_keys_sync authorized_keys_sync_recovered], got %v", stages)
	}
}

// Cancellation must stop the loop promptly rather than sleeping out a full
// interval — agent shutdown should not block for a minute.
func TestAuthorizedKeysSyncerStopsOnContextCancel(t *testing.T) {
	rf := &recordingFetch{results: []error{nil}}
	s := &AuthorizedKeysSyncer{
		Interval:      time.Hour,
		RetryInterval: time.Hour,
		Fetch:         rf.fn,
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- s.Run(ctx) }()

	if !waitFor(func() bool { return rf.count() >= 1 }, 2*time.Second) {
		t.Fatal("syncer never performed its immediate first sync")
	}
	cancel()

	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("expected context.Canceled, got %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Run did not return promptly after cancel")
	}
}
