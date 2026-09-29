//go:build !linux

package handlers

import (
	"errors"
	"os"
)

// The node agent runs only on Linux; this keeps the package building elsewhere.
func inspectOpenBeneath(root, rel string) (*os.File, error) {
	return nil, errors.New("file_stat needs openat2, which this platform does not have")
}

func inspectOpenRaced(err error) bool { return false }
