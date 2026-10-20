//go:build linux

package identity

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// openPty returns a master and the slave path of a fresh pseudo-terminal.
func openPty(t *testing.T) (*os.File, string) {
	t.Helper()
	m, err := os.OpenFile("/dev/ptmx", os.O_RDWR|unix.O_NOCTTY|unix.O_NONBLOCK, 0)
	if err != nil {
		t.Skipf("no /dev/ptmx: %v", err)
	}
	t.Cleanup(func() { m.Close() })
	fd := int(m.Fd())
	if err := unix.IoctlSetPointerInt(fd, unix.TIOCSPTLCK, 0); err != nil {
		t.Skipf("TIOCSPTLCK: %v", err)
	}
	n, err := unix.IoctlGetInt(fd, unix.TIOCGPTN)
	if err != nil {
		t.Skipf("TIOCGPTN: %v", err)
	}
	return m, "/dev/pts/" + strconv.Itoa(n)
}

func lflags(t *testing.T, m *os.File) uint32 {
	t.Helper()
	tm, err := unix.IoctlGetTermios(int(m.Fd()), unix.TCGETS)
	if err != nil {
		t.Fatal(err)
	}
	return tm.Lflag
}

func ptyStrategy(t *testing.T, slavePath string, timeout time.Duration) (*ConsolePromptStrategy, string) {
	t.Helper()
	dir := t.TempDir()
	boot := filepath.Join(dir, "identity.cfg")
	if err := os.WriteFile(boot, []byte(bootCfgPinned), 0o600); err != nil {
		t.Fatal(err)
	}
	stage := filepath.Join(dir, "run", "identity.cfg")
	return &ConsolePromptStrategy{
		Open: func() (ConsoleTTY, error) {
			f, err := os.OpenFile(slavePath, os.O_RDWR|unix.O_NOCTTY|unix.O_NONBLOCK, 0)
			if err != nil {
				return nil, err
			}
			return osConsole{f}, nil
		},
		Timeout: timeout, Skip: func() bool { return false },
		BootStrategy: &BootIdentityStrategy{Path: boot}, StagePath: stage,
		LockPath: filepath.Join(dir, "lock"), RefusalsPath: filepath.Join(dir, "refusals"),
	}, stage
}

func TestConsolePtyRestoresTerminalAfterTimeout(t *testing.T) {
	m, slave := openPty(t)
	// keep the slave open so the pty settings survive the strategy's Close
	keep, err := os.OpenFile(slave, os.O_RDWR|unix.O_NOCTTY, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer keep.Close()
	if lflags(t, m)&(unix.ECHO|unix.ICANON) != unix.ECHO|unix.ICANON {
		t.Fatalf("fresh pty should start with ECHO|ICANON")
	}
	s, _ := ptyStrategy(t, slave, 200*time.Millisecond)
	if _, err := s.Discover(context.Background()); !errors.Is(err, ErrNotFound) {
		t.Fatalf("want ErrNotFound, got %v", err)
	}
	if got := lflags(t, m); got&unix.ECHO == 0 || got&unix.ICANON == 0 {
		t.Fatalf("terminal left in no-echo/raw mode after timeout: lflag=%#x", got)
	}
}

func TestConsolePtyMasksInputAndRestoresAfterInput(t *testing.T) {
	m, slave := openPty(t)
	keep, err := os.OpenFile(slave, os.O_RDWR|unix.O_NOCTTY, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer keep.Close()
	s, stage := ptyStrategy(t, slave, 5*time.Second)

	type out struct {
		id  *Identity
		err error
	}
	done := make(chan out, 1)
	go func() { id, err := s.Discover(context.Background()); done <- out{id, err} }()

	// wait for the prompt on the master, then check the mode WHILE prompting
	var seen strings.Builder
	buf := make([]byte, 4096)
	deadline := time.Now().Add(3 * time.Second)
	for !strings.Contains(seen.String(), "Enter alone skips") {
		if time.Now().After(deadline) {
			t.Fatalf("no prompt; saw %q", seen.String())
		}
		_ = m.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
		n, _ := m.Read(buf)
		seen.Write(buf[:n])
	}
	if got := lflags(t, m); got&unix.ECHO != 0 || got&unix.ICANON != 0 {
		t.Fatalf("terminal must be no-echo/non-canonical while prompting: lflag=%#x", got)
	}
	if _, err := m.Write([]byte(consoleKey + "\r")); err != nil {
		t.Fatal(err)
	}
	r := <-done
	if r.err != nil || r.id == nil || r.id.BootstrapToken != consoleKey {
		t.Fatalf("discover: %v %+v", r.err, r.id)
	}
	// nothing the operator typed may be echoed back on the pty
	for {
		_ = m.SetReadDeadline(time.Now().Add(150 * time.Millisecond))
		n, err := m.Read(buf)
		seen.Write(buf[:n])
		if err != nil || n == 0 {
			break
		}
	}
	if strings.Contains(seen.String(), consoleKey) {
		t.Fatal("typed key was echoed on the terminal")
	}
	if got := lflags(t, m); got&unix.ECHO == 0 || got&unix.ICANON == 0 {
		t.Fatalf("terminal not restored after input: lflag=%#x", got)
	}
	if _, err := os.Stat(stage); err != nil {
		t.Fatalf("not staged: %v", err)
	}
}

func TestConsoleFlockExcludesSecondReader(t *testing.T) {
	p := filepath.Join(t.TempDir(), "lock")
	unlock, err := lockConsole(p)
	if err != nil {
		t.Fatal(err)
	}
	if _, err2 := lockConsole(p); err2 == nil {
		t.Fatal("second reader must not get the lock")
	}
	unlock()
	u2, err := lockConsole(p)
	if err != nil {
		t.Fatalf("lock must be reusable after release: %v", err)
	}
	u2()
}
