package security

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"

	"github.com/powernode/platform/extensions/system/agent/internal/mount"
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

// ApplySeccompProfile is a placeholder for the seccomp filter install step.
// True seccomp filters are typically applied per-process via prctl rather
// than as a system-wide install; the kernel API is process-local. The
// agent currently relies on systemd unit overrides (SystemCallFilter=
// directive) that point at a JSON profile shipped in the module — so this
// function's job is to write the profile into the systemd drop-in path
// for the module's services.
func ApplySeccompProfile(ctx context.Context, runner mount.Runner, profilePath string) error {
	if profilePath == "" {
		return errors.New("ApplySeccompProfile: empty path")
	}
	if _, err := os.Stat(profilePath); err != nil {
		return err
	}
	// systemd reads SystemCallFilter from drop-ins under
	// /etc/systemd/system/<unit>.d/seccomp.conf. The module's services
	// reference their profile via SystemCallFilter=@<profile>. We just
	// validate the file exists; per-unit drop-in writing happens in
	// internal/runtime/init_actions.go (M2.E.x follow-up).
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
