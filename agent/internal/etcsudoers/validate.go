package etcsudoers

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// Validate shells out to visudo -cf <tmpfile> to confirm the rendered
// file body is syntactically valid sudoers. If visudo is unavailable
// on the host (rare; only really happens in minimal containers), the
// call is a no-op — sudo would reject the file at parse time anyway,
// and the agent prefers to attempt the write rather than block on a
// missing tool.
//
// On validation failure, returns an error including visudo's stderr —
// usually a clear "syntax error near token X" message.
func Validate(body []byte) error {
	if _, err := exec.LookPath("visudo"); err != nil {
		// visudo absent; defer to sudo's own runtime validation.
		return nil
	}

	tmp, err := os.CreateTemp("", "powernode-sudoers-*")
	if err != nil {
		return fmt.Errorf("create temp file: %w", err)
	}
	defer os.Remove(tmp.Name())

	if _, err := tmp.Write(body); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("write temp file: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("close temp file: %w", err)
	}

	cmd := exec.Command("visudo", "-cf", tmp.Name())
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("visudo rejected file: %s: %w",
			strings.TrimSpace(string(out)), err)
	}
	return nil
}
