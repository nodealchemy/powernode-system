package cli

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
)

// OutputMode controls how Render emits its payload.
type OutputMode int

const (
	OutputHuman OutputMode = iota // tab-separated lines (default)
	OutputJSON                    // single JSON object per command
)

// Result is the stable shape every CLI command's --json output uses.
// Human output renders the same fields with `KEY: value` lines.
type Result struct {
	Command    string         `json:"command"`
	Status     string         `json:"status"`               // "ok" | "error" | "noop"
	ExitCode   int            `json:"exit_code"`
	DurationMs int64          `json:"duration_ms,omitempty"`
	Stage      string         `json:"stage,omitempty"`
	Error      string         `json:"error,omitempty"`
	Details    map[string]any `json:"details,omitempty"`
}

// Render writes r to w in the requested mode. Returns the encoder
// error (rare; usually io.Writer failures only).
func Render(w io.Writer, mode OutputMode, r Result) error {
	if w == nil {
		w = os.Stdout
	}
	switch mode {
	case OutputJSON:
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		return enc.Encode(r)
	default:
		return renderHuman(w, r)
	}
}

func renderHuman(w io.Writer, r Result) error {
	if _, err := fmt.Fprintf(w, "command:    %s\n", r.Command); err != nil {
		return err
	}
	if _, err := fmt.Fprintf(w, "status:     %s\n", r.Status); err != nil {
		return err
	}
	if r.Stage != "" {
		fmt.Fprintf(w, "stage:      %s\n", r.Stage)
	}
	if r.Error != "" {
		fmt.Fprintf(w, "error:      %s\n", r.Error)
	}
	if r.DurationMs > 0 {
		fmt.Fprintf(w, "duration:   %dms\n", r.DurationMs)
	}
	if r.ExitCode != 0 {
		fmt.Fprintf(w, "exit_code:  %d\n", r.ExitCode)
	}
	for k, v := range r.Details {
		fmt.Fprintf(w, "%-12s%v\n", k+":", v)
	}
	return nil
}
