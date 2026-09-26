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
	withLookups(t, map[string][]string{"ops-hub.example.test": {"192.0.2.227"}},
		[]string{"127.0.0.1", "192.0.2.227"}, nil)
	r := selfHostReconciler(t, "https://ops-hub.example.test")

	if !r.selfHosted() {
		t.Error("a platform URL resolving to one of this node's own addresses is self-hosted")
	}
}

func TestSelfHosted_FalseForARemotePlatform(t *testing.T) {
	withLookups(t, map[string][]string{"dev.example.test": {"192.0.2.22"}},
		[]string{"127.0.0.1", "192.0.2.99"}, nil)
	r := selfHostReconciler(t, "https://dev.example.test")

	if r.selfHosted() {
		t.Error("a platform on another host must not be treated as self-hosted")
	}
}

// The guard must not evaporate exactly when the platform is sick. DNS is
// often the first thing to go, and a lookup failure resolving to "not
// self-hosted" would disarm the protection during the very incident it
// exists for.
func TestSelfHosted_IsStickyOnceEstablished(t *testing.T) {
	withLookups(t, map[string][]string{"ops-hub.example.test": {"192.0.2.227"}},
		[]string{"192.0.2.227"}, nil)
	r := selfHostReconciler(t, "https://ops-hub.example.test")
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
	withLookups(t, nil, []string{"192.0.2.227"}, nil)
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

// NOTE (round 9): TestFilterDetaches_VersionBumpIsNotTreatedAsRemoval used
// to live here, proving filterUnsafeDetaches let a same-ID old/new pair
// through unconditionally so an upgrade could never be misread as a
// removal on a self-hosted node. As of the round-9 in-place-upgrade
// redesign, RunOnce itself partitions a version bump's old/new pair OUT of
// toDetach/toAttach before either ever reaches filterUnsafeDetaches (see
// that function's own updated doc) — every module it sees in toDetach is
// now a genuine removal, so the question this test asked no longer
// applies to it. The underlying invariant (a bump is never treated as a
// removal) is covered at the partition itself instead.
