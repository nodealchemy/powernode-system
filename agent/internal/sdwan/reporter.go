// reporter.go — small helpers shared between manager.go and the
// runtime package's heartbeat hook. Kept separate so the heartbeat
// integration remains readable.
//
// Slice 1 of the SDWAN plan.

package sdwan

import "bytes"

// bodyReader turns a byte slice into the io.Reader form that
// http.NewRequest wants. Trivial wrapper; lives here so manager.go
// stays focused on reconcile semantics.
func bodyReader(b []byte) *bytes.Reader {
	return bytes.NewReader(b)
}
