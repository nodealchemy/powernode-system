//go:build !linux

package identity

import "errors"

func openConsole() (ConsoleTTY, error) {
	return nil, errors.New("console prompt: unsupported platform")
}

type platformTermios struct{}

func (platformTermios) DisableEcho(uintptr) (func(), error) {
	return nil, errors.New("console prompt: unsupported platform")
}
