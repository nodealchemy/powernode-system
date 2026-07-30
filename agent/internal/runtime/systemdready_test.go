package runtime

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/bootslots"
	"github.com/nodealchemy/powernode-system/agent/internal/espwrite"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

func stubSystemctl(out string, err error) systemctlFunc {
	return func(_ context.Context, _ ...string) ([]byte, error) {
		return []byte(out), err
	}
}

// THE mutation-critical case, and the reason this prober does not use
// mount.Runner. `systemctl is-system-running` exits 1 to report degraded, so the
// state arrives ALONGSIDE an error. Any refactor that checks err before reading
// stdout — the natural way to write it — turns every degraded node into a node
// that never blesses, which is the exact bug this whole change is fixing.
func TestSystemdReadyProber_DegradedIsHealthyDespiteNonZeroExit(t *testing.T) {
	p := &systemdReadyProber{run: stubSystemctl("degraded\n", &exec.ExitError{})}

	healthy, err := p.Healthy(context.Background())
	if err != nil {
		t.Fatalf("returned an error for a booted system: %v", err)
	}
	if !healthy {
		t.Fatal("reported a degraded system as unhealthy — degraded means the boot COMPLETED and " +
			"some unrelated unit is failed (claude-tmux with no credential, on ops-cell). " +
			"Refusing to bless over that reverts good images forever, one failed unit at a time")
	}
}

func TestSystemdReadyProber_States(t *testing.T) {
	for _, c := range []struct {
		state string
		want  bool
	}{
		{"running", true},
		{"degraded", true},
		// Not ready yet — the boot has not finished, so nothing is proven.
		{"initializing", false},
		{"starting", false},
		// Actively bad, or on the way down: never a moment to disarm a rollback.
		{"maintenance", false},
		{"stopping", false},
		{"offline", false},
		{"unknown", false},
	} {
		p := &systemdReadyProber{run: stubSystemctl(c.state+"\n", nil)}
		healthy, err := p.Healthy(context.Background())
		if err != nil {
			t.Errorf("%s: unexpected error %v", c.state, err)
		}
		if healthy != c.want {
			t.Errorf("%s: healthy = %v, want %v", c.state, healthy, c.want)
		}
	}
}

// No state at all means the probe itself failed (systemctl missing, or the node
// is not systemd-managed). That must surface as an ERROR, not a quiet false: the
// consecutive run resets either way, but only an error is distinguishable in the
// logs from "still coming up".
func TestSystemdReadyProber_MissingSystemctlIsAnError(t *testing.T) {
	p := &systemdReadyProber{run: stubSystemctl("", errors.New("exec: \"systemctl\": not found"))}

	healthy, err := p.Healthy(context.Background())
	if healthy {
		t.Fatal("reported healthy with no state at all")
	}
	if err == nil {
		t.Fatal("swallowed a probe failure — an unrunnable gate would look identical to a slow boot")
	}
	if !strings.Contains(err.Error(), "is-system-running") {
		t.Errorf("error does not name the probe: %v", err)
	}
}

// Empty output with a zero exit is still no answer.
func TestSystemdReadyProber_EmptyOutputIsAnError(t *testing.T) {
	p := &systemdReadyProber{run: stubSystemctl("  \n", nil)}

	if healthy, err := p.Healthy(context.Background()); healthy || err == nil {
		t.Fatalf("healthy=%v err=%v, want false + error", healthy, err)
	}
}

// The gate selection, which is where the original defect lived: an unconfigured
// node was handed https://127.0.0.1/up — a URL only a node running the platform
// web tier can answer — so it failed the gate on every probe, forever.
func TestBootConfirmer_UnconfiguredNodeGetsTheLocalGateNotLoopback(t *testing.T) {
	c := &BootConfirmer{} // no AppHealthURL, no breadcrumb

	gate := c.resolveGate()
	if _, ok := gate.prober.(*systemdReadyProber); !ok {
		t.Fatalf("gate prober = %T, want *systemdReadyProber. A node with no configured health "+
			"endpoint must be gated on something it can actually pass", gate.prober)
	}
	if !strings.Contains(gate.desc, "systemd") {
		t.Errorf("desc = %q, want it to name the local gate", gate.desc)
	}
}

// The negative control: a hub that DOES declare an endpoint must still be gated
// on it. If this regressed, hubs would bless on "systemd came up" while their
// web tier was down — disarming the rollback that exists for exactly that.
func TestBootConfirmer_ConfiguredURLStillUsesTheHTTPGate(t *testing.T) {
	c := &BootConfirmer{AppHealthURL: "https://127.0.0.1/up"}

	gate := c.resolveGate()
	if _, ok := gate.prober.(*HTTPHealthProber); !ok {
		t.Fatalf("gate prober = %T, want *HTTPHealthProber for an explicitly configured URL", gate.prober)
	}
	if !strings.Contains(gate.desc, "https://127.0.0.1/up") {
		t.Errorf("desc = %q, want the probed URL named", gate.desc)
	}
}

// The breadcrumb is the ONLY route by which a real node is told to use the HTTP
// gate — nothing in production sets Config.AppHealthURL, so the two tests above
// exercise a field the fleet never populates. This covers the path that actually
// carries the SiteSetting to the node.
func TestBootConfirmer_BreadcrumbURLSelectsTheHTTPGate(t *testing.T) {
	path := filepath.Join(t.TempDir(), "boot-composed.json")
	if err := os.WriteFile(path, []byte(
		`{"app_health":{"url":"https://127.0.0.1/up","required_consecutive":5,"poll_interval_seconds":7}}`,
	), 0o644); err != nil {
		t.Fatal(err)
	}
	c := &BootConfirmer{BreadcrumbPath: path} // no AppHealthURL — the real shape

	gate := c.resolveGate()
	if _, ok := gate.prober.(*HTTPHealthProber); !ok {
		t.Fatalf("gate prober = %T, want *HTTPHealthProber — a node whose breadcrumb names a health "+
			"endpoint must be gated on it, or the SiteSetting that delivers it does nothing", gate.prober)
	}
	// The rest of the breadcrumb's gate config must survive the same path.
	if gate.required != 5 {
		t.Errorf("required = %d, want 5 from the breadcrumb", gate.required)
	}
	if gate.interval != 7*time.Second {
		t.Errorf("interval = %v, want 7s from the breadcrumb", gate.interval)
	}
}

// REACHABILITY. bootupgrade's own tests prove ResolveFallback resolves a
// rollback correctly; they cannot prove the confirmer ever CALLS it. That gap is
// how the last bless fix in this file shipped as dead code — correct logic
// sitting below a cheap short-circuit that never let anything reach it — so the
// test that it runs belongs here, in the caller's package.
//
// The prober NEVER returns healthy, which is the whole point: a rolled-back node
// is the least likely of all to look healthy, and the verdict must land anyway.
func TestBootConfirmer_ResolvesARollbackWithoutEverPassingTheGate(t *testing.T) {
	restore := bootslots.SetStatePathForTest(filepath.Join(t.TempDir(), "boot-slot.json"))
	defer restore()
	// A boot_id differing from the one that armed the attempt is what makes this
	// a rollback rather than an upgrade that has not been tried yet.
	bootID := filepath.Join(t.TempDir(), "boot_id")
	if err := os.WriteFile(bootID, []byte("22222222-2222-2222-2222-222222222222\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	defer bootslots.SetBootIDPathForTest(bootID)()
	if err := bootslots.Update(func(st *bootslots.State) error {
		st.Active = "a"
		st.Pending = "b"
		st.PendingSHA = "1111111111111111111111111111111111111111"
		st.PendingBootID = "11111111-1111-1111-1111-111111111111"
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	// systemd-boot says we booted slot a — i.e. the trial of b fell back.
	ev := t.TempDir()
	for name, body := range map[string][]byte{
		"LoaderEntrySelected-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f": utf16leEFIVar("powernode-a.efi"),
		"LoaderInfo-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f":          []byte("systemd-boot 255.4"),
	} {
		if err := os.WriteFile(filepath.Join(ev, name), body, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	defer bootslots.SetEfivarsDirForTest(ev)()
	defer espwrite.SetESPMountForTest(t.TempDir())()

	prober := &scriptedProber{results: []bool{false}} // never healthy, ever
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	c := &BootConfirmer{
		Prober:       prober,
		PollInterval: 5 * time.Millisecond,
		Runner:       &recordingRunner{},
		BootedGitSHA: "2222222222222222222222222222222222222222",
	}
	if err := c.Run(ctx); err != nil {
		t.Fatalf("Run: %v", err)
	}

	if got := bootslots.Load().Pending; got != "" {
		t.Fatalf("Pending = %q after a provable rollback — ResolveFallback is not reached from Run, "+
			"so the ungated verdict is dead code and the attempt stays pending for the whole boot", got)
	}
	// Nothing is owed once the attempt is resolved, so there is nothing left to
	// gate on and the confirmer must not sit there probing for the rest of the boot.
	if n := prober.probes(); n != 0 {
		t.Errorf("probed %d times after resolving the verdict — no bless is owed, so the gate is moot", n)
	}
}

// A gate that cannot be passed is otherwise completely silent — the node simply
// never blesses, and the only symptom appears days later as an image that
// reverted. Fired once, not once per tick.
func TestBootConfirmer_WarnsWhenTheGateNeverPasses(t *testing.T) {
	pendingUpgrade(t)
	rec := &errRecorder{}

	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	c := &BootConfirmer{
		Prober:        &scriptedProber{results: []bool{false}},
		PollInterval:  5 * time.Millisecond,
		GateWarnAfter: 20 * time.Millisecond,
		Runner:        mount.ExecRunner{},
		OnError:       rec.record,
	}
	if err := c.Run(ctx); err != nil {
		t.Fatalf("Run: %v", err)
	}

	switch n := rec.count("boot_confirm_gate"); n {
	case 0:
		t.Fatal("an unpassable gate reported NOTHING — this failure mode is invisible until an " +
			"image mysteriously reverts, which is how it went unnoticed on ops-cell")
	case 1: // exactly right
	default:
		t.Errorf("reported the same stuck gate %d times; it must be said once, not once per tick", n)
	}
}

// The warning must not fire on a node that simply took a few probes to come up.
func TestBootConfirmer_DoesNotWarnWhenTheGatePasses(t *testing.T) {
	pendingUpgrade(t)
	rec := &errRecorder{}

	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	c := &BootConfirmer{
		Prober:        &scriptedProber{results: []bool{true}},
		PollInterval:  time.Millisecond,
		GateWarnAfter: 50 * time.Millisecond,
		Runner:        mount.ExecRunner{},
		OnError:       rec.record,
	}
	if err := c.Run(ctx); err != nil {
		t.Fatalf("Run: %v", err)
	}

	if n := rec.count("boot_confirm_gate"); n != 0 {
		t.Errorf("warned about a gate that passed (%d times)", n)
	}
}

// A hub must not be demoted to the local gate, and cannot be TOLD not to be:
// nothing sets Config.AppHealthURL, and the SiteSetting that feeds the
// breadcrumb is fleet-global, so protecting a hub through it would re-break
// every other node. The node therefore decides from its own composed set — and
// on a self-hosted control plane, booting from a permanently frozen LKG, that
// is the only signal that can still reach it.
func TestBootConfirmer_WebTierInComposedSetSelectsTheHTTPGate(t *testing.T) {
	path := filepath.Join(t.TempDir(), "boot-composed.json")
	if err := os.WriteFile(path, []byte(
		`{"modules":[{"id":"m1","name":"reverse-proxy-traefik"},{"id":"m2","name":"runtime-ruby"},{"id":"m3","name":"powernode-hub-backend"}]}`,
	), 0o644); err != nil {
		t.Fatal(err)
	}
	c := &BootConfirmer{BreadcrumbPath: path} // no URL configured anywhere

	gate := c.resolveGate()
	if _, ok := gate.prober.(*HTTPHealthProber); !ok {
		t.Fatalf("gate prober = %T, want *HTTPHealthProber — a node composing the platform web tier "+
			"can answer /up, and is the node where a broken stack is least recoverable", gate.prober)
	}
}

// The negative control. Every other node in the fleet composes modules too, and
// must still get the local gate — otherwise this reintroduces the original bug
// through a new door.
func TestBootConfirmer_NonWebTierComposedSetKeepsTheLocalGate(t *testing.T) {
	path := filepath.Join(t.TempDir(), "boot-composed.json")
	if err := os.WriteFile(path, []byte(
		`{"modules":[{"id":"m1","name":"runtime-ruby"},{"id":"m2","name":"claude-tmux"}]}`,
	), 0o644); err != nil {
		t.Fatal(err)
	}
	c := &BootConfirmer{BreadcrumbPath: path}

	if _, ok := c.resolveGate().prober.(*systemdReadyProber); !ok {
		t.Fatalf("prober = %T, want *systemdReadyProber for a node with no web tier", c.resolveGate().prober)
	}
}

// The conjunct systemd cannot supply. A UKI that breaks module composition
// reports a clean `running` with nothing failed — the units were never installed
// to fail — which is exactly the /sbin-shadowing and module-overlay regression
// class A/B rollback exists for. Without this, the gate blesses them.
func TestSystemdReadyProber_UnreconciledNodeIsNotHealthy(t *testing.T) {
	p := &systemdReadyProber{
		run:         stubSystemctl("running\n", nil), // systemd is perfectly happy
		reconcileOK: func() bool { return false },    // composition is not
	}

	healthy, err := p.Healthy(context.Background())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if healthy {
		t.Fatal("blessed an image whose module reconcile never succeeded — systemd reports `running` " +
			"precisely BECAUSE the units were never installed, so it cannot see this failure")
	}
}

// And the conjunct must not veto a node that reconciled fine.
func TestSystemdReadyProber_ReconciledDegradedNodeStillPasses(t *testing.T) {
	p := &systemdReadyProber{
		run:         stubSystemctl("degraded\n", &exec.ExitError{}),
		reconcileOK: func() bool { return true },
	}

	healthy, err := p.Healthy(context.Background())
	if err != nil || !healthy {
		t.Fatalf("healthy=%v err=%v — a reconciled node with one unhappy unit must still bless", healthy, err)
	}
}

// The conjunct must gate on COMPOSITION, not on a successful reconcile pass.
// Reconciler.lastError is only set by fetching modules and reading/writing
// state — three of which need the platform — so gating on it would both miss
// every attach/union failure AND make a node with a dead platform link unable
// to bless a good image for a whole boot.
func TestReconciler_ComposedOKTracksCompositionNotReachability(t *testing.T) {
	r := &Reconciler{}

	// Nothing observed yet: absence of evidence passes, which is exactly the
	// pre-conjunct behaviour for a node whose reconcile never got that far.
	if !r.ComposedOK() {
		t.Fatal("a node with no observed composition failure must pass — otherwise a node that " +
			"cannot reach the platform can never bless, which is the bug this change exists to fix")
	}

	// An observed union-mount / attach failure must block the bless.
	r.composeFailed.Store(true)
	if r.ComposedOK() {
		t.Fatal("passed despite an observed composition failure — this is the /sbin-shadow and " +
			"module-overlay class, and blessing here disarms the rollback that would recover it")
	}
}

// Exercises the WIRING, not the accessor. The first cut of this change set the
// field at only one of the three failure sites — the other two edits silently
// failed to apply — and the accessor-only test above passed anyway, because it
// assigns composeFailed directly. Assert the real call sites exist instead.
func TestReconciler_AllCompositionFailureSitesMarkComposeFailed(t *testing.T) {
	src, err := os.ReadFile("reconcile.go")
	if err != nil {
		t.Fatal(err)
	}
	body := string(src)
	// Each failure path that means "this image did not compose" must set the
	// flag. Named individually so a future edit that drops one fails HERE.
	for _, site := range []string{"reconciler:missing_manifest", "reconciler:attach", "reconciler:union_mount"} {
		i := strings.Index(body, site)
		if i < 0 {
			t.Fatalf("failure site %q no longer exists — did it move? the gate depends on it", site)
		}
		// Window ends at the NEXT error site, so a block cannot pass on its
		// neighbour's marker. A fixed-width window did exactly that here and let
		// a genuinely unmarked site survive mutation.
		rest := body[i+len(site):]
		end := len(rest)
		if n := strings.Index(rest, "r.cfg.OnError("); n >= 0 {
			end = n
		}
		if !strings.Contains(rest[:end], "r.composeFailed.Store(true)") {
			t.Errorf("%s does not mark composeFailed — an image that fails there still BLESSES, "+
				"and the gate silently proves less than its comments claim", site)
		}
	}
	// And the flag must be reset when a pass reaches the compose stage, or one
	// transient failure latches for the rest of the boot and nothing re-blesses.
	if !strings.Contains(body, "r.composeFailed.Store(false)") {
		t.Error("composeFailed is never reset — a single transient failure would block every " +
			"subsequent bless for the remainder of the boot")
	}
}

// The regression critic A blocked the ship on. powernode-hub-worker composes
// hub-backend but NO reverse proxy — its seed description says "No
// reverse-proxy (no public TLS endpoint on workers)" — so nothing listens on
// :443. Keying detection on the module that SERVES /up while the probe needs
// the module that TERMINATES the port handed every worker-pool node a gate it
// could never answer. Those nodes bless fine today on the local gate, so this
// would have been a regression introduced by the fix.
func TestBootConfirmer_WorkerPoolIsNotMistakenForAWebTier(t *testing.T) {
	for _, c := range []struct {
		name     string
		modules  string
		wantHTTP bool
	}{
		{"hub-worker: backend, no proxy", `{"name":"runtime-ruby"},{"name":"powernode-hub-backend"},{"name":"powernode-hub-worker"}`, false},
		{"hub-frontend: proxy, no backend", `{"name":"reverse-proxy-traefik"},{"name":"powernode-hub-frontend"}`, false},
		{"hub-api: both", `{"name":"reverse-proxy-traefik"},{"name":"runtime-ruby"},{"name":"powernode-hub-backend"}`, true},
	} {
		path := filepath.Join(t.TempDir(), "boot-composed.json")
		if err := os.WriteFile(path, []byte(`{"modules":[`+c.modules+`]}`), 0o644); err != nil {
			t.Fatal(err)
		}
		gate := (&BootConfirmer{BreadcrumbPath: path}).resolveGate()
		_, isHTTP := gate.prober.(*HTTPHealthProber)
		if isHTTP != c.wantHTTP {
			t.Errorf("%s: HTTP gate = %v, want %v — a node given a loopback probe it cannot answer "+
				"never blesses, and silently reverts every good image", c.name, isHTTP, c.wantHTTP)
		}
	}
}
