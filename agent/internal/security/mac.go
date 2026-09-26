package security

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// LoadSELinuxProfile installs a compiled SELinux policy module (.pp file)
// via semodule, resolving a bare profile NAME against the agent-owned
// SELinux profile directory (SELinuxProfileDir).
//
// Under the SECURITY-BLOCK CONTRACT
// (server/app/services/system/module_config_validator.rb) selinux_profile is a
// bare NAME — never a module-rootfs path, never an operator-supplied host
// path. The name is grammar-checked and resolved INSIDE the agent-owned
// directory; anything that could name a file outside it (an absolute path, a
// '/' or '..' component, a control character) is refused BEFORE any host
// filesystem or LSM access, and a name that does not resolve to an existing
// file fails CLOSED. This containment holds independently of the server's
// write-time grammar, per the contract's "assume a hostile config can still
// reach the agent" clause.
//
// Returns ErrSELinuxNotAvailable if SELinux isn't enabled on the host —
// checked AFTER name containment so a hostile name is refused as a
// containment error even on a host with no SELinux.
func LoadSELinuxProfile(ctx context.Context, runner mount.Runner, name string) error {
	resolved, err := resolveAgentOwnedProfile(SELinuxProfileDir, name)
	if err != nil {
		return fmt.Errorf("LoadSELinuxProfile: %w", err)
	}
	if !selinuxAvailable() {
		return ErrSELinuxNotAvailable
	}
	return runner.Run(ctx, "semodule", "-i", resolved)
}

// LoadAppArmorProfile installs an AppArmor profile via apparmor_parser
// (-r = replace if it exists), resolving a bare profile NAME against the
// agent-owned AppArmor profile directory (AppArmorProfileDir).
//
// Same containment contract as LoadSELinuxProfile: the name is grammar-checked
// and resolved INSIDE the agent-owned directory before any host filesystem or
// LSM access, and fails CLOSED when the profile is absent. An absolute path, a
// path component, or a control character is refused as a containment error —
// never handed to apparmor_parser.
func LoadAppArmorProfile(ctx context.Context, runner mount.Runner, name string) error {
	resolved, err := resolveAgentOwnedProfile(AppArmorProfileDir, name)
	if err != nil {
		return fmt.Errorf("LoadAppArmorProfile: %w", err)
	}
	if !apparmorAvailable() {
		return ErrAppArmorNotAvailable
	}
	return runner.Run(ctx, "apparmor_parser", "-r", resolved)
}

// ApplySeccompProfile validates that security.seccomp_profile resolves to a
// name in the agent-owned seccomp set (KnownSeccompSets). It does NOT touch
// the host filesystem.
//
// Enforcement is per-unit: the drop-in WriteSeccompDropIn emits
// SystemCallFilter=@<name>, which systemd applies at unit start. This function
// is the pre-flight validation on the Apply path — it used to os.Stat the
// value as a FILE PATH, which was the root of the path-vs-set-name ambiguity
// (IMP-01a02f7d-fecd): a set name like "system-service" is not a file, so the
// Stat aborted the attach for the only spelling systemd understands, while a
// file base name that survived the Stat produced an inert @deny.json directive.
// The contract resolves the field to a set NAME, so validation is name
// resolution, never a filesystem probe. Fails CLOSED for any unresolvable name.
func ApplySeccompProfile(ctx context.Context, runner mount.Runner, profile string) error {
	_ = ctx
	_ = runner
	if _, err := SeccompFilterName(profile); err != nil {
		return fmt.Errorf("ApplySeccompProfile: %w", err)
	}
	return nil
}

// systemdDropInRoot is the canonical location systemd reads unit
// overrides from. Variable so tests can redirect.
var systemdDropInRoot = "/etc/systemd/system"

// SystemdDropInRoot returns the CURRENT drop-in root — production's fixed
// "/etc/systemd/system", or whatever a test redirected it to via
// SetSystemdDropInRootForTest. Exported (round 9, R3b) so
// internal/runtime's upgrade path can snapshot and restore the exact
// on-disk bytes under the SAME root every drop-in writer in this package
// targets, without runtime hard-coding (or independently tracking) that
// path itself.
func SystemdDropInRoot() string { return systemdDropInRoot }

// WriteRawDropInFileForRestore writes body to dropInDir/filename through the
// SAME skip-if-identical, atomic tmp-write-then-rename path every typed
// drop-in writer uses (writeDropInFile) — exported for round 9's R3b
// upgrade-restore path, which restores an exact byte SNAPSHOT taken before
// the upgrade began rather than rendering fresh content from a policy, and
// so cannot go through any of the typed Write*DropIn(At) wrappers (those
// take a capability/profile list or a bool, never raw bytes).
func WriteRawDropInFileForRestore(dropInDir, filename, body string) error {
	return writeDropInFile(dropInDir, filename, body)
}

// SetSystemdDropInRootForTest redirects every per-unit drop-in writer in this
// package to dir and returns a restore func. For tests in OTHER packages that
// drive a real attach path (runtime's attachModule) and must read back what
// it wrote, without touching the host's /etc/systemd/system.
func SetSystemdDropInRootForTest(dir string) (restore func()) {
	// Exported for cross-package tests only; redirecting the drop-in root in a
	// running agent would silently write every unit's confinement elsewhere.
	if !testing.Testing() {
		panic("security.SetSystemdDropInRootForTest called outside a test binary")
	}
	prev := systemdDropInRoot
	systemdDropInRoot = dir
	return func() { systemdDropInRoot = prev }
}

// WriteSeccompDropIn renders a systemd drop-in that adds
// `SystemCallFilter=@<name>` to the named unit, where <name> is derived
// from the module's manifest-declared seccomp_profile value. The drop-in
// lands at <root>/<unit>.d/seccomp.conf where <root> defaults to
// /etc/systemd/system.
//
// The caller MUST run `systemctl daemon-reload` after a batch of
// drop-in writes (use systemd.DaemonReload). systemd reads drop-ins
// on next unit start anyway, but daemon-reload makes the change
// observable to `systemctl cat` immediately.
//
// Path-traversal guard: rejects unit names containing `..`, `/`, or
// any leading dash (which would parse as a flag). Defense in depth —
// callers should already validate unit names before reaching here.
//
// The profile value is UNTRUSTED — it comes from a module's config
// block, which no path validates before it reaches this node. It is run
// through SeccompFilterName, which refuses any value that could open a
// second directive in this root-owned unit; the derivation is done HERE
// rather than by the caller so there is no signature through which an
// unvalidated name can reach the file. A refusal is a returned error and
// NO file is written — the caller must treat that as a policy failure,
// never as "start the unit unconfined".
func WriteSeccompDropIn(unit, profilePath string) error {
	return writeSeccompDropInAt(systemdDropInRoot, unit, profilePath)
}

// WriteSeccompDropInAt is the explicit-root form of WriteSeccompDropIn for the
// pivot/compose path: the drop-in must land in the module union at `root`
// (= sysroot), where systemd-in-the-union reads it after switch_root, NOT the
// live initramfs /etc/systemd/system (the systemdDropInRoot the cloud_init path
// targets). Mirrors WriteCapabilityDropInAt. The profile value is run
// through SeccompFilterName here — the derivation is inside the writer so no
// signature carries an unvalidated name to the file, and a refusal writes NO
// drop-in (IMP-ce76b93d79fe house rule).
func WriteSeccompDropInAt(root, unit, profilePath string) error {
	base := filepath.Join(root, "etc", "systemd", "system")
	return writeSeccompDropInAt(base, unit, profilePath)
}

// RenderSeccompDropInBody is WriteSeccompDropIn's file body, factored out to
// a pure function for the same reason RenderCapabilityDropInBody is
// (capabilities.go) — RenderedPolicyHash (policy_stamp.go) and the writer
// must share one render, or a future fix to this rendering logic could ship
// with the stamp never moving (IMP-f5c0afa7183a).
func RenderSeccompDropInBody(profilePath string) (string, error) {
	name, err := SeccompFilterName(profilePath)
	if err != nil {
		return "", err
	}
	return "[Service]\nSystemCallFilter=@" + name + "\nSystemCallErrorNumber=EPERM\n", nil
}

func writeSeccompDropInAt(base, unit, profilePath string) error {
	// Shared with WriteCapabilityDropIn/WriteCapabilityDropInAt/
	// WriteUserNamespaceDropIn (capabilities.go / userns_dropin.go) — one
	// unit-name guard for all four drop-in writers, not a fourth independent
	// copy of the same three checks (empty / path-traversal / leading-dash)
	// that could silently refuse a different set of names than its siblings.
	if err := validateDropInUnitName("WriteSeccompDropIn", unit); err != nil {
		return err
	}
	body, err := RenderSeccompDropInBody(profilePath)
	if err != nil {
		return fmt.Errorf("WriteSeccompDropIn: %w", err)
	}

	dropInDir := filepath.Join(base, unit+".d")
	// writeDropInFile: atomic tmp+rename (parity with WriteCapabilityDropIn /
	// userns) so a mid-write failure can never leave a TRUNCATED directive
	// that systemd would still load — which on the pivot path (drop-in
	// writes are non-fatal/OnError) would silently weaken confinement rather
	// than fail loudly (review F5). Also skips the write entirely when the
	// on-disk content is already byte-identical (L3(c), review round 7).
	if err := writeDropInFile(dropInDir, "seccomp.conf", body); err != nil {
		return errors.New("WriteSeccompDropIn: " + err.Error())
	}
	return nil
}

// NOTE (round 9): Policy.PredictMACProfileFailure (L2 part 2, review round
// 7) used to live here — a pure pre-check for the resolvable-ahead-of-time
// subset of a Policy.Apply MAC-load failure, called from
// decideModuleSecurityPolicy so the version-bump pre-check (also removed,
// round 9) could see a bad profile name without invoking Apply. Removed as
// redundant: LoadSELinuxProfile/LoadAppArmorProfile below already do the
// identical resolve-then-availability check BEFORE ever calling
// runner.Run, so once decideModuleSecurityPolicy's result feeds directly
// into one real Policy.Apply call (the in-place upgrade's own step, before
// anything old is touched), letting Apply fail IS the check — no duplicate
// logic needed, and no separate side-effect-free path to keep in sync with
// it.

// ErrSELinuxNotAvailable signals the host doesn't have SELinux enabled.
var ErrSELinuxNotAvailable = errors.New("security: SELinux not available on this host")

// ErrAppArmorNotAvailable signals the host doesn't have AppArmor enabled.
var ErrAppArmorNotAvailable = errors.New("security: AppArmor not available on this host")

// selinuxAvailable returns true when /sys/fs/selinux is mounted (the
// canonical signal SELinux is loaded).
//
// A package var for the same reason as apparmorAvailable: a test asserting
// that a VALID contained profile reaches semodule cannot run at all on a host
// without SELinux, and neither dev-cell nor the CI container has it — so that
// assertion would never execute anywhere. Production callers never touch it.
var selinuxAvailable = func() bool {
	_, err := os.Stat("/sys/fs/selinux/enforce")
	return err == nil
}

// apparmorAvailable returns true when /sys/kernel/security/apparmor is
// present (the canonical signal AppArmor is loaded).
//
// A package var rather than a plain func, for the same reason
// AppArmorProfileDir is one: it is a test seam. The containment contract is
// host-independent, but LoadAppArmorProfile consults this AFTER resolution, so
// a test that asserts a VALID profile reaches the loader cannot run at all on
// a host without AppArmor. Leaving it a func made that assertion pass on
// dev-cell and fail in CI, where the container has no LSM — the failure said
// "present agent-owned profile rejected", which is not what happened.
// Production callers never touch this.
var apparmorAvailable = func() bool {
	_, err := os.Stat("/sys/kernel/security/apparmor")
	return err == nil
}

// SetSELinuxAvailableForTest forces selinuxAvailable()'s result for tests
// that need to exercise the semodule invocation path (LoadSELinuxProfile /
// Policy.Apply) on a host — like this project's own CI and dev-cell
// sandboxes — that has no real SELinux LSM loaded. Without this seam,
// EVERY test asserting behaviour on/after a successful profile resolution
// would be unreachable here, always short-circuiting on ErrSELinuxNotAvailable
// before ever reaching runner.Run — same problem SetSystemdDropInRootForTest
// solves for the drop-in root, and the same testing.Testing() guard.
func SetSELinuxAvailableForTest(available bool) (restore func()) {
	if !testing.Testing() {
		panic("security.SetSELinuxAvailableForTest called outside a test binary")
	}
	prev := selinuxAvailable
	selinuxAvailable = func() bool { return available }
	return func() { selinuxAvailable = prev }
}

// Agent-owned MAC profile directories. security.selinux_profile /
// security.apparmor_profile are bare NAMES resolved INSIDE these directories
// and nowhere else — never a module-rootfs path, never an operator-supplied
// host path (SECURITY-BLOCK CONTRACT). Package vars so tests can redirect them
// to a t.TempDir() (mirrors systemdDropInRoot); production callers never pass
// a path.
var (
	SELinuxProfileDir  = "/persist/var/lib/powernode/security/selinux"
	AppArmorProfileDir = "/persist/var/lib/powernode/security/apparmor"
)

// profileNamePattern is the on-node twin of the server contract's
// PROFILE_NAME_RX: a bare name, no path separators, no '..', no control or
// whitespace. Because the first character must be [A-Za-z0-9], the traversal
// spellings ".." and ".hidden" are refused, and because '/' is excluded, no
// name can escape the agent-owned directory.
var profileNamePattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$`)

// resolveAgentOwnedProfile turns a bare profile NAME into a concrete path
// inside the agent-owned directory `dir`, failing CLOSED. The order is
// deliberate and is the containment guarantee:
//
//  1. Grammar check the RAW name FIRST (before any join/normalise), so a
//     payload hidden in a path segment cannot launder itself — the same
//     rule earned in IMP-ce76b93d79fe. A '/' , '..', control char, whitespace
//     or absolute path fails here, as a containment error, on EVERY host
//     regardless of whether the LSM is present.
//  2. Join under `dir` and re-check via filepath.Clean that the result still
//     lives under `dir` (defence in depth against a grammar gap).
//  3. Require the file to EXIST, and resolve symlinks and re-check the prefix
//     so a symlink planted in the dir cannot point outside it. A missing
//     profile is a hard error — the module asked for confinement and must not
//     silently get none.
func resolveAgentOwnedProfile(dir, name string) (string, error) {
	if name == "" {
		return "", errors.New("empty profile name")
	}
	if !profileNamePattern.MatchString(name) {
		return "", fmt.Errorf(
			"profile %q is not a bare agent-owned name (no path, no '..', no whitespace/control) — "+
				"security.selinux_profile/apparmor_profile resolve against %s, never an operator-supplied path",
			name, dir)
	}
	resolved := filepath.Join(dir, name)
	cleanDir := filepath.Clean(dir)
	if resolved != filepath.Join(cleanDir, name) || !strings.HasPrefix(filepath.Clean(resolved), cleanDir+string(os.PathSeparator)) {
		return "", fmt.Errorf("profile %q escapes the agent-owned directory %s", name, dir)
	}
	real, err := filepath.EvalSymlinks(resolved)
	if err != nil {
		return "", fmt.Errorf("profile %q not found in agent-owned directory %s: %w", name, dir, err)
	}
	if !strings.HasPrefix(real, cleanDir+string(os.PathSeparator)) {
		return "", fmt.Errorf("profile %q resolves via symlink outside the agent-owned directory %s", name, dir)
	}
	return real, nil
}
