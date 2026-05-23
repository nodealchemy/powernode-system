package etcidentity

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

func newTempPaths(t *testing.T) Paths {
	t.Helper()
	dir := t.TempDir()
	return Paths{
		Lock:    filepath.Join(dir, ".pwd.lock"),
		Passwd:  filepath.Join(dir, "passwd"),
		Group:   filepath.Join(dir, "group"),
		Shadow:  filepath.Join(dir, "shadow"),
		Gshadow: filepath.Join(dir, "gshadow"),
	}
}

func TestApplyAtWritesAllFour(t *testing.T) {
	paths := newTempPaths(t)
	set := Baseline()

	if err := ApplyAt(set, paths); err != nil {
		t.Fatalf("ApplyAt: %v", err)
	}

	for label, p := range map[string]string{
		"passwd": paths.Passwd, "group": paths.Group,
		"shadow": paths.Shadow, "gshadow": paths.Gshadow,
	} {
		st, err := os.Stat(p)
		if err != nil {
			t.Errorf("%s missing: %v", label, err)
			continue
		}
		if st.Size() == 0 {
			t.Errorf("%s empty", label)
		}
	}
}

func TestApplyAtSetsFileModes(t *testing.T) {
	paths := newTempPaths(t)
	if err := ApplyAt(Baseline(), paths); err != nil {
		t.Fatalf("ApplyAt: %v", err)
	}

	cases := []struct {
		label string
		path  string
		mode  os.FileMode
	}{
		{"passwd", paths.Passwd, 0644},
		{"group", paths.Group, 0644},
		{"shadow", paths.Shadow, 0640},
		{"gshadow", paths.Gshadow, 0640},
	}
	for _, c := range cases {
		st, err := os.Stat(c.path)
		if err != nil {
			t.Errorf("%s stat: %v", c.label, err)
			continue
		}
		if st.Mode().Perm() != c.mode {
			t.Errorf("%s mode = %o want %o", c.label, st.Mode().Perm(), c.mode)
		}
	}
}

func TestApplyAtPasswdContent(t *testing.T) {
	paths := newTempPaths(t)
	if err := ApplyAt(Baseline(), paths); err != nil {
		t.Fatalf("ApplyAt: %v", err)
	}
	body, err := os.ReadFile(paths.Passwd)
	if err != nil {
		t.Fatalf("read passwd: %v", err)
	}
	got := string(body)
	for _, want := range []string{"root:x:0:0:", "nobody:x:65534:65534:"} {
		if !strings.Contains(got, want) {
			t.Errorf("/etc/passwd missing %q\nfull:\n%s", want, got)
		}
	}
}

// TestApplyAtWaitsForContendedLock takes a separate hold on the test
// lock, then runs ApplyAt in a goroutine. ApplyAt's flock should block
// until we release the hold, then complete normally — verifying the
// flock interlock works with concurrent writers.
func TestApplyAtWaitsForContendedLock(t *testing.T) {
	paths := newTempPaths(t)

	holdFD, err := os.OpenFile(paths.Lock, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		t.Fatalf("open hold lock: %v", err)
	}
	defer holdFD.Close()
	if err := syscall.Flock(int(holdFD.Fd()), syscall.LOCK_EX); err != nil {
		t.Fatalf("flock hold: %v", err)
	}

	done := make(chan error, 1)
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		done <- ApplyAt(Baseline(), paths)
	}()

	// Hold for 500ms so ApplyAt is definitely blocked, then release.
	time.Sleep(500 * time.Millisecond)
	if err := syscall.Flock(int(holdFD.Fd()), syscall.LOCK_UN); err != nil {
		t.Fatalf("flock release: %v", err)
	}

	select {
	case err := <-done:
		if err != nil {
			t.Errorf("ApplyAt returned error after lock release: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("ApplyAt did not complete within 5s of lock release")
	}
	wg.Wait()
}
