package etcsudoers

import (
	"fmt"
	"strings"
	"time"
)

// Render returns the file body for the given grant. Format:
//
//	# Managed by Powernode: module=<module>, grant_id=<id>, generated <iso8601>
//	<user> ALL=(<runas_user>[:<runas_group>]) NOPASSWD[,<extra_flags>]: <cmd1>, <cmd2>, ...
//
// NOPASSWD is always present because service accounts have locked
// passwords ('*' in /etc/shadow). The optional flags from the manifest
// (e.g. SETENV) are appended after NOPASSWD with comma separators —
// sudo allows multiple comma-separated tag flags before the colon.
//
// generated_at is supplied by the caller (tests freeze the clock).
func Render(g Grant, generatedAt time.Time) []byte {
	runas := g.Grant.RunasUser
	if runas == "" {
		runas = "root"
	}
	if g.Grant.RunasGroup != "" {
		runas = runas + ":" + g.Grant.RunasGroup
	}

	tagFlags := []string{"NOPASSWD"}
	for _, f := range g.Grant.Flags {
		if f == "" || f == "NOPASSWD" {
			continue
		}
		tagFlags = append(tagFlags, f)
	}

	commands := strings.Join(g.Grant.Commands, ", ")

	var b strings.Builder
	fmt.Fprintf(&b, "# Managed by Powernode: module=%s, grant_id=%s, generated %s\n",
		g.ModuleName, g.Grant.ID, generatedAt.UTC().Format(time.RFC3339))
	fmt.Fprintf(&b, "%s ALL=(%s) %s: %s\n",
		g.Grant.User, runas, strings.Join(tagFlags, ","), commands)
	return []byte(b.String())
}
