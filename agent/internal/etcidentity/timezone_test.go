package etcidentity

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/writeguard"
)

// IMP-87ce46b9a1aa — the system timezone is rendered by the agent from a declared
// setting. /etc on a module-composed node is on the root overlay, so a
// `timedatectl set-timezone` reverts to UTC on reboot; the agent owns
// /etc/localtime and /etc/timezone the way it owns /etc/hostname.
//
// The name is validated as a zoneinfo name that EXISTS in the image: a value from
// per-node configuration must never be able to point /etc/localtime anywhere but
// a real zone file, and a name the image does not carry is refused rather than
// rendered as a dangling link.

// mkZoneRoot builds <root>/etc and <root>/usr/share/zoneinfo with the named zones
// as real TZif files, returning the root.
func mkZoneRoot(t *testing.T, zones ...string) string {
	t.Helper()
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "etc"), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, z := range zones {
		p := filepath.Join(root, "usr", "share", "zoneinfo", z)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("TZif2"+strings.Repeat("\x00", 40)), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func TestApplyTimezone_RendersLocaltimeLinkAndTimezoneFile(t *testing.T) {
	root := mkZoneRoot(t, "America/Anchorage", "UTC")

	changed, err := ApplyTimezone(root, "America/Anchorage")
	if err != nil || !changed {
		t.Fatalf("ApplyTimezone = %v, %v; want changed", changed, err)
	}

	target, err := os.Readlink(filepath.Join(root, "etc", "localtime"))
	if err != nil {
		t.Fatalf("/etc/localtime must be a symlink: %v", err)
	}
	if target != "../usr/share/zoneinfo/America/Anchorage" {
		t.Fatalf("localtime -> %q", target)
	}
	got, _ := os.ReadFile(filepath.Join(root, "etc", "timezone"))
	if string(got) != "America/Anchorage\n" {
		t.Fatalf("/etc/timezone = %q", got)
	}
	// The link resolves to the real zone file inside the same root.
	if _, err := os.Stat(filepath.Join(root, "etc", "localtime")); err != nil {
		t.Fatalf("the link must resolve inside the root: %v", err)
	}
}

func TestApplyTimezone_IdempotentAndReplacesAStaleZone(t *testing.T) {
	root := mkZoneRoot(t, "America/Anchorage", "UTC")

	if _, err := ApplyTimezone(root, "UTC"); err != nil {
		t.Fatal(err)
	}
	if changed, err := ApplyTimezone(root, "UTC"); err != nil || changed {
		t.Fatalf("an identical re-apply must be a no-op, got changed=%v err=%v", changed, err)
	}
	changed, err := ApplyTimezone(root, "America/Anchorage")
	if err != nil || !changed {
		t.Fatalf("a different zone must replace the old one: %v %v", changed, err)
	}
	if target, _ := os.Readlink(filepath.Join(root, "etc", "localtime")); !strings.HasSuffix(target, "America/Anchorage") {
		t.Fatalf("localtime -> %q", target)
	}
}

func TestApplyTimezone_ReplacesARegularLocaltimeFile(t *testing.T) {
	root := mkZoneRoot(t, "UTC")
	if err := os.WriteFile(filepath.Join(root, "etc", "localtime"), []byte("a copied zone file"), 0o644); err != nil {
		t.Fatal(err)
	}

	if changed, err := ApplyTimezone(root, "UTC"); err != nil || !changed {
		t.Fatalf("got %v %v", changed, err)
	}
	if _, err := os.Readlink(filepath.Join(root, "etc", "localtime")); err != nil {
		t.Fatalf("a regular file must be replaced by the link: %v", err)
	}
}

func TestApplyTimezone_EmptyNameIsANoOp(t *testing.T) {
	root := mkZoneRoot(t, "UTC")

	changed, err := ApplyTimezone(root, "  ")
	if err != nil || changed {
		t.Fatalf("an empty name never invents a zone: %v %v", changed, err)
	}
	if _, err := os.Lstat(filepath.Join(root, "etc", "localtime")); !os.IsNotExist(err) {
		t.Fatalf("nothing may be written for an empty name")
	}
}

func TestApplyTimezone_RefusesWhatIsNotAZoneinfoNameInTheImage(t *testing.T) {
	root := mkZoneRoot(t, "UTC")
	// A directory, a non-TZif file, and a symlink out of the zoneinfo tree.
	if err := os.MkdirAll(filepath.Join(root, "usr/share/zoneinfo/America"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "usr/share/zoneinfo/Junk"), []byte("not a zone"), 0o644); err != nil {
		t.Fatal(err)
	}
	outside := filepath.Join(t.TempDir(), "secret")
	if err := os.WriteFile(outside, []byte("TZif2"+strings.Repeat("\x00", 40)), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(root, "usr/share/zoneinfo/Escape")); err != nil {
		t.Fatal(err)
	}

	for _, bad := range []string{
		"Not/AZone", "America", "Junk", "Escape",
		"../../etc/passwd", "/etc/passwd", "America/../UTC", "UTC/", "Am erica/Anchorage",
		"UTC\nmalicious", "a;b", strings.Repeat("A", 100), ".", "..", "UTC\x00",
	} {
		changed, err := ApplyTimezone(root, bad)
		if err == nil || changed {
			t.Errorf("ApplyTimezone(%q) = %v, %v; want a refusal", bad, changed, err)
		}
		if _, lerr := os.Lstat(filepath.Join(root, "etc", "localtime")); !os.IsNotExist(lerr) {
			t.Fatalf("a refused name must leave /etc/localtime untouched (%q)", bad)
		}
		if _, lerr := os.Lstat(filepath.Join(root, "etc", "timezone")); !os.IsNotExist(lerr) {
			t.Fatalf("a refused name must leave /etc/timezone untouched (%q)", bad)
		}
	}
}

func TestValidTimezoneName_Syntax(t *testing.T) {
	for _, ok := range []string{"UTC", "America/Anchorage", "America/Argentina/Buenos_Aires", "Etc/GMT+5", "Asia/Ho_Chi_Minh"} {
		if !ValidTimezoneName(ok) {
			t.Errorf("%q should be a valid zoneinfo name", ok)
		}
	}
	for _, bad := range []string{"", "..", "a/../b", "/abs", "trail/", "sp ace", "new\nline", "semi;colon", strings.Repeat("A", 65)} {
		if ValidTimezoneName(bad) {
			t.Errorf("%q must not be a valid zoneinfo name", bad)
		}
	}
}

// The test binary's write guard refuses any write outside the sandbox: the live
// path (root == "") must be refused on its RESOLVED path, never reach /etc.
func TestApplyTimezone_LivePathIsWriteGuarded(t *testing.T) {
	var err error
	rec := writeguard.Capture(func() { _, err = ApplyTimezone("", "UTC") })
	if err == nil || len(rec) == 0 {
		t.Fatalf("the live /etc write must be refused by the write guard under test: err=%v recorded=%v", err, rec)
	}
}
