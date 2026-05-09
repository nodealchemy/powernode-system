package security

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// LoadSELinuxProfile installs a compiled SELinux policy module (.pp file)
// via semodule. The path can be either:
//   - an absolute path to a .pp file, OR
//   - a relative path inside a mounted module (e.g., "policy.pp" inside
//     the module's rootfs)
//
// Returns ErrSELinuxNotAvailable if SELinux isn't enabled on the host —
// the caller should treat this as advisory (some hosts run AppArmor only
// or no LSM at all).
func LoadSELinuxProfile(ctx context.Context, runner mount.Runner, path string) error {
	if path == "" {
		return errors.New("LoadSELinuxProfile: empty path")
	}
	if !selinuxAvailable() {
		return ErrSELinuxNotAvailable
	}
	abs := absPath(path)
	if _, err := os.Stat(abs); err != nil {
		return err
	}
	return runner.Run(ctx, "semodule", "-i", abs)
}

// LoadAppArmorProfile installs an AppArmor profile via apparmor_parser
// (-r = replace if it exists). Profiles can be in regular kernel-readable
// format; AppArmor handles enforcing/complain mode tags inside the file.
func LoadAppArmorProfile(ctx context.Context, runner mount.Runner, path string) error {
	if path == "" {
		return errors.New("LoadAppArmorProfile: empty path")
	}
	if !apparmorAvailable() {
		return ErrAppArmorNotAvailable
	}
	abs := absPath(path)
	if _, err := os.Stat(abs); err != nil {
		return err
	}
	return runner.Run(ctx, "apparmor_parser", "-r", abs)
}

// ApplySeccompProfile validates that the seccomp profile file exists.
// True seccomp filters are typically applied per-process via prctl
// rather than as a system-wide install; the kernel API is process-local.
// The agent relies on systemd unit overrides (SystemCallFilter=
// directive) that point at a JSON profile shipped in the module —
// callers should follow this validation with WriteSeccompDropIn for
// each unit that should enforce the profile.
func ApplySeccompProfile(ctx context.Context, runner mount.Runner, profilePath string) error {
	if profilePath == "" {
		return errors.New("ApplySeccompProfile: empty path")
	}
	if _, err := os.Stat(profilePath); err != nil {
		return err
	}
	return nil
}

// systemdDropInRoot is the canonical location systemd reads unit
// overrides from. Variable so tests can redirect.
var systemdDropInRoot = "/etc/systemd/system"

// WriteSeccompDropIn renders a systemd drop-in that adds
// `SystemCallFilter=@<profile>` to the named unit. The drop-in lands
// at <root>/<unit>.d/seccomp.conf where <root> defaults to
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
func WriteSeccompDropIn(unit, profile, profilePath string) error {
	if unit == "" {
		return errors.New("WriteSeccompDropIn: empty unit")
	}
	if profile == "" {
		return errors.New("WriteSeccompDropIn: empty profile")
	}
	if profilePath == "" {
		return errors.New("WriteSeccompDropIn: empty profilePath")
	}
	if strings.ContainsAny(unit, "/\\\x00") || strings.Contains(unit, "..") {
		return errors.New("WriteSeccompDropIn: invalid unit name (path traversal)")
	}
	if strings.HasPrefix(unit, "-") {
		return errors.New("WriteSeccompDropIn: invalid unit name (leading dash)")
	}

	dropInDir := filepath.Join(systemdDropInRoot, unit+".d")
	if err := os.MkdirAll(dropInDir, 0o755); err != nil {
		return errors.New("WriteSeccompDropIn: mkdir " + dropInDir + ": " + err.Error())
	}
	dropInPath := filepath.Join(dropInDir, "seccomp.conf")
	body := "[Service]\nSystemCallFilter=@" + profile + "\nSystemCallErrorNumber=EPERM\n"
	if err := os.WriteFile(dropInPath, []byte(body), 0o644); err != nil {
		return errors.New("WriteSeccompDropIn: write " + dropInPath + ": " + err.Error())
	}
	return nil
}

// ErrSELinuxNotAvailable signals the host doesn't have SELinux enabled.
var ErrSELinuxNotAvailable = errors.New("security: SELinux not available on this host")

// ErrAppArmorNotAvailable signals the host doesn't have AppArmor enabled.
var ErrAppArmorNotAvailable = errors.New("security: AppArmor not available on this host")

// selinuxAvailable returns true when /sys/fs/selinux is mounted (the
// canonical signal SELinux is loaded).
func selinuxAvailable() bool {
	_, err := os.Stat("/sys/fs/selinux/enforce")
	return err == nil
}

// apparmorAvailable returns true when /sys/kernel/security/apparmor is
// present (the canonical signal AppArmor is loaded).
func apparmorAvailable() bool {
	_, err := os.Stat("/sys/kernel/security/apparmor")
	return err == nil
}

// absPath returns the absolute path of a possibly-relative input.
func absPath(p string) string {
	if filepath.IsAbs(p) {
		return p
	}
	abs, err := filepath.Abs(p)
	if err != nil {
		return p
	}
	return abs
}

// ResolveProfileInModule joins a module's rootfs mountpoint with a
// manifest-supplied profile path. Used by the mount package's attach flow
// when applying a module's security policy.
func ResolveProfileInModule(modulePath, profileRel string) string {
	if profileRel == "" {
		return ""
	}
	if filepath.IsAbs(profileRel) {
		return profileRel
	}
	return filepath.Join(modulePath, strings.TrimPrefix(profileRel, "./"))
}
