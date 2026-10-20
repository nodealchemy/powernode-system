//go:build !linux

package identity

import (
	"context"
	"errors"
)

func sysMount(context.Context, string, string, string, string) error {
	return errors.New("media scan: mounting is only supported on linux")
}

func sysUnmount(string) error { return errors.New("media scan: unmount is only supported on linux") }
