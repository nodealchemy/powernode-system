package tcpfwd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"sync"
	"sync/atomic"
	"time"
)

// Forwarder runs the daemon: binds every Forward's listen address and
// pumps bytes to its backend on each accepted connection. One
// goroutine per listener for accept; one goroutine per connection for
// bidirectional copy.
type Forwarder struct {
	cfg       *Config
	logger    *slog.Logger
	dialer    *net.Dialer
	listeners []net.Listener
	wg        sync.WaitGroup
	openConns int64 // atomic; observable via OpenConnections()
}

// New constructs a Forwarder from a validated Config. Doesn't bind
// yet — call Run to start listening.
func New(cfg *Config, logger *slog.Logger) *Forwarder {
	if logger == nil {
		logger = slog.Default()
	}
	return &Forwarder{
		cfg:    cfg,
		logger: logger,
		dialer: &net.Dialer{
			Timeout:   10 * time.Second,
			KeepAlive: 30 * time.Second,
		},
	}
}

// Run binds every Forward's listen address and accepts in a goroutine
// per listener. Returns when ctx is cancelled OR when a bind fails
// (in which case any successfully-bound listeners are closed first).
func (f *Forwarder) Run(ctx context.Context) error {
	for _, fwd := range f.cfg.Forwards {
		l, err := net.Listen("tcp", fwd.Listen)
		if err != nil {
			f.shutdown()
			return fmt.Errorf("bind %s: %w", fwd.Listen, err)
		}
		f.listeners = append(f.listeners, l)
		fwd := fwd // capture per-iteration value for the goroutine
		f.wg.Add(1)
		go f.acceptLoop(ctx, l, fwd)
	}

	<-ctx.Done()
	f.shutdown()
	f.wg.Wait()
	return nil
}

// Listeners returns the bound listeners. Useful in tests when binding
// to "127.0.0.1:0" to discover the kernel-assigned port.
func (f *Forwarder) Listeners() []net.Listener {
	return f.listeners
}

// OpenConnections returns the current number of in-flight connections
// being pumped. Useful for tests + future metrics export.
func (f *Forwarder) OpenConnections() int64 {
	return atomic.LoadInt64(&f.openConns)
}

func (f *Forwarder) shutdown() {
	for _, l := range f.listeners {
		_ = l.Close()
	}
}

func (f *Forwarder) acceptLoop(ctx context.Context, l net.Listener, fwd Forward) {
	defer f.wg.Done()
	for {
		conn, err := l.Accept()
		if err != nil {
			// Listener closed (shutdown path) or context cancelled — clean exit.
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return
			}
			f.logger.Warn("tcpfwd: accept error",
				"listen", fwd.Listen,
				"err", err)
			continue
		}
		f.wg.Add(1)
		go f.handleConn(ctx, conn, fwd)
	}
}

func (f *Forwarder) handleConn(ctx context.Context, in net.Conn, fwd Forward) {
	defer f.wg.Done()
	defer in.Close()

	atomic.AddInt64(&f.openConns, 1)
	defer atomic.AddInt64(&f.openConns, -1)

	out, err := f.dialer.DialContext(ctx, "tcp", fwd.Backend)
	if err != nil {
		f.logger.Warn("tcpfwd: backend dial failed",
			"subscription_id", fwd.SubscriptionID,
			"backend", fwd.Backend,
			"err", err)
		return
	}
	defer out.Close()

	f.logger.Info("tcpfwd: connection established",
		"subscription_id", fwd.SubscriptionID,
		"listen", fwd.Listen,
		"backend", fwd.Backend,
		"client", in.RemoteAddr().String(),
	)

	bytesIn, bytesOut := pumpBidirectional(in, out)

	f.logger.Info("tcpfwd: connection closed",
		"subscription_id", fwd.SubscriptionID,
		"bytes_client_to_backend", bytesIn,
		"bytes_backend_to_client", bytesOut,
	)
}

// pumpBidirectional copies in→out and out→in concurrently, returning
// the byte counts (client→backend, backend→client). Closes the
// write half on each socket when its source returns to signal EOF
// to the other end gracefully.
func pumpBidirectional(in, out net.Conn) (bytesIn, bytesOut int64) {
	var wg sync.WaitGroup
	wg.Add(2)

	go func() {
		defer wg.Done()
		n, _ := io.Copy(out, in)
		atomic.StoreInt64(&bytesIn, n)
		if c, ok := out.(*net.TCPConn); ok {
			_ = c.CloseWrite()
		}
	}()
	go func() {
		defer wg.Done()
		n, _ := io.Copy(in, out)
		atomic.StoreInt64(&bytesOut, n)
		if c, ok := in.(*net.TCPConn); ok {
			_ = c.CloseWrite()
		}
	}()
	wg.Wait()
	return atomic.LoadInt64(&bytesIn), atomic.LoadInt64(&bytesOut)
}
