//go:build !linux

package identity

import (
	"context"
	"errors"
	"os"
)

var errMediaUnsupported = errors.New("media scan: only supported on linux")

func sysMount(context.Context, string, string, string, string, string) error {
	return errMediaUnsupported
}
func sysUnmount(string, bool) error                { return errMediaUnsupported }
func sysSetReadOnly(string) error                  { return errMediaUnsupported }
func openBeneath(string, string) (*os.File, error) { return nil, errMediaUnsupported }
