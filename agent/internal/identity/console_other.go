//go:build !linux

package identity

import (
	"context"
	"errors"
	"os"
)

func openConsole() (ConsoleTTY, error) {
	return nil, errors.New("console prompt: unsupported platform")
}

type platformTermios struct{}

func (platformTermios) DisableEcho(uintptr) (func(), error) {
	return nil, errors.New("console prompt: unsupported platform")
}

func lockConsole(string) (func(), error) { return func() {}, nil }

func signalContext(ctx context.Context) (context.Context, context.CancelFunc, func() os.Signal) {
	c, cancel := context.WithCancel(ctx)
	return c, cancel, func() os.Signal { return nil }
}

func reraiseSignal(os.Signal) {}
