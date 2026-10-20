//go:build linux

package identity

import (
	"context"
	"io"
	"os"
	"syscall"
	"testing"
	"time"
)

// Item 4: the signal that was received is the one re-raised, and the terminal
// is restored before it is.
func TestConsoleReRaisesTheReceivedSignal(t *testing.T) {
	for _, sig := range []syscall.Signal{syscall.SIGINT, syscall.SIGTERM} {
		f := fixtureWithState(t, "", bootCfgPinned)
		pr, pw := io.Pipe()
		f.tty.in = pr
		f.tty.closer = func() { pw.Close() }
		got := make(chan syscall.Signal, 1)
		old := killSelf
		killSelf = func(s syscall.Signal) {
			if !contains(f.ev.list(), "restore") {
				t.Error("terminal must be restored before the signal is re-raised")
			}
			got <- s
		}
		go func() { time.Sleep(150 * time.Millisecond); syscall.Kill(os.Getpid(), sig) }()
		_, _ = f.s.Discover(context.Background())
		killSelf = old
		select {
		case s := <-got:
			if s != sig {
				t.Fatalf("re-raised %v, received %v", s, sig)
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("signal %v not re-raised", sig)
		}
	}
}
