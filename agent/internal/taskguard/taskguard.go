// Package taskguard validates control-plane-supplied task fields before they
// reach a root actuator on this node.
//
// # Why this lives at the agent
//
// The agent must not assume the control plane is honest. Every field in a
// System::Task's `options` blob is attacker-choosable in practice:
// POST /api/v1/system/tasks permits `options: {}` as free-form JSONB with no
// server-side schema, and the intervention policies that govern
// `system.task.*` are seeded at scope "global", which binds AI-agent callers
// as well as operators. So a prompt-injected agent holding
// system.infra_tasks.create writes the same task row a human operator does,
// and the agent json.Unmarshals it straight into a typed payload whose string
// fields then select filenames under /etc, lines inside systemd units and
// /etc/exports, and argv elements of root commands.
//
// A server-side check is worth having and is NOT a substitute: it defends only
// against a caller who goes through that controller. This is the same trust
// boundary the boot-image signature work landed on — a credential that rides
// the same task record as the thing it authorises stops a compromised artifact
// store but not whoever writes the row. Defence at the actuator is the
// load-bearing half, so the rules live here, in the process that performs the
// privileged operation.
//
// # Shape
//
// These are the PRIMITIVE rules, shared by every task family, so a field's
// rule is stated once rather than re-derived per call site. Payload-level
// composition (which field gets which rule) lives with each payload — see
// storage.MountTask.Validate and friends. Every rule fails CLOSED: an empty or
// absent value is refused unless the payload explicitly opts out, because an
// absent field is exactly how a crafted payload reaches a default.
package taskguard

import (
	"errors"
	"fmt"
	"net"
	"net/url"
	"path/filepath"
	"strings"
)

// ErrRefused wraps every refusal so callers (and tests) can distinguish a
// validation refusal from an I/O failure that happens to occur at the same
// point. Assert on this, never on message text.
var ErrRefused = errors.New("taskguard: refused")

// refuse builds a refusal that names the field and the reason and ECHOES the
// offending value, which is safe for names, paths and config tokens — they are
// operator-visible configuration and the echo is what makes the failure
// diagnosable in the platform's task error_message.
func refuse(field, reason, value string) error {
	return fmt.Errorf("%w: %s: %s (got %q)", ErrRefused, field, reason, value)
}

// refuseQuiet is the same refusal WITHOUT the value, for fields that may carry
// secret material (passwords, key material). Never widen this to echo.
func refuseQuiet(field, reason string) error {
	return fmt.Errorf("%w: %s: %s", ErrRefused, field, reason)
}

const (
	maxNameLen  = 255
	maxPathLen  = 4096
	maxTokenLen = 512
)

// criticalRoots are absolute paths the agent must never accept as the TARGET
// of a mount, an export, or a recursive chown. Masking or re-owning any of
// them converts a storage operation into a node takeover: /etc holds the
// node's configuration, /usr and the bin/lib trees hold the executables the
// platform's own units run, /persist and /var/lib/powernode hold the agent's
// durable state and last-known-good pointer, /sysroot is the composed module
// union every service runs against.
//
// A candidate is refused when it EQUALS one of these, sits UNDER one of these,
// or is a strict ANCESTOR of one of these — the ancestor case matters because
// mounting at /var masks /var/lib/powernode just as effectively as targeting
// it directly.
var criticalRoots = []string{
	"/",
	"/bin",
	"/boot",
	"/dev",
	"/etc",
	"/lib",
	"/lib32",
	"/lib64",
	"/libx32",
	"/persist",
	"/proc",
	"/root",
	"/run",
	"/sbin",
	"/sys",
	"/sysroot",
	"/usr",
	"/var/lib/powernode",
}

// hasControlChars reports whether s contains any byte that would terminate or
// start a line in a rendered systemd unit or /etc/exports entry, or truncate a
// C string in an exec argument. This is the single rule that turns "one field"
// into "arbitrary directives".
func hasControlChars(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] < 0x20 || s[i] == 0x7f {
			return true
		}
	}
	return false
}

// UnitName accepts only a bare systemd unit filename that stays inside the
// unit directory and carries one of the allowed suffixes.
//
// Two separate escapes are closed here. First, filepath.Join CLEANS a path but
// does NOT confine one, so any separator or ".." component lets the caller
// choose where a root process writes or deletes. Second, the suffix: the unit
// body is rendered with fmt.Sprintf and the platform's only legitimate
// producer emits ".mount", so restricting the suffix is what keeps an injected
// body from being started as a service.
func UnitName(field, name string, allowedSuffixes ...string) error {
	if name == "" {
		return refuse(field, "must not be empty", name)
	}
	if len(name) > maxNameLen {
		return refuse(field, "exceeds the maximum unit name length", name)
	}
	// Leading "." covers "." and ".." and hidden names in one rule.
	if strings.HasPrefix(name, ".") {
		return refuse(field, "must not begin with a dot", name)
	}
	if strings.HasPrefix(name, "-") {
		return refuse(field, "must not begin with a dash", name)
	}
	// The allow-list is what confines the value to ONE component: it excludes
	// "/" and "\\" (so filepath.Join cannot be steered), whitespace, and every
	// control character (so nothing here can end a line). Deliberately the only
	// rule covering those — a second, overlapping guard would make it
	// impossible to tell from a failing test which one is load-bearing.
	for _, r := range name {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
		case r == '-', r == '_', r == '.', r == '@', r == ':':
		default:
			return refuse(field, "contains a character not allowed in a unit name", name)
		}
	}
	if len(allowedSuffixes) == 0 {
		return nil
	}
	for _, suffix := range allowedSuffixes {
		if strings.HasSuffix(name, suffix) && len(name) > len(suffix) {
			return nil
		}
	}
	return refuse(field, "must end in "+strings.Join(allowedSuffixes, " or "), name)
}

// AbsPath accepts an absolute, already-canonical path with no traversal and no
// control characters. It says nothing about WHERE the path points — use
// TargetPath for a path the agent will write to, mount over, export or chown.
func AbsPath(field, p string) error {
	if p == "" {
		return refuse(field, "must not be empty", p)
	}
	if len(p) > maxPathLen {
		return refuse(field, "exceeds the maximum path length", p)
	}
	if hasControlChars(p) {
		return refuse(field, "must not contain control characters", p)
	}
	if !strings.HasPrefix(p, "/") {
		return refuse(field, "must be an absolute path", p)
	}
	if filepath.Clean(p) != p {
		// Catches "..", ".", doubled separators and trailing slashes in one
		// rule, and — unlike a substring search for ".." — cannot be fooled by
		// a component that merely contains dots.
		return refuse(field, "must be canonical (no '..', '.', or redundant separators)", p)
	}
	return nil
}

// TargetPath is AbsPath plus the critical-root denylist. Use it for any path
// the agent will mount over, export, chown, or create.
func TargetPath(field, p string) error {
	if err := AbsPath(field, p); err != nil {
		return err
	}
	for _, root := range criticalRoots {
		if p == root {
			return refuse(field, "is a critical system path", p)
		}
		if root != "/" && strings.HasPrefix(p, root+"/") {
			return refuse(field, "is inside the critical system path "+root, p)
		}
		if p != "/" && strings.HasPrefix(root, p+"/") {
			return refuse(field, "would mask the critical system path "+root, p)
		}
	}
	return nil
}

// Identifier accepts a value the agent splices into a filename, a unit name or
// a marker line: platform UUIDs, storage/account/credential ids, service
// names. It must be a single safe path component — no separators, no leading
// dot or dash, no traversal.
func Identifier(field, s string) error {
	if s == "" {
		return refuse(field, "must not be empty", s)
	}
	if len(s) > maxNameLen {
		return refuse(field, "exceeds the maximum identifier length", s)
	}
	if strings.HasPrefix(s, ".") || strings.HasPrefix(s, "-") {
		return refuse(field, "must not begin with a dot or dash", s)
	}
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
		case r == '-', r == '_', r == '.':
		default:
			return refuse(field, "contains a character not allowed in an identifier", s)
		}
	}
	return nil
}

// ConfigToken accepts one whitespace-free token destined for a rendered config
// line: a mount option, an export option, a Type=/What= value, a wireguard
// interface hint. Rejecting every control character is what stops one option
// from ending its line and starting a directive of its own; rejecting a
// leading dash is what stops one from becoming a flag if the value is ever
// passed as a bare argv element instead.
func ConfigToken(field, s string) error {
	if s == "" {
		return refuse(field, "must not be empty", s)
	}
	if len(s) > maxTokenLen {
		return refuse(field, "exceeds the maximum token length", s)
	}
	if hasControlChars(s) {
		return refuse(field, "must not contain control characters", s)
	}
	// Tab and the rest are already control characters; only the space needs a
	// rule of its own.
	if strings.Contains(s, " ") {
		return refuse(field, "must not contain a space", s)
	}
	if strings.HasPrefix(s, "-") {
		return refuse(field, "must not begin with a dash", s)
	}
	return nil
}

// ConfigTokens applies ConfigToken to each element, naming the index in the
// refusal so an operator can find the offending entry.
func ConfigTokens(field string, values []string) error {
	for i, v := range values {
		if err := ConfigToken(fmt.Sprintf("%s[%d]", field, i), v); err != nil {
			return err
		}
	}
	return nil
}

// Secret accepts a credential value the agent passes to a tool but must never
// echo. Same control-character and leading-dash rules as ConfigToken; the
// refusal names the field only.
func Secret(field, s string) error {
	if s == "" {
		return refuseQuiet(field, "must not be empty")
	}
	if len(s) > maxTokenLen {
		return refuseQuiet(field, "exceeds the maximum length")
	}
	if hasControlChars(s) {
		return refuseQuiet(field, "must not contain control characters")
	}
	if strings.HasPrefix(s, "-") {
		return refuseQuiet(field, "must not begin with a dash")
	}
	return nil
}

// IPAddress accepts a literal IP address. The exports renderer splices this
// value straight into an export line's host field, where a wildcard or a
// comment character would widen the grant past whatever peer the payload
// appears to name.
func IPAddress(field, s string) error {
	if s == "" {
		return refuse(field, "must not be empty", s)
	}
	if net.ParseIP(s) == nil {
		return refuse(field, "is not a literal IP address", s)
	}
	return nil
}

// Host accepts a hostname or literal IP used as the remote end of a mount.
func Host(field, s string) error {
	if s == "" {
		return refuse(field, "must not be empty", s)
	}
	if len(s) > maxNameLen {
		return refuse(field, "exceeds the maximum host length", s)
	}
	if net.ParseIP(s) != nil {
		return nil
	}
	if strings.HasPrefix(s, "-") || strings.HasSuffix(s, ".") {
		return refuse(field, "is not a valid hostname", s)
	}
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
		case r == '-', r == '.':
		default:
			return refuse(field, "is not a valid hostname or IP address", s)
		}
	}
	return nil
}

// PlatformPath accepts a control-plane-relative request path.
//
// transport.Client builds its request URL by CONCATENATION —
// `c.PlatformURL + path` — so a value that does not begin with "/" is spliced
// into the authority component and re-points the agent's mTLS-authenticated
// call at a host of the caller's choosing. Requiring a leading "/" (and
// refusing a protocol-relative "//") keeps the value inside the path.
func PlatformPath(field, p string) error {
	if p == "" {
		return refuse(field, "must not be empty", p)
	}
	if len(p) > maxPathLen {
		return refuse(field, "exceeds the maximum path length", p)
	}
	if hasControlChars(p) {
		return refuse(field, "must not contain control characters", p)
	}
	if !strings.HasPrefix(p, "/") {
		return refuse(field, "must be a platform-relative path beginning with '/'", p)
	}
	if strings.HasPrefix(p, "//") {
		return refuse(field, "must not be protocol-relative", p)
	}
	return nil
}

// httpMethods is the set of verbs a health probe may issue. A probe reads; it
// does not get to pick an arbitrary verb against whatever the node can reach.
var httpMethods = map[string]bool{"GET": true, "HEAD": true, "OPTIONS": true}

// HTTPMethod accepts only a read-shaped verb from the allow-list.
func HTTPMethod(field, s string) error {
	// No separate empty check: "" is not in the allow-list, and a second guard
	// on the same input would hide which one is doing the work.
	if !httpMethods[s] {
		return refuse(field, "is not an allowed health-check method", s)
	}
	return nil
}

// HTTPEndpoint accepts an absolute http(s) URL with a host.
//
// Two escapes are closed by the same requirement. A value beginning with "-"
// is read by curl as an OPTION rather than a URL — curl's own config-file
// option can then redirect output — and a non-http scheme turns a status-code
// probe into a local file or gopher-style fetch. Neither parses to an http(s)
// scheme with a host, so that one rule covers both.
func HTTPEndpoint(field, s string) error {
	if len(s) > maxPathLen {
		return refuse(field, "exceeds the maximum URL length", s)
	}
	// The scheme requirement below is the ONLY rule needed for the empty
	// value, for a leading dash, and for anything else that is not a URL:
	// none of them parses to an http(s) scheme. url.Parse itself rejects
	// embedded ASCII control characters. Adding separate guards for those
	// would be dead weight that reads as protection.
	u, err := url.Parse(s)
	if err != nil {
		return refuse(field, "is not a parseable URL", s)
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return refuse(field, "must use the http or https scheme", s)
	}
	if u.Host == "" {
		return refuse(field, "must name a host", s)
	}
	return nil
}
