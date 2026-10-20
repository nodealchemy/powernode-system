//go:build !linux

package identity

import (
	"context"
	"errors"
)

func openConsole() (ConsoleTTY, error) {
	return nil, errors.New("console prompt: unsupported platform")
}

type platformTermios struct{}

func (platformTermios) DisableEcho(uintptr) (func(), error) {
	return nil, errors.New("console prompt: unsupported platform")
}

func lockConsole(string) (func(), error) { return func() {}, nil }

func signalContext(ctx context.Context) (context.Context, context.CancelFunc) {
	return context.WithCancel(ctx)
}

func reraiseSignal() {}
