package etcidentity

import (
	"fmt"
	"path/filepath"
	"regexp"
	"strings"
	"unicode/utf8"
)

// Field validation for the identity files (IMP-01a0f109).
//
// Every field below is concatenated into a colon-separated, newline-
// terminated line of /etc/passwd, /etc/group, /etc/shadow or /etc/gshadow.
// A ':' shifts the fields of its own line; a newline starts a NEW line, so a
// gecos of "x\ntoor:x:0:0::/root:/bin/bash" is a second, uid-0 account on
// every node carrying the module. The values come from module manifests
// (via the platform), so they are checked twice: Collect refuses a manifest
// entry before it joins the Set, and the renderer re-checks every entry it
// is handed before writing it. Fail closed: an invalid entry is skipped and
// reported, never written, never "repaired".

// nameRE is the POSIX-portable user/group name the platform also enforces
// (System::ServiceUser::USERNAME_RX allows one character less; the agent
// accepts glibc's full 32).
var nameRE = regexp.MustCompile(`^[a-z_][a-z0-9_-]{0,31}$`)

// pathRE is the character set allowed in a home or shell path: no ':',
// whitespace, control characters or shell metacharacters.
var pathRE = regexp.MustCompile(`^/[A-Za-z0-9._+@/-]*$`)

const (
	maxGecosLen = 256 // system_service_users.gecos column limit
	maxHomeLen  = 256 // system_service_users.home column limit
	maxShellLen = 128 // system_service_users.shell column limit

	// ManagedIDMin/ManagedIDMax bound every uid/gid a MODULE may declare: the
	// platform allocator's fleet-global range (ServiceUser::UID_MIN..UID_MAX,
	// enforced by a DB check constraint). Anything else — 0, the system range,
	// pnadmin's 1000, nobody's 65534 — is only ever the agent's own baseline.
	ManagedIDMin = 70000
	ManagedIDMax = 99999
)

// privilegedGroups are baseline groups a module may NOT add members to.
// Membership in any of these is root or root-equivalent (raw disks, kernel
// memory, the shadow file, the sudoers %sudo rule, terminals of other users,
// system logs) or belongs to the platform's own accounts. The device groups
// (video, render, kvm, input, audio, dialout, ...) stay mergeable: granting a
// workload user GPU or KVM access is the point of declaring them.
var privilegedGroups = map[string]bool{
	"root": true, "daemon": true, "bin": true, "sys": true, "adm": true,
	"tty": true, "disk": true, "kmem": true, "sudo": true, "shadow": true,
	"utmp": true, "systemd-journal": true, "pnadmin": true, "nogroup": true,
}

// ValidName reports whether s is a safe user or group name.
func ValidName(s string) bool { return nameRE.MatchString(s) }

func safeText(s string, max int) error {
	if len(s) > max {
		return fmt.Errorf("longer than %d bytes", max)
	}
	if !utf8.ValidString(s) {
		return fmt.Errorf("not valid UTF-8")
	}
	for _, r := range s {
		if r == ':' {
			return fmt.Errorf("contains ':'")
		}
		if r < 0x20 || r == 0x7f || (r >= 0x80 && r < 0xa0) {
			return fmt.Errorf("contains control character %q", r)
		}
	}
	return nil
}

// safePath accepts "" (an empty passwd field is format-safe; the platform
// always fills both, and only a hand-built Set omits them).
func safePath(s string, max int) error {
	if s == "" {
		return nil
	}
	if len(s) > max {
		return fmt.Errorf("longer than %d bytes", max)
	}
	if !pathRE.MatchString(s) {
		return fmt.Errorf("%q is not an absolute path of [A-Za-z0-9._+@/-]", s)
	}
	for _, part := range strings.Split(s, "/") {
		if part == ".." {
			return fmt.Errorf("%q contains a '..' component", s)
		}
	}
	return nil
}

// CheckUserFields validates every field of u that reaches a rendered line.
// It does not check id ranges: the baseline legitimately uses 0..65534.
func CheckUserFields(u User) error {
	if !ValidName(u.Name) {
		return fmt.Errorf("name %q must match %s", u.Name, nameRE)
	}
	if u.UID < 0 || u.PrimaryGID < 0 {
		return fmt.Errorf("negative uid/gid")
	}
	if err := safeText(u.Gecos, maxGecosLen); err != nil {
		return fmt.Errorf("gecos %s", err)
	}
	if err := safePath(u.Home, maxHomeLen); err != nil {
		return fmt.Errorf("home %s", err)
	}
	if err := safePath(u.Shell, maxShellLen); err != nil {
		return fmt.Errorf("shell %s", err)
	}
	if u.PrimaryGroup != "" && !ValidName(u.PrimaryGroup) {
		return fmt.Errorf("primary_group %q must match %s", u.PrimaryGroup, nameRE)
	}
	for _, g := range u.SupplementaryGroups {
		if !ValidName(g) {
			return fmt.Errorf("supplementary group %q must match %s", g, nameRE)
		}
	}
	return nil
}

// CheckGroupFields validates every field of g that reaches a rendered line.
func CheckGroupFields(g Group) error {
	if !ValidName(g.Name) {
		return fmt.Errorf("name %q must match %s", g.Name, nameRE)
	}
	if g.GID < 0 {
		return fmt.Errorf("negative gid")
	}
	for _, m := range g.Members {
		if !ValidName(m) {
			return fmt.Errorf("member %q must match %s", m, nameRE)
		}
	}
	return nil
}

func managedID(id int) bool { return id >= ManagedIDMin && id <= ManagedIDMax }

// checkManifestUser adds the rules that apply only to MODULE-declared users:
// the platform's id range and no baseline name.
func checkManifestUser(u User, baselineUsers map[string]bool) error {
	if err := CheckUserFields(u); err != nil {
		return err
	}
	if baselineUsers[u.Name] {
		return fmt.Errorf("name %q is a built-in account a module may not redeclare", u.Name)
	}
	if !managedID(u.UID) {
		return fmt.Errorf("uid %d is outside the platform range %d..%d", u.UID, ManagedIDMin, ManagedIDMax)
	}
	if !managedID(u.PrimaryGID) {
		return fmt.Errorf("primary gid %d is outside the platform range %d..%d", u.PrimaryGID, ManagedIDMin, ManagedIDMax)
	}
	return nil
}

// checkManifestGroup adds the module-only rules for a group that is NEW to
// the Set (a same-name merge into a baseline group is handled by Collect).
func checkManifestGroup(g Group) error {
	if err := CheckGroupFields(g); err != nil {
		return err
	}
	if !managedID(g.GID) {
		return fmt.Errorf("gid %d is outside the platform range %d..%d", g.GID, ManagedIDMin, ManagedIDMax)
	}
	return nil
}

// cleanHome is the managed-home key two users may not share.
func cleanHome(h string) string { return filepath.Clean(h) }

// screen is the render-time re-check: it returns a copy of set holding only
// entries whose fields are safe to concatenate, plus a refusal per skip.
func screen(set *Set) (*Set, []Refusal) {
	out := &Set{}
	var refused []Refusal
	if set == nil {
		return out, nil
	}
	for _, u := range set.Users {
		if err := CheckUserFields(u); err != nil {
			refused = append(refused, Refusal{Kind: "user", Name: u.Name, Reason: err.Error()})
			continue
		}
		out.Users = append(out.Users, u)
	}
	for _, g := range set.Groups {
		if err := CheckGroupFields(g); err != nil {
			refused = append(refused, Refusal{Kind: "group", Name: g.Name, Reason: err.Error()})
			continue
		}
		out.Groups = append(out.Groups, g)
	}
	return out, refused
}
