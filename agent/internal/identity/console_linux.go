//go:build linux

package identity

import (
	"context"
	"errors"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"golang.org/x/sys/unix"
)

type osConsole struct{ f *os.File }

func (c osConsole) Read(p []byte) (int, error)  { return c.f.Read(p) }
func (c osConsole) Write(p []byte) (int, error) { return c.f.Write(p) }
func (c osConsole) Close() error                { return c.f.Close() }
func (c osConsole) Control(fn func(fd uintptr)) error {
	rc, err := c.f.SyscallConn()
	if err != nil {
		return err
	}
	return rc.Control(fn)
}

// openConsole opens /dev/console without becoming its controlling terminal.
func openConsole() (ConsoleTTY, error) {
	f, err := os.OpenFile("/dev/console", os.O_RDWR|unix.O_NOCTTY|unix.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	return osConsole{f}, nil
}

type platformTermios struct{}

func (platformTermios) DisableEcho(fd uintptr) (func(), error) {
	ifd := int(fd)
	orig, err := unix.IoctlGetTermios(ifd, unix.TCGETS)
	if err != nil {
		return nil, err
	}
	n := *orig
	n.Lflag &^= unix.ECHO | unix.ECHOE | unix.ECHOK | unix.ECHONL | unix.ICANON
	n.Cc[unix.VMIN] = 1
	n.Cc[unix.VTIME] = 0
	if err := unix.IoctlSetTermios(ifd, unix.TCSETS, &n); err != nil {
		return nil, err
	}
	_ = unix.IoctlSetInt(ifd, unix.TCFLSH, unix.TCIFLUSH) // drop stale type-ahead
	return func() {
		_ = unix.IoctlSetTermios(ifd, unix.TCSETS, orig)
	}, nil
}

// lockConsole takes an exclusive advisory lock so two readers never share the
// tty. The lock dies with the process; no stale-lock cleanup is needed.
func lockConsole(path string) (func(), error) {
	_ = os.MkdirAll(filepath.Dir(path), 0o700)
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := unix.Flock(int(f.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		f.Close()
		return nil, errors.New("console prompt: another reader holds the console")
	}
	return func() { _ = unix.Flock(int(f.Fd()), unix.LOCK_UN); f.Close() }, nil
}

func signalContext(ctx context.Context) (context.Context, context.CancelFunc) {
	return signal.NotifyContext(ctx, syscall.SIGTERM, syscall.SIGINT)
}

// reraiseSignal restores the default disposition and re-sends SIGTERM to
// ourselves, so the process still terminates after the terminal is restored.
func reraiseSignal() {
	signal.Reset(syscall.SIGTERM, syscall.SIGINT)
	_ = syscall.Kill(os.Getpid(), syscall.SIGTERM)
}
