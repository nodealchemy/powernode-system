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

// The denylist is deliberately SPLIT, because "critical" means two different
// things and conflating them refuses configuration the platform documents as
// supported.
//
// hardRoots hold the executables and runtime state the node and the agent
// depend on. Nothing may be mounted, exported or chowned AT them, UNDER them,
// or at an ancestor of them. System::Storage::MountPathInferenceService — the
// platform's own table of supported StorageAssignment mount paths — lists none
// of these, so denying the whole subtree costs nothing.
var hardRoots = []string{
	"/",
	"/bin",
	"/dev",
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
}

// maskRoots are trees the platform DOES place storage inside.
// MountPathInferenceService explicitly supports /etc/nginx, /etc/traefik,
// /etc/* (root-owned), /boot, and /var/lib/powernode/* (service user
// "powernode"), and the shipped gateway smoke seed uses
// /var/lib/powernode/storage/smoke-gateway. So the subtree must stay usable.
//
// What is still refused is the root ITSELF and any strict ANCESTOR of it,
// because those are the operations that mask the whole tree rather than place
// something inside it: mounting at /etc hides the node's entire configuration,
// and `find /etc -uid 0 -exec chown` re-owns it. That is exactly the case this
// work exists to stop, and it survives the carve-out — while /etc/nginx, the
// legitimate case, no longer dies with it.
var maskRoots = []string{
	"/",
	"/boot",
	"/etc",
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

// NamePrefix requires a name to carry a known prefix.
//
// Distinct from UnitName's suffix rule and applied alongside it. The platform
// stamps every storage unit with System::Storage::TaskPayloadBuilder's
// MOUNT_UNIT_PREFIX, and systemd.go's own comment states the invariant this
// enforces: "distinct prefix powernode-storage-* so we can audit + clean up
// safely without touching unrelated operator units". Without it a bare
// `persist.mount` or `sysroot.mount` is a legal unit name, and `systemctl stop`
// plus os.Remove on one of those takes down the agent's own durable state.
func NamePrefix(field, s, prefix string) error {
	if !strings.HasPrefix(s, prefix) || len(s) == len(prefix) {
		return refuse(field, "must begin with "+prefix, s)
	}
	return nil
}

// AbsPath accepts an absolute, canonical, whitespace-free path. It says
// nothing about WHERE the path points — use TargetPath for a path the agent
// will write to, mount over, export or chown.
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
	// A SPACE is the field separator in /etc/exports, so a "path" containing
	// one is really two fields: an export_path of
	// `/etc 0.0.0.0/0(rw,no_root_squash)` renders a complete, world-writable
	// export line whose first token still looks like a single path to any
	// prefix comparison. This is the only rule that catches that, and it is
	// what lets the denylist below be trusted to compare whole paths.
	if strings.Contains(p, " ") {
		return refuse(field, "must not contain a space", p)
	}
	if !strings.HasPrefix(p, "/") {
		return refuse(field, "must be an absolute path", p)
	}
	// ONE trailing slash is tolerated: the platform's own model-level format
	// (StorageAssignment#mount_path, /\A\/[\w\/.\-]+\z/) accepts it, so
	// existing rows carry it and refusing would break them at the next
	// reconcile rather than at deploy. Everything else must already be
	// canonical. This catches "..", ".", and doubled separators in one rule
	// and — unlike a substring search for ".." — cannot be fooled by a
	// component that merely contains dots.
	if filepath.Clean(p) != p && filepath.Clean(p) != strings.TrimSuffix(p, "/") {
		return refuse(field, "must be canonical (no '..', '.', or redundant separators)", p)
	}
	return nil
}

// TargetPath is AbsPath plus the two denylists. Use it for any path the agent
// will mount over, export, chown, or create.
//
// The denylists run TWICE: once on the literal value, and once on the value
// with its existing prefix symlink-resolved. filepath.Clean does NOT resolve
// symlinks, so a textual comparison alone is defeated by any pre-existing
// link — /var/run is a symlink to /run on every systemd distro, and an
// unresolved re_export_path of /var/run would be handed to `exportfs`, which
// resolves it and exports the real /run. Resolution is best-effort by
// construction (the path may not exist yet, and it can change between the
// check and the use), so it TIGHTENS the textual rule and never replaces it.
func TargetPath(field, p string) error {
	if err := AbsPath(field, p); err != nil {
		return err
	}
	clean := filepath.Clean(p)
	if err := checkRoots(field, clean, p); err != nil {
		return err
	}
	if resolved := resolveExistingPrefix(clean); resolved != clean {
		if err := checkRoots(field, resolved, p); err != nil {
			return err
		}
	}
	return nil
}

// checkRoots applies both denylists to one candidate. `reported` is the value
// echoed back, so a refusal names what the payload actually said rather than
// an internal resolution the operator never wrote.
func checkRoots(field, candidate, reported string) error {
	// Two arms, not three. hardRoots carries no ANCESTOR arm because every
	// entry is top-level: the only strict ancestor of "/usr" is "/", and "/"
	// is itself in the list, so an ancestor arm here would never fire. It was
	// present in an earlier revision and mutation testing found it dead — a
	// guard that cannot fire still reads as protection, so it is gone rather
	// than explained. maskRoots below DOES need one, because /var/lib/powernode
	// is nested and "/var" really can mask it.
	for _, root := range hardRoots {
		if candidate == root {
			return refuse(field, "is a critical system path", reported)
		}
		if root != "/" && strings.HasPrefix(candidate, root+"/") {
			return refuse(field, "is inside the critical system path "+root, reported)
		}
	}
	for _, root := range maskRoots {
		if candidate == root {
			return refuse(field, "would mask the system path "+root, reported)
		}
		if candidate != "/" && strings.HasPrefix(root, candidate+"/") {
			return refuse(field, "would mask the system path "+root, reported)
		}
	}
	return nil
}

// resolveExistingPrefix walks up until it finds a component that exists, runs
// EvalSymlinks on it, and re-attaches the remainder. A path with no existing
// ancestor resolves to itself.
func resolveExistingPrefix(p string) string {
	rest := ""
	cur := p
	for i := 0; i < 64; i++ {
		if real, err := filepath.EvalSymlinks(cur); err == nil {
			if rest == "" {
				return real
			}
			return filepath.Join(real, rest)
		}
		parent := filepath.Dir(cur)
		if parent == cur {
			return p
		}
		if rest == "" {
			rest = filepath.Base(cur)
		} else {
			rest = filepath.Join(filepath.Base(cur), rest)
		}
		cur = parent
	}
	return p
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
	// A trailing backslash is systemd's line-continuation marker: an Options=
	// line ending in one swallows the directive on the next line. It cannot
	// INJECT a directive (that still needs a newline) but it can corrupt the
	// unit, so it is refused rather than explained away.
	if strings.Contains(s, `\`) {
		return refuse(field, "must not contain a backslash", s)
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

// PeerAddress accepts the value the platform stores as a peer's address: an
// IP, or an IP with a prefix length.
//
// It is NOT IPAddress, and that difference is the whole point. Every producer
// on this path — Sdwan::PrefixAllocator.compose_address_128, through
// Sdwan::Peer#assigned_address, through System::Storage::CredentialIssuer into
// the credential's peer_ip — emits a /128, never a bare address. A rule that
// accepted only bare addresses would refuse every real storage.exports.apply
// task while passing every hand-written fixture.
func PeerAddress(field, s string) error {
	if s == "" {
		return refuse(field, "must not be empty", s)
	}
	if net.ParseIP(s) != nil {
		return nil
	}
	if _, _, err := net.ParseCIDR(s); err == nil {
		return nil
	}
	return refuse(field, "is not an IP address or CIDR", s)
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
// call at a host of the caller's choosing. Requiring a leading "/" keeps the
// value inside the path; requiring it to be CANONICAL keeps it at the endpoint
// the producer named, and also subsumes the protocol-relative "//" case, which
// Clean rewrites to a single slash. (An explicit "//" guard lived here until
// mutation testing showed no example could distinguish it from the canonical
// rule.)
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
	if strings.ContainsAny(p, "?#") {
		return refuse(field, "must not carry a query string or fragment", p)
	}
	// Without this, "/api/v1/../../x" stays on the platform origin but reaches
	// an endpoint the producer never names.
	if filepath.Clean(p) != p {
		return refuse(field, "must be canonical", p)
	}
	return nil
}

// httpMethods MIRRORS System::ModuleService::HEALTH_METHODS
// (server/app/models/system/module_service.rb). It is deliberately not
// narrower: that column is validated against this exact set, so a manifest may
// legitimately declare a POST or PUT health check, and refusing one here would
// fail the whole probe for a module the platform considers valid. It is
// deliberately not wider either — the point is that the verb cannot be chosen
// freely. Keep the two in sync if either changes.
var httpMethods = map[string]bool{"GET": true, "POST": true, "PUT": true}

// HTTPMethod accepts only a verb the platform's own model permits.
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
// HealthEndpoint accepts what System::ModuleService#health_endpoint actually
// holds. Every shipped manifest declares a RELATIVE path — "/up", "/health",
// "/metrics", "/ping", "/" — so requiring an absolute URL would refuse the
// entire fleet's health checks. An absolute http(s) URL is accepted too, for a
// service whose manifest names one.
//
// A relative path is safe to hand to curl: curl rejects it as an invalid URL,
// which is the honest per-check failure this probe is designed to report. What
// is refused is anything that would make curl do something OTHER than an
// http(s) request — a leading dash (read as an option, and curl's -K then
// names a config file), or a non-http scheme.
func HealthEndpoint(field, s string) error {
	if s == "" {
		return refuse(field, "must not be empty", s)
	}
	if strings.HasPrefix(s, "/") {
		return AbsPath(field, s)
	}
	return HTTPEndpoint(field, s)
}

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
