package etcidentity

import "testing"

// This package renders /etc/group AUTHORITATIVELY — it replaces the base
// image's own complete file rather than merging into it. So any standard
// group missing from Baseline() is not "left to a module", it is DELETED
// from the running system.
//
// On dev-cell 2026-08-17 that produced, every boot:
//
//	systemd-tmpfiles: Failed to resolve group 'systemd-journal': No such process
//	systemd-udevd:    Unknown group 'video'/'kvm'/'render'/..., ignoring
//	utempter:         pututline: Permission denied
//
// and made `journalctl` unusable for non-root users. The udev failures are
// the material ones: the rules drop GROUP= on /dev/kvm, /dev/dri/render*,
// /dev/snd/* and the serial nodes, so unprivileged access to KVM, GPU, audio
// and serial silently breaks.
//
// The consumers are files the BASE OS ships (/usr/lib/udev/rules.d/*.rules,
// /usr/lib/tmpfiles.d/*.conf), which is why they can never be module-declared
// and must be pinned here.
func TestBaselineCarriesGroupsShippedOSConfigReferences(t *testing.T) {
	// GIDs match what base-os-ubuntu-noble ships, so the rendered file agrees
	// with the image instead of reallocating underneath it.
	required := map[string]int{
		"kmem":            15,
		"lp":              7,
		"dialout":         20,
		"cdrom":           24,
		"floppy":          25,
		"tape":            26,
		"audio":           29,
		"utmp":            43,
		"video":           44,
		"render":          994,
		"kvm":             995,
		"sgx":             996,
		"input":           997,
		"systemd-journal": 999,
	}

	got := map[string]int{}
	for _, g := range Baseline().Groups {
		got[g.Name] = g.GID
	}

	for name, wantGID := range required {
		gid, ok := got[name]
		if !ok {
			t.Errorf("group %q missing from Baseline() — shipped udev/tmpfiles config references it, "+
				"and this package's render REPLACES /etc/group, so it would be deleted from the node", name)
			continue
		}
		if gid != wantGID {
			t.Errorf("group %q has GID %d, want %d (must match base-os-ubuntu-noble)", name, gid, wantGID)
		}
	}
}

// A duplicate GID makes the rendered /etc/group ambiguous: name->gid lookups
// still work but gid->name resolution returns whichever line is scanned first,
// so file ownership and `ls -l` disagree with the group a rule targeted.
func TestBaselineGroupGIDsAreUnique(t *testing.T) {
	seen := map[int]string{}
	for _, g := range Baseline().Groups {
		if prev, dup := seen[g.GID]; dup {
			t.Errorf("GID %d assigned to both %q and %q", g.GID, prev, g.Name)
		}
		seen[g.GID] = g.Name
	}
}

// The platform is the authoritative allocator above 70000 (see reserved.go).
// A baseline group landing in that range would collide with a ServiceUser the
// server hands out, and the agent trusts the platform's value on conflict —
// so the collision would silently repoint a device group.
func TestBaselineGroupsAvoidPlatformAllocationRange(t *testing.T) {
	for _, g := range Baseline().Groups {
		if g.GID >= 70000 {
			t.Errorf("baseline group %q at GID %d intrudes on the platform allocation range (>=70000)",
				g.Name, g.GID)
		}
	}
}

// Every baseline user's PrimaryGroup must actually exist as a group, or
// getpwnam returns a user whose gid resolves to nothing and login-time group
// setup fails.
func TestBaselineUserPrimaryGroupsResolve(t *testing.T) {
	groups := map[string]int{}
	for _, g := range Baseline().Groups {
		groups[g.Name] = g.GID
	}
	for _, u := range Baseline().Users {
		gid, ok := groups[u.PrimaryGroup]
		if !ok {
			t.Errorf("user %q has PrimaryGroup %q which is not in Baseline().Groups", u.Name, u.PrimaryGroup)
			continue
		}
		if gid != u.PrimaryGID {
			t.Errorf("user %q PrimaryGID %d disagrees with group %q GID %d",
				u.Name, u.PrimaryGID, u.PrimaryGroup, gid)
		}
	}
}
