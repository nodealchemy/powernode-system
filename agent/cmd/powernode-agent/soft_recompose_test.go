package main

import (
	"os"
	"strings"
	"testing"
)

// The honesty invariant, pinned the only way it can be from here.
//
// Under --execute the order MUST be: survival gate -> write breadcrumb ->
// `systemctl soft-reboot`. If the gate moves below the breadcrumb write, a
// refused soft-reboot leaves an on-disk record asserting a switch that never
// happened — the LKG capturer cannot tell the difference, because a
// soft-reboot keeps the kernel boot id — and it may later freeze that
// never-run composition as last-known-good. Two shipped .conf files and
// NextrootSurvivalGate's doc both cite this ordering as the reason the gate
// makes an unmeasured drop-in safe to ship.
//
// WHY A SOURCE-ORDER TEST. RunE composes an overlay, mounts a tmpfs and
// invokes `systemctl soft-reboot`; there is no seam to drive it in-process,
// and building one for this is a larger change than the guard is worth. A
// reordering of these three statements is exactly what this must catch, and
// reading the source catches it deterministically. If RunE ever gains real
// seams, replace this with a behavioral test rather than deleting it.
func TestSoftRecompose_GateRunsBeforeTheBreadcrumbAndTheSoftReboot(t *testing.T) {
	src, err := os.ReadFile("soft_recompose.go")
	if err != nil {
		t.Fatalf("read own source: %v", err)
	}
	s := string(src)
	// Anchor on call sites, not on prose: every needle below is a call, and
	// the doc comments that discuss the ordering sit ABOVE the gate call, so
	// a comment cannot satisfy an anchor and fake the order.
	gate := strings.Index(s, "runtime.NextrootSurvivalGate(ctx,")
	crumb := strings.Index(s, "runtime.WriteBreadcrumb(runtime.BootBreadcrumbPath")
	reboot := strings.Index(s, `Run(ctx, "systemctl", "soft-reboot")`)
	for name, idx := range map[string]int{"gate": gate, "breadcrumb write": crumb, "soft-reboot": reboot} {
		if idx < 0 {
			t.Fatalf("could not find the %s call site — this guard has gone stale and is no longer checking anything", name)
		}
	}
	if !(gate < crumb) {
		t.Errorf("NextrootSurvivalGate (%d) must run BEFORE the breadcrumb write (%d): "+
			"otherwise a refused soft-reboot leaves a breadcrumb claiming the switch happened", gate, crumb)
	}
	if !(crumb < reboot) {
		t.Errorf("the breadcrumb write (%d) must precede `systemctl soft-reboot` (%d)", crumb, reboot)
	}
}

// REGRESSION GUARD — do not relax without reading prepareNextrootMounts.
//
// Binding /run into the soft-reboot nextroot destroys the running node:
// /run/nextroot lives INSIDE /run, so `mount --rbind /run /run/nextroot/run`
// recursively binds a tree containing its own destination. A subsequent
// prepare's `umount -l` of /run/nextroot then detaches the live
// /run/powernode/scratch (the running root's overlay upperdir) and every
// erofs module mount. Reproduced in an isolated mount namespace 2026-08-07;
// the control run without the /run bind kept every mount.
func TestNextrootBindSources_NeverIncludeRunOrApiFilesystems(t *testing.T) {
	forbidden := map[string]string{
		"/run":  "contains /run/nextroot itself — a recursive bind of the target's own parent; umount -l then detaches the live root's upperdir and module mounts",
		"/dev":  "systemd re-establishes API filesystems when it re-execs into the new root",
		"/proc": "systemd re-establishes API filesystems when it re-execs into the new root",
		"/sys":  "systemd re-establishes API filesystems when it re-execs into the new root",
	}
	for _, src := range nextrootBindSources {
		if why, bad := forbidden[src]; bad {
			t.Errorf("nextrootBindSources must not contain %q: %s", src, why)
		}
		if !strings.HasPrefix(src, "/") {
			t.Errorf("bind source %q must be absolute", src)
		}
	}
}

// The one thing that MUST be bound: /persist carries the enrolled PKI, the
// boot LKG and the durable /var, none of which the post-soft-reboot
// userspace can reconstruct.
func TestNextrootBindSources_IncludePersist(t *testing.T) {
	for _, src := range nextrootBindSources {
		if src == "/persist" {
			return
		}
	}
	t.Errorf("nextrootBindSources must include /persist, got %v", nextrootBindSources)
}

// Both refusal clauses must fire independently. The peer-group clause is
// the one that matches the real failure mode: "/run/powernode" does NOT
// path-contain /run/nextroot, yet binding it creates peer copies of the
// live scratch and module mounts that a later `umount -l` detaches.
func TestPrepareNextrootMounts_RefusesUnsafeSources(t *testing.T) {
	cases := map[string]struct{ src, wantSubstr string }{
		"/run itself":             {"/run", "peer group"},
		"a subtree of /run":       {"/run/powernode", "peer group"},
		"a source containing tgt": {"/", "contains the target"},
	}
	for name, c := range cases {
		orig := nextrootBindSources
		nextrootBindSources = []string{c.src}
		dests, err := prepareNextrootMounts("/run/nextroot")
		nextrootBindSources = orig
		if err == nil || !strings.Contains(err.Error(), c.wantSubstr) {
			t.Errorf("%s (src=%q): want a refusal mentioning %q, got %v", name, c.src, c.wantSubstr, err)
		}
		// A refusal must not hand back a partial carrier list: the survival
		// gate treats every destination it receives as load-bearing, and a
		// half-built list would have it vouch for mounts that were never made.
		if dests != nil {
			t.Errorf("%s (src=%q): a refusal must return no destinations, got %v", name, c.src, dests)
		}
	}
}
