package etcsudoers

import (
	"fmt"
	"strings"
	"unicode/utf8"

	"github.com/nodealchemy/powernode-system/agent/internal/etcidentity"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
)

// Grant field validation (IMP-01a0f109, sudoers half).
//
// Render concatenates user, runas, flags and commands into one sudoers rule.
// visudo -cf only proves the RESULT parses, and a second injected rule
// ("...\npnadmin ALL=(ALL) NOPASSWD: /bin/sh") parses fine; on a host with
// no visudo it is not run at all. So each field is held to a grammar that
// cannot leave its own slot, and a grant that fails is refused (never
// written) before Render is called.

// allowedTags are the sudoers Tag_Spec values a module may append after the
// always-present NOPASSWD. PASSWD is excluded (it would re-enable a password
// prompt for an account whose password is locked — a dead grant).
var allowedTags = map[string]bool{
	"NOPASSWD": true, "SETENV": true, "NOSETENV": true, "EXEC": true, "NOEXEC": true,
	"LOG_INPUT": true, "NOLOG_INPUT": true, "LOG_OUTPUT": true, "NOLOG_OUTPUT": true,
	"MAIL": true, "NOMAIL": true, "FOLLOW": true, "NOFOLLOW": true,
	"INTERCEPT": true, "NOINTERCEPT": true,
}

// commandForbidden are the characters sudoers treats as structure inside a
// Cmnd_List (',' next command, ':' next host spec, '=' runas/host
// separator, '\' escape/line continuation) — none may appear unescaped, and
// the platform never emits escapes.
const commandForbidden = ",:=\\"

// reservedGrantUsers are accounts a module grant may not name as the user
// that gains sudo: the agent's baseline accounts. pnadmin's escalation is the
// operator break-glass drop-in, never a module's.
func reservedGrantUser(name string) bool {
	for _, u := range etcidentity.Baseline().Users {
		if u.Name == name {
			return true
		}
	}
	return false
}

func checkCommand(c string) error {
	if !strings.HasPrefix(c, "/") {
		return fmt.Errorf("command %q must be an absolute path", c)
	}
	if !utf8.ValidString(c) {
		return fmt.Errorf("command %q is not valid UTF-8", c)
	}
	for _, r := range c {
		if r < 0x20 || r == 0x7f || (r >= 0x80 && r < 0xa0) {
			return fmt.Errorf("command %q contains control character %q", c, r)
		}
		if strings.ContainsRune(commandForbidden, r) {
			return fmt.Errorf("command %q contains sudoers separator %q", c, r)
		}
	}
	for _, tok := range strings.Fields(c) {
		if tok == "ALL" {
			return fmt.Errorf("command %q contains the literal token ALL", c)
		}
	}
	return nil
}

// CheckGrant validates every field Render concatenates into a drop-in.
// ModuleName and ID are checked separately by Grant.CheckFilename.
func CheckGrant(g manifest.ManifestSudoer) error {
	if !etcidentity.ValidName(g.User) {
		return fmt.Errorf("user %q is not a valid user name", g.User)
	}
	if reservedGrantUser(g.User) {
		return fmt.Errorf("user %q is a built-in account a module grant may not escalate", g.User)
	}
	if g.RunasUser != "" && !etcidentity.ValidName(g.RunasUser) {
		return fmt.Errorf("runas_user %q is not a valid user name", g.RunasUser)
	}
	if g.RunasGroup != "" && !etcidentity.ValidName(g.RunasGroup) {
		return fmt.Errorf("runas_group %q is not a valid group name", g.RunasGroup)
	}
	for _, f := range g.Flags {
		if f == "" {
			continue
		}
		if !allowedTags[f] {
			return fmt.Errorf("flag %q is not an allowed sudoers tag", f)
		}
	}
	if len(g.Commands) == 0 {
		return fmt.Errorf("no commands")
	}
	for _, c := range g.Commands {
		if err := checkCommand(c); err != nil {
			return err
		}
	}
	return nil
}
