//go:build linux

package identity

import (
	"os"

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
