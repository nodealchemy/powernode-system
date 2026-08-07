package main

import (
	"strings"
	"testing"
)

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
		err := prepareNextrootMounts("/run/nextroot")
		nextrootBindSources = orig
		if err == nil || !strings.Contains(err.Error(), c.wantSubstr) {
			t.Errorf("%s (src=%q): want a refusal mentioning %q, got %v", name, c.src, c.wantSubstr, err)
		}
	}
}
