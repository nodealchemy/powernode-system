package taskguard

import (
	"path"
	"strings"
)

// Rules for the read-only node inspection task (probe.node_inspect).
//
// Every collector it runs is a fixed command or a fixed read, and the only
// values the control plane chooses are the arguments checked here. The task is
// governed auto_approve, so these rules are what stand between a hostile
// payload and a root read of the node: an interface name that becomes a wg
// subcommand, a unit name that becomes an option, a path that reaches a secret.

// Refused builds a refusal for a rule a task handler enforces itself, one that
// needs the node (a unit that must exist, a path's symlink target) and so
// cannot live here as a pure check. It wraps ErrRefused like every rule above.
func Refused(field, reason, value string) error { return refuse(field, reason, value) }

// ifaceMaxLen is IFNAMSIZ-1: the kernel refuses a longer interface name.
const ifaceMaxLen = 15

// reservedInterfaces are words `wg show` reads as something other than an
// interface. "all" is the whole-host form, which prints every interface and,
// with the dump subcommand, every key; "interfaces" lists them. Neither is a
// name a node can give an interface it wants inspected.
var reservedInterfaces = map[string]bool{"all": true, "interfaces": true}

// InterfaceName accepts a network interface name for `wg show <name>`.
//
// The charset is stricter than the kernel's (which admits almost anything but
// "/" and whitespace) because the value is an argv element of a root command:
// no leading dash, so it cannot become an option, and no leading dot.
func InterfaceName(field, s string) error {
	if s == "" {
		return refuse(field, "must not be empty", s)
	}
	if len(s) > ifaceMaxLen {
		return refuse(field, "exceeds the maximum interface name length", s)
	}
	if strings.HasPrefix(s, "-") || strings.HasPrefix(s, ".") {
		return refuse(field, "must not begin with a dash or dot", s)
	}
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
		case r == '-', r == '_', r == '.':
		default:
			return refuse(field, "contains a character not allowed in an interface name", s)
		}
	}
	if reservedInterfaces[strings.ToLower(s)] {
		return refuse(field, "is a reserved word, not an interface name", s)
	}
	return nil
}

// systemdUnitSuffixes are the unit types systemd defines. A bare name with none
// of them is refused so that `journalctl -u sshd` style shorthand, which systemd
// expands and globs, never reaches a collector.
var systemdUnitSuffixes = []string{
	".service", ".socket", ".target", ".timer", ".mount", ".automount",
	".path", ".slice", ".scope", ".swap", ".device",
}

// SystemdUnit accepts a full systemd unit name: UnitName's single-component,
// no-dot-prefix, no-dash-prefix charset rules plus a required unit-type suffix.
// The charset excludes the glob characters, so a name can never be a pattern.
func SystemdUnit(field, name string) error {
	return UnitName(field, name, systemdUnitSuffixes...)
}

// inspectAllowedPrefixes are the ONLY trees file_stat may look in. An
// allow-list, not a deny-list, because the failure directions differ: a
// deny-list is open by default, so every secret location nobody has thought of
// is readable, while an allow-list is closed by default and its failure mode is
// a path an operator has to ask to have added. Everything the agent's own
// diagnosis has needed sits under these: unit files and drop-ins and node
// config (/etc), installed binaries and libraries (/usr), the boot entries
// (/boot), and the agent's own state and marker files.
//
// /proc, /sys, /dev, /root, /home, /tmp, /var/log and /persist/volumes are
// absent on purpose. /proc/<pid>/environ in particular is refused by omission,
// not by a rule that could be edited out.
var inspectAllowedPrefixes = []string{
	"/etc",
	"/usr",
	"/boot",
	"/persist/var/lib/powernode",
	"/persist/cache/modules",
	"/var/lib/powernode",
	"/run/powernode",
}

// inspectDeniedSegments are directory components that hold secret material
// wherever they appear under an allowed tree.
var inspectDeniedSegments = map[string]bool{
	"pki": true, "private": true, "secrets": true, "secret": true, "keys": true,
	"credentials": true, "credstore": true, "vault": true, "wireguard": true,
	"security": true, ".ssh": true, ".gnupg": true,
}

// inspectDeniedSubstrings mark a file name as a secret. Substrings, lowercased:
// the point is the name's meaning, and a file called client_secret or
// db-password is one whatever its extension.
var inspectDeniedSubstrings = []string{
	"shadow", "opasswd", "priv", "secret", "token", "password", "passphrase",
	"credential", "htpasswd", "netrc", "pgpass",
}

var inspectDeniedSuffixes = []string{
	".key", "_key", "-key", "-key.pem", "_key.pem", ".p12", ".pfx", ".jks", ".keystore", ".env",
}

var inspectDeniedPrefixes = []string{"id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", ".env"}

// InspectFilePath accepts a path the file_stat collector may stat and hash.
//
// file_stat returns metadata and a sha256, never contents, but the hash is not
// harmless for a secret: the sha256 of a low-entropy value (a shadow entry, a
// token, a password file) is an offline oracle for it. So the secret locations
// are refused even though nothing is read back.
//
// The rule is textual and runs on the value as given. The handler runs it AGAIN
// on the symlink-resolved path, because a link inside an allowed tree can point
// anywhere and a textual rule alone follows it out.
func InspectFilePath(field, p string) error {
	if err := AbsPath(field, p); err != nil {
		return err
	}
	clean := strings.TrimSuffix(p, "/")
	if clean == "" {
		return refuse(field, "is not under a path file_stat may inspect", p)
	}
	if !inspectAllowedPath(clean) {
		return refuse(field, "is not under a path file_stat may inspect", p)
	}
	segments := strings.Split(strings.TrimPrefix(clean, "/"), "/")
	for i, seg := range segments {
		lower := strings.ToLower(seg)
		if inspectDeniedSegments[lower] {
			return refuse(field, "is a secret location", p)
		}
		// The file name (last segment) is judged by what it says it is.
		if i == len(segments)-1 && inspectSecretName(lower) {
			return refuse(field, "is a secret location", p)
		}
	}
	// A private host key is <name>_key; its public half is <name>_key.pub and
	// is not secret. Judging by suffix already leaves the .pub alone.
	return nil
}

func inspectAllowedPath(clean string) bool {
	clean = path.Clean(clean)
	for _, prefix := range inspectAllowedPrefixes {
		if clean == prefix || strings.HasPrefix(clean, prefix+"/") {
			return true
		}
	}
	return false
}

func inspectSecretName(lower string) bool {
	for _, s := range inspectDeniedSubstrings {
		if strings.Contains(lower, s) {
			return true
		}
	}
	for _, s := range inspectDeniedSuffixes {
		if strings.HasSuffix(lower, s) {
			return true
		}
	}
	for _, s := range inspectDeniedPrefixes {
		if strings.HasPrefix(lower, s) {
			return true
		}
	}
	return false
}
