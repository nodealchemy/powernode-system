// Command tcpfwd-smoke runs the tcpfwd forwarder package (see
// agent/internal/tcpfwd) standalone, independent of the full
// powernode-agent service loop -- which requires a live platform
// connection, mTLS enrollment, and heartbeats before it will start
// anything (agent/internal/runtime/service.go's Run()).
//
// It exists so the forwarder can be exercised for real, on loopback,
// against a config file produced by the Ruby-side
// Federation::TcpForwarderConfigWriter -- e.g. from
// smoke_test_edge_exposure.rb -- without bootstrapping the rest of
// the agent. This is the only way to get genuine (a)-grade real-
// network verification for the tcpfwd paths (federated tcp,
// site-local tcpfwd); every other on-node config surface can be
// checked config-plane-only.
//
// Prints "tcpfwd-smoke: READY ..." to stdout once every configured
// forward has bound its listener (or after a 2s grace period),
// so a driving process can watch for that line instead of polling
// individual ports. Exits cleanly on SIGINT/SIGTERM, or automatically
// after -duration if set (bounded runtime for scripted smoke runs).
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/tcpfwd"
)

func main() {
	configPath := flag.String("config", tcpfwd.DefaultConfigPath, "path to tcpfwd forwards.json config")
	duration := flag.Duration("duration", 0, "auto-exit after this duration (0 = run until SIGINT/SIGTERM)")
	flag.Parse()

	cfg, err := tcpfwd.LoadConfig(*configPath)
	if err != nil {
		log.Fatalf("tcpfwd-smoke: load config: %v", err)
	}

	fwd := tcpfwd.New(cfg, nil)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if *duration > 0 {
		var timeoutCancel context.CancelFunc
		ctx, timeoutCancel = context.WithTimeout(ctx, *duration)
		defer timeoutCancel()
	}

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-sigCh
		cancel()
	}()

	runErrCh := make(chan error, 1)
	go func() { runErrCh <- fwd.Run(ctx) }()

	// Run() binds every listener synchronously before its own
	// <-ctx.Done() wait, but that happens in the goroutine above -- poll
	// Listeners() (same idiom as forwarder_test.go's startForwarder) so
	// we only announce READY once binding has actually happened.
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) && len(fwd.Listeners()) < len(cfg.Forwards) {
		time.Sleep(5 * time.Millisecond)
	}
	fmt.Printf("tcpfwd-smoke: READY forwards=%d bound=%d config=%s\n",
		len(cfg.Forwards), len(fwd.Listeners()), *configPath)

	if err := <-runErrCh; err != nil {
		log.Fatalf("tcpfwd-smoke: forwarder error: %v", err)
	}
	fmt.Println("tcpfwd-smoke: exiting")
}
