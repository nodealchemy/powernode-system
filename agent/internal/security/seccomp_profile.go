package security

import (
	"fmt"
	"regexp"
	"strings"
)

// seccompProfileNamePattern is the ONLY shape a module-declared
// seccomp_profile may reduce to before it is allowed anywhere near a
// generated systemd unit.
//
// The name lands in `SystemCallFilter=@<name>`, so it must be a single
// systemd token: the character class deliberately excludes newline, carriage
// return, NUL, every other control character, whitespace, '/', '\', ';', '%'
// and '$'. A value that cannot express a newline cannot open a second
// directive in the drop-in, which is what makes the injection UNEXPRESSIBLE
// rather than stripped-after-the-fact.
//
// The class is deliberately WIDER than "valid systemd syscall set", and that
// is not an oversight — it is the boundary of this fix. `seccomp_profile` is
// ambiguous in the codebase today: ApplySeccompProfile (mac.go) os.Stat()s it
// as a FILE PATH, while this drop-in emits it as a systemd SET NAME after '@'.
// Only systemd's own predefined sets (@system-service, @basic-io, ...) are
// valid after '@', so a file base name like "deny.json" yields a directive
// systemd does not understand. Resolving which meaning the field has is a
// schema decision with its own consumers to migrate; it is tracked separately
// and is NOT what this validator decides.
//
// What this validator decides is narrower and complete on its own axis: no
// value of seccomp_profile, under EITHER reading, may express a character
// that could open a second directive in a root-owned unit. The class
// therefore admits both spellings and refuses everything else.
//
// 64 chars is a deliberate cap; no legitimate set or profile name is longer,
// and it bounds the directive.
var seccompProfileNamePattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)

// SeccompFilterName derives the SystemCallFilter set name from a manifest's
// raw `security.seccomp_profile` value and REFUSES anything that cannot
// safely appear in a root-owned systemd unit.
//
// This is the seccomp counterpart of normalizeCapName (capabilities.go): the
// capability list in the same manifest block has always been allowlisted
// before reaching CapabilityBoundingSet=, while the profile strings next to
// it were concatenated raw. Same treatment, same failure mode — a name that
// does not validate is an ERROR, never a silently-dropped or silently-
// rewritten value.
//
// Rules, in order:
//  1. A control character ANYWHERE in the raw value is fatal. This is checked
//     on the whole string, before the base name is taken, so a payload hidden
//     in a leading path segment cannot slip past by being trimmed away.
//  2. Path components are dropped (the drop-in names a filter set, not a
//     path) — the same reduction the old runtime.sanitizeProfileName did.
//  3. A single leading '@' is accepted and dropped: the writer always emits
//     exactly one '@', so "@system-service" and "system-service" are the same
//     request spelled two ways. This is an alias, not a sanitization — it can
//     never turn an invalid value into a valid one.
//  4. The result must match seccompProfileNamePattern. Anything else is
//     refused outright.
//
// Accepting a name here means only "this cannot corrupt the unit body". It is
// NOT a claim that systemd will honour the resulting directive — see the
// pattern's comment above on the field's unresolved path-vs-set-name meaning.
func SeccompFilterName(profile string) (string, error) {
	if profile == "" {
		return "", fmt.Errorf("seccomp_profile: empty")
	}
	for i, r := range profile {
		if r < 0x20 || r == 0x7f {
			return "", fmt.Errorf(
				"seccomp_profile %q: control character %#U at byte %d — a systemd drop-in directive cannot contain one",
				profile, r, i)
		}
	}
	name := profile
	if idx := strings.LastIndexByte(name, '/'); idx >= 0 {
		name = name[idx+1:]
	}
	name = strings.TrimPrefix(name, "@")
	if !seccompProfileNamePattern.MatchString(name) {
		return "", fmt.Errorf(
			"seccomp_profile %q: resolved filter-set name %q is not of the form %s",
			profile, name, seccompProfileNamePattern)
	}
	return name, nil
}
