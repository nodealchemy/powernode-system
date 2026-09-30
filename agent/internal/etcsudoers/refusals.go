package etcsudoers

import "fmt"

// RefusedGrantError reports one grant ApplyAt declined to render because its
// name is not a legal drop-in name or collides with another grant's. It is a
// property of THAT grant's module, not a failure of the sudoers directory, so a
// caller can log and signal it without treating the whole apply as failed.
type RefusedGrantError struct {
	ModuleName string
	GrantID    string
	Reason     string
}

func (e *RefusedGrantError) Error() string {
	return fmt.Sprintf("refusing sudoers grant: module %q grant %q: %s", e.ModuleName, e.GrantID, e.Reason)
}

// RefusalsOnly reports whether err (as returned by Apply/ApplyAt, possibly a
// joined tree) consists SOLELY of RefusedGrantErrors. A write, validate, sweep
// or mkdir failure anywhere in the tree makes it false and stays fatal.
func RefusalsOnly(err error) bool {
	switch e := err.(type) {
	case nil:
		return false
	case *RefusedGrantError:
		return true
	case interface{ Unwrap() []error }:
		children := e.Unwrap()
		for _, c := range children {
			if !RefusalsOnly(c) {
				return false
			}
		}
		return len(children) > 0
	default:
		return false
	}
}
