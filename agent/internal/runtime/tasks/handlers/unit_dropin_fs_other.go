//go:build !linux

package handlers

import "errors"

// The node agent runs only on Linux; this keeps the package building elsewhere.
func writeDropin(root, unit, file string, content []byte) (bool, error) {
	return false, errors.New("unit.dropin needs openat semantics, which this platform does not have")
}

func removeDropin(root, unit, file string) (bool, error) {
	return false, errors.New("unit.dropin needs openat semantics, which this platform does not have")
}
