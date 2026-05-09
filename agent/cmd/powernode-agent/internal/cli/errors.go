package cli

import "fmt"

// CommandError carries a structured exit code alongside the error
// message. main() unwraps the chain looking for *CommandError and
// uses its Code; absent one, the default exit code is ExitGeneric.
type CommandError struct {
	Code  int
	Stage string // optional: which step failed (mount_overlay, verify_cosign, ...)
	Err   error
}

func (e *CommandError) Error() string {
	if e == nil {
		return ""
	}
	if e.Stage != "" {
		return fmt.Sprintf("%s: %v", e.Stage, e.Err)
	}
	return e.Err.Error()
}

func (e *CommandError) Unwrap() error {
	if e == nil {
		return nil
	}
	return e.Err
}

// Errorf is a convenience for constructing a CommandError with a
// stage + Errorf-formatted message.
func Errorf(code int, stage, format string, args ...any) *CommandError {
	return &CommandError{
		Code:  code,
		Stage: stage,
		Err:   fmt.Errorf(format, args...),
	}
}
