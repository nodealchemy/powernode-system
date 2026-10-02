package handlers

import (
	"bytes"
	"encoding/json"
	"io"
	"strings"

	"github.com/nodealchemy/powernode-system/agent/internal/runtime/tasks"
)

// fullLogMaxBytes caps the log uploaded for one task (IMP-dbc22946e05c). The
// result's log_tail keeps only the last 4 KB of stdout and 128 KB of stderr, so a
// failure whose cause scrolled out of that window could not be diagnosed over MCP;
// the platform now stores the whole scrubbed log, up to this bound. The END is
// kept, because the cause of a failure is at the end, and the truncation is
// stated in the upload (truncated, original_bytes). The server enforces its own
// cap on top of this one.
var fullLogMaxBytes = 1 << 20

// fullLogTruncatedMarker leads a log whose earlier output was cut.
const fullLogTruncatedMarker = "...[log truncated: earlier output omitted]\n"

// taskLogPath is the node-API route a task's log is uploaded to.
func taskLogPath(taskID string) string {
	return "/api/v1/system/node_api/status/tasks/" + taskID + "/log"
}

// scrubbedFullLog is the whole of a script's output as one scrubbed, bounded
// string, the full-log counterpart of scrubbedLogTail and built on the SAME
// scrub: every secret the task was handed is removed from each WHOLE stream
// first, then every headed private-key block, and only then is the log cut, so
// no cut can land inside a secret and leave a fragment. Returns the text, the
// size of the scrubbed log BEFORE the cap (framing included, not the raw stream
// size), and whether the cap cut it.
func scrubbedFullLog(stdout, stderr []byte, secrets ...string) (string, int, bool) {
	out := removeKeyBlocks([]byte(scrubSecrets(string(stdout), secrets...)))
	errb := removeKeyBlocks([]byte(scrubSecrets(string(stderr), secrets...)))

	var b strings.Builder
	b.WriteString("stdout:\n")
	b.Write(bytes.TrimRight(out, "\n"))
	b.WriteString("\nstderr:\n")
	b.Write(bytes.TrimRight(errb, "\n"))
	b.WriteString("\n")
	full := b.String()

	if len(full) <= fullLogMaxBytes {
		return full, len(full), false
	}
	// The marker counts inside the cap, so the uploaded log never exceeds it.
	keep := fullLogMaxBytes - len(fullLogTruncatedMarker)
	if keep < 0 {
		keep = 0
	}
	cut := full[len(full)-keep:]
	// Drop the partial first line, and any PEM-shaped body the cut left headerless.
	if i := strings.IndexByte(cut, '\n'); i >= 0 && i+1 < len(cut) {
		cut = cut[i+1:]
	}
	return fullLogTruncatedMarker + dropCutKeyBody(cut), len(full), true
}

// uploadTaskLog posts the scrubbed log for a task and reports whether the
// platform accepted it. It NEVER returns an error to the caller: a log that could
// not be uploaded must not fail a build that otherwise succeeded, and on the
// failure path it must not mask the build's own error. The log is best-effort
// diagnostics, so a refusal or a transport error only reads as false.
func uploadTaskLog(h tasks.HTTPClient, taskID, log string, originalBytes int, truncated bool) bool {
	if h == nil || taskID == "" {
		return false
	}
	body, err := json.Marshal(map[string]any{
		"log": log, "original_bytes": originalBytes, "truncated": truncated,
	})
	if err != nil {
		return false
	}
	resp, err := h.PostJSON(taskLogPath(taskID), body)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<16))
	return resp.StatusCode >= 200 && resp.StatusCode < 300
}

// uploadBuildLog scrubs and uploads a finished script's whole output, skipping
// quietly when there is nothing to attach it to (no task id).
func uploadBuildLog(h tasks.HTTPClient, taskID string, stdout, stderr []byte, secrets ...string) bool {
	if taskID == "" {
		return false
	}
	log, original, truncated := scrubbedFullLog(stdout, stderr, secrets...)
	return uploadTaskLog(h, taskID, log, original, truncated)
}
