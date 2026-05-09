package mount

import (
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

var osStat = os.Stat

func TestLockUnlockBasic(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state.json")

	unlock, err := Lock(path)
	if err != nil {
		t.Fatalf("Lock: %v", err)
	}
	if err := unlock(); err != nil {
		t.Errorf("unlock: %v", err)
	}

	// Second lock after unlock should succeed.
	unlock2, err := Lock(path)
	if err != nil {
		t.Fatalf("re-Lock after unlock: %v", err)
	}
	unlock2()
}

func TestLockEmptyPath(t *testing.T) {
	if _, err := Lock(""); err == nil {
		t.Errorf("expected error for empty path")
	}
}

// TestLockContention serializes two goroutines on the same lock. The
// second goroutine should not acquire the lock until the first
// releases it.
func TestLockContention(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state.json")

	var (
		acquiredAt [2]time.Time
		releasedAt [2]time.Time
		mu         sync.Mutex
		started    atomic.Int32
	)

	hold := 100 * time.Millisecond

	worker := func(idx int, ready <-chan struct{}) {
		started.Add(1)
		<-ready
		unlock, err := Lock(path)
		if err != nil {
			t.Errorf("worker %d Lock: %v", idx, err)
			return
		}
		mu.Lock()
		acquiredAt[idx] = time.Now()
		mu.Unlock()

		time.Sleep(hold)

		mu.Lock()
		releasedAt[idx] = time.Now()
		mu.Unlock()
		unlock()
	}

	ready := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); worker(0, ready) }()
	go func() { defer wg.Done(); worker(1, ready) }()

	// Wait for both goroutines to start.
	for started.Load() < 2 {
		time.Sleep(time.Millisecond)
	}
	close(ready)
	wg.Wait()

	// One acquired strictly after the other released.
	mu.Lock()
	defer mu.Unlock()

	first, second := 0, 1
	if acquiredAt[1].Before(acquiredAt[0]) {
		first, second = 1, 0
	}
	if !acquiredAt[second].After(releasedAt[first]) && !acquiredAt[second].Equal(releasedAt[first]) {
		t.Errorf("second lock acquired before first released: first acquired=%v released=%v second acquired=%v",
			acquiredAt[first], releasedAt[first], acquiredAt[second])
	}
}

// TestLockSidecar confirms the lockfile lives next to the protected
// path with a .lock suffix and that state.json itself is not created
// or modified by Lock.
func TestLockSidecar(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state.json")

	unlock, err := Lock(path)
	if err != nil {
		t.Fatalf("Lock: %v", err)
	}
	defer unlock()

	if _, err := osStat(path + ".lock"); err != nil {
		t.Errorf("expected lockfile at %s.lock: %v", path, err)
	}
	if _, err := osStat(path); err == nil {
		t.Errorf("Lock should not create %s", path)
	}
}
