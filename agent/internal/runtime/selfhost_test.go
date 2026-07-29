package runtime

import (
	"errors"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

func withLookups(t *testing.T, hostIPs map[string][]string, local []string, hostErr error) {
	t.Helper()
	origHost, origLocal := lookupHostIPs, localInterfaceIPs
	lookupHostIPs = func(h string) ([]string, error) {
		if hostErr != nil {
			return nil, hostErr
		}
		return hostIPs[h], nil
	}
	localInterfaceIPs = func() ([]string, error) { return local, nil }
	t.Cleanup(func() { lookupHostIPs, localInterfaceIPs = origHost, origLocal })
}

func selfHostReconciler(t *testing.T, platformURL string) *Reconciler {
	t.Helper()
	return &Reconciler{cfg: ReconcilerConfig{
		PlatformURL: platformURL,
		OnError:     func(string, error) {},
	}}
}

func TestSelfHosted_TrueWhenPlatformResolvesToALocalAddress(t *testing.T) {
	withLookups(t, map[string][]string{"ops-hub.ipnode.us": {"10.125.0.227"}},
		[]string{"127.0.0.1", "10.125.0.227"}, nil)
	r := selfHostReconciler(t, "https://ops-hub.ipnode.us")

	if !r.selfHosted() {
		t.Error("a platform URL resolving to one of this node's own addresses is self-hosted")
	}
}

func TestSelfHosted_FalseForARemotePlatform(t *testing.T) {
	withLookups(t, map[string][]string{"dev.ipnode.us": {"10.125.0.22"}},
		[]string{"127.0.0.1", "10.125.0.99"}, nil)
	r := selfHostReconciler(t, "https://dev.ipnode.us")

	if r.selfHosted() {
		t.Error("a platform on another host must not be treated as self-hosted")
	}
}

// The guard must not evaporate exactly when the platform is sick. DNS is
// often the first thing to go, and a lookup failure resolving to "not
// self-hosted" would disarm the protection during the very incident it
// exists for.
func TestSelfHosted_IsStickyOnceEstablished(t *testing.T) {
	withLookups(t, map[string][]string{"ops-hub.ipnode.us": {"10.125.0.227"}},
		[]string{"10.125.0.227"}, nil)
	r := selfHostReconciler(t, "https://ops-hub.ipnode.us")
	if !r.selfHosted() {
		t.Fatal("precondition: should be self-hosted")
	}

	// DNS now fails entirely.
	withLookups(t, nil, nil, errors.New("no such host"))

	if !r.selfHosted() {
		t.Error("self-hosted must latch: a later DNS failure must not disarm the guard")
	}
}

func TestSelfHosted_FalseWhenPlatformURLIsUnset(t *testing.T) {
	withLookups(t, nil, []string{"10.125.0.227"}, nil)
	r := selfHostReconciler(t, "")

	if r.selfHosted() {
		t.Error("no platform URL means nothing to protect")
	}
}

// --- the guard itself ----------------------------------------------------

func detachFixture(t *testing.T, selfHosted bool) *Reconciler {
	t.Helper()
	if selfHosted {
		withLookups(t, map[string][]string{"h": {"10.0.0.1"}}, []string{"10.0.0.1"}, nil)
	} else {
		withLookups(t, map[string][]string{"h": {"10.0.0.2"}}, []string{"10.0.0.1"}, nil)
	}
	return selfHostReconciler(t, "https://h")
}

var (
	svcMod     = mount.Module{ID: "rails", Digest: "sha256:a"}
	contentMod = mount.Module{ID: "docs", Digest: "sha256:b"}
	fixtureMfs = map[string]*manifest.Manifest{
		"rails": {Services: []manifest.Service{{Name: "rails"}}},
		"docs":  {},
	}
)

// The invariant. On 2026-07-28 a DB-saturating CVE job made a degraded
// modules response look like "these are no longer assigned", and the agent
// detached rails/traefik/sidekiq — the services answering the very endpoint
// it reads assignments from. It could not recover, by construction.
func TestFilterDetaches_SelfHostedKeepsServiceBearingModules(t *testing.T) {
	r := detachFixture(t, true)

	kept := r.filterUnsafeDetaches(mount.ModuleStack{svcMod, contentMod}, nil, fixtureMfs)

	ids := map[string]bool{}
	for _, m := range kept {
		ids[m.ID] = true
	}
	if ids["rails"] {
		t.Error("a service-bearing module must never be live-detached on a self-hosted node")
	}
	if !ids["docs"] {
		t.Error("a content-only module is still safe to detach")
	}
}

func TestFilterDetaches_RemotePlatformIsUnaffected(t *testing.T) {
	r := detachFixture(t, false)

	kept := r.filterUnsafeDetaches(mount.ModuleStack{svcMod, contentMod}, nil, fixtureMfs)

	if len(kept) != 2 {
		t.Errorf("a normal node detaches normally; a wrong detach there is recoverable. got %v", kept)
	}
}

// An absent manifest means we cannot prove the module is content-only. On a
// self-hosted node the cost of being wrong is unrecoverable, so it is
// treated as service-bearing.
func TestFilterDetaches_UnknownManifestIsTreatedAsServiceBearing(t *testing.T) {
	r := detachFixture(t, true)

	kept := r.filterUnsafeDetaches(mount.ModuleStack{{ID: "mystery", Digest: "sha256:c"}}, nil,
		map[string]*manifest.Manifest{})

	if len(kept) != 0 {
		t.Errorf("an unknown manifest must not be assumed safe, got %v", kept)
	}
}

func TestFilterDetaches_ReportsWhatItRefused(t *testing.T) {
	var stages []string
	r := detachFixture(t, true)
	r.cfg.OnError = func(stage string, _ error) { stages = append(stages, stage) }

	r.filterUnsafeDetaches(mount.ModuleStack{svcMod}, nil, fixtureMfs)

	found := false
	for _, s := range stages {
		if s == "reconciler:self_host_detach_refused" {
			found = true
		}
	}
	if !found {
		// Silently declining to act is how a guard becomes invisible and
		// someone later "fixes" the mystery by removing it.
		t.Errorf("a refused detach must be surfaced, got stages %v", stages)
	}
}

func TestFilterDetaches_EmptyInputIsANoop(t *testing.T) {
	r := detachFixture(t, true)
	if got := r.filterUnsafeDetaches(nil, nil, fixtureMfs); len(got) != 0 {
		t.Errorf("got %v, want empty", got)
	}
}

// The guard must not block upgrades. A version bump puts the OLD digest in
// toDetach and the NEW one in toAttach; refusing that detach would leave two
// versions of the same module attached simultaneously and would stop
// ops-hub — the node that most needs fixes — from ever receiving one.
func TestFilterDetaches_VersionBumpIsNotTreatedAsRemoval(t *testing.T) {
	r := detachFixture(t, true)
	oldRails := mount.Module{ID: "rails", Digest: "sha256:old"}
	newRails := mount.Module{ID: "rails", Digest: "sha256:new"}

	kept := r.filterUnsafeDetaches(mount.ModuleStack{oldRails}, mount.ModuleStack{newRails}, fixtureMfs)

	if len(kept) != 1 || kept[0].Digest != "sha256:old" {
		t.Errorf("a service-bearing module WITH a successor must still detach, got %v", kept)
	}
}
