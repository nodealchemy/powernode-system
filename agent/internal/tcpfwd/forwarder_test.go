package tcpfwd

import (
	"context"
	"io"
	"net"
	"strings"
	"sync"
	"testing"
	"time"
)

// startEchoServer spins up an in-process TCP echo server bound to
// 127.0.0.1:0 (kernel-assigned port). Returns the actual bound
// address and a shutdown func.
func startEchoServer(t *testing.T) (addr string, shutdown func()) {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("echo listen: %v", err)
	}
	var wg sync.WaitGroup
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			wg.Add(1)
			go func() {
				defer wg.Done()
				defer c.Close()
				_, _ = io.Copy(c, c)
			}()
		}
	}()
	return l.Addr().String(), func() {
		_ = l.Close()
		wg.Wait()
	}
}

// startForwarder builds a Forwarder pointed at the echo backend and
// returns the listen address + a context cancel + a wait func.
func startForwarder(t *testing.T, backendAddr string) (listenAddr string, cancel func(), wait func()) {
	t.Helper()
	cfg := &Config{
		Forwards: []Forward{
			{
				Listen:         "127.0.0.1:0",
				Backend:        backendAddr,
				Protocol:       "tcp",
				SubscriptionID: "test-sub-1",
			},
		},
	}
	fwd := New(cfg, nil)

	ctx, cancelFn := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		_ = fwd.Run(ctx)
		close(done)
	}()

	// Wait for the listener to be ready
	deadline := time.Now().Add(500 * time.Millisecond)
	for time.Now().Before(deadline) {
		if len(fwd.Listeners()) > 0 {
			return fwd.Listeners()[0].Addr().String(), cancelFn, func() { <-done }
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("forwarder failed to bind within 500ms")
	return "", nil, nil
}

func TestForwarder_PumpsBytesEndToEnd(t *testing.T) {
	echoAddr, shutdownEcho := startEchoServer(t)
	defer shutdownEcho()

	fwdAddr, cancel, wait := startForwarder(t, echoAddr)
	defer func() {
		cancel()
		wait()
	}()

	// Connect to the forwarder + send some bytes + verify echo.
	conn, err := net.Dial("tcp", fwdAddr)
	if err != nil {
		t.Fatalf("dial forwarder: %v", err)
	}
	defer conn.Close()

	payload := "hello, federation!"
	if _, err := conn.Write([]byte(payload)); err != nil {
		t.Fatalf("write: %v", err)
	}
	// Signal end-of-stream so echo server's io.Copy returns.
	if tc, ok := conn.(*net.TCPConn); ok {
		_ = tc.CloseWrite()
	}

	buf := make([]byte, len(payload))
	_, err = io.ReadFull(conn, buf)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if string(buf) != payload {
		t.Fatalf("expected echo %q, got %q", payload, string(buf))
	}
}

func TestForwarder_BackendUnreachable_DropsConnection(t *testing.T) {
	// Point at a port that nothing is listening on. Connect to the
	// forwarder; the forwarder's dial fails, so it closes our conn
	// immediately. We should observe an immediate EOF, not a hang.
	fwdAddr, cancel, wait := startForwarder(t, "127.0.0.1:1")
	defer func() {
		cancel()
		wait()
	}()

	conn, err := net.Dial("tcp", fwdAddr)
	if err != nil {
		t.Fatalf("dial forwarder: %v", err)
	}
	defer conn.Close()

	// Reading should immediately yield EOF (or a close-related error)
	_ = conn.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
	buf := make([]byte, 16)
	_, err = conn.Read(buf)
	if err == nil {
		t.Fatalf("expected connection close, got data")
	}
	// Either EOF or close-related — both are valid outcomes
	if err != io.EOF && !strings.Contains(err.Error(), "closed") && !strings.Contains(err.Error(), "reset") {
		t.Fatalf("expected EOF/closed/reset, got: %v", err)
	}
}

func TestForwarder_OpenConnections_TracksLifecycle(t *testing.T) {
	// Start a backend that pauses indefinitely so we can observe
	// the open-connection count mid-stream.
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	hold := make(chan struct{})
	go func() {
		conn, err := l.Accept()
		if err != nil {
			return
		}
		<-hold
		_ = conn.Close()
	}()

	cfg := &Config{
		Forwards: []Forward{
			{Listen: "127.0.0.1:0", Backend: l.Addr().String(), Protocol: "tcp",
				SubscriptionID: "metrics-test"},
		},
	}
	fwd := New(cfg, nil)
	ctx, cancel := context.WithCancel(context.Background())
	go fwd.Run(ctx)
	defer func() {
		close(hold)
		_ = l.Close()
		cancel()
	}()

	// Wait for listener to be ready
	deadline := time.Now().Add(500 * time.Millisecond)
	for time.Now().Before(deadline) && len(fwd.Listeners()) == 0 {
		time.Sleep(5 * time.Millisecond)
	}
	if len(fwd.Listeners()) == 0 {
		t.Fatal("forwarder did not bind")
	}

	// Open one connection — should increment OpenConnections.
	c, err := net.Dial("tcp", fwd.Listeners()[0].Addr().String())
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer c.Close()

	// Wait for the forwarder to register the conn (it happens in a goroutine)
	pollDeadline := time.Now().Add(500 * time.Millisecond)
	for time.Now().Before(pollDeadline) {
		if fwd.OpenConnections() >= 1 {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if fwd.OpenConnections() < 1 {
		t.Fatalf("expected OpenConnections >= 1, got %d", fwd.OpenConnections())
	}
}

func TestForwarder_BindFailureReturnsError(t *testing.T) {
	// Bind something to 127.0.0.1:0, then ask the forwarder to bind to
	// the SAME address — the second bind fails.
	blocker, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer blocker.Close()

	cfg := &Config{
		Forwards: []Forward{
			{Listen: blocker.Addr().String(), Backend: "127.0.0.1:1", Protocol: "tcp"},
		},
	}
	fwd := New(cfg, nil)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	err = fwd.Run(ctx)
	if err == nil || !strings.Contains(err.Error(), "bind") {
		t.Fatalf("expected bind error, got: %v", err)
	}
}
