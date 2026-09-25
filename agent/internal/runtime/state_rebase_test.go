package runtime

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/etcidentity"
	"github.com/nodealchemy/powernode-system/agent/internal/etcsudoers"
	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/verify"
)

// OPSHUB-AGENT (offer 01a0c60b-c298) — the boot state rebase (state_rebase.go).
//
// ops-hub's state.json recorded two devpin modules as attached that the boot
// did not compose, that were not mounted, had no units and were not assigned.
// They rode into running_module_digests, the drift report called them `extra`,
// and the self-host fence refused their detach every tick, forever.
//
// Every assertion checks BOTH what must go and what must stay, so an
// implementation that drops everything, or nothing, cannot pass.

const (
	rebaseThisBoot  = "boot-this-0001"
	rebaseOtherBoot = "boot-prev-0000"
)

var rebaseComposedAt = time.Date(2026, 9, 20, 4, 0, 0, 0, time.UTC)

// rebaseModule is one module of a fixture: its assignment, what state.json
// says, and what the node actually has.
type rebaseModule struct {
	id     string
	digest string // the digest state.json records
	// assigned: returned by the platform's assigned-modules list this tick.
	assigned bool
	// inState: recorded in state.json's AttachedModules.
	inState bool
	// composed: listed in this boot's breadcrumb at bcDigest (default digest).
	// A composed module's bcDigest is mounted AND a lower of / — the
	// cross-check's known answer — unless bcNotMounted / bcNotInUnion break it.
	composed                   bool
	bcDigest                   string
	bcNotMounted, bcNotInUnion bool
	// Liveness evidence for the STATE digest.
	mounted bool // a mount at ModuleMountPath(digest)
	inUnion bool // ModuleMountPath(digest) is a lower of /
	units   bool // systemd lists a loaded powernode-<id>-* unit
	// unitFile writes a unit file in the unit dir (fence pins only).
	unitFile bool
	// Manifest content.
	services bool
	users    []manifest.ManifestUser
	egress   []string // declares security.egress_allow when non-nil
	// noCache leaves no cached manifest on disk for the module.
	noCache bool
}

func (m rebaseModule) boot() string {
	if m.bcDigest != "" {
		return m.bcDigest
	}
	return m.digest
}

func (m rebaseModule) manifest() *manifest.Manifest {
	mf := &manifest.Manifest{ID: m.id, Name: m.id, Digest: m.digest, Users: m.users}
	if m.services {
		mf.Services = []manifest.Service{{Name: "svc", StartCommand: "/bin/true", RestartPolicy: "always"}}
	}
	if m.egress != nil {
		allow := make([]any, 0, len(m.egress))
		for _, e := range m.egress {
			allow = append(allow, e)
		}
		mf.Config = map[string]any{"security": map[string]any{"egress_allow": allow}}
	}
	return mf
}

type rebaseOpts struct {
	selfHosted bool
	enforce    bool // the enable sentinel exists
	killFile   bool // the disable sentinel exists
	killCmd    bool // powernode.state_rebase=off on the kernel cmdline
	dryRun     bool
	// breadcrumb: "this" (default when composed modules exist), "other",
	// "corrupt", "incomplete", "no-boot-id", "none".
	breadcrumb string
	composedAt time.Time
	// kernelBootUnknown makes the kernel boot id unavailable.
	kernelBootUnknown bool
	// Mount table shape.
	mountInfoUnreadable bool
	mountInfoGarbage    bool
	lowerdirPlus        bool
	rootWithoutLowers   bool
	// unitQueryFails makes systemctl list-units fail for this module id.
	unitQueryFails string
	// findmntFails makes findmnt error for every module mount point.
	findmntFails bool
	// Root mode.
	chroot       bool
	rootProbeErr bool
	// State seeding.
	stateRebasedAgainst string
	unmaterialized      []string
	unitDirUnreadable   bool
}

type rebaseHarness struct {
	r          *Reconciler
	statePath  string
	layout     mount.Layout
	runner     *mount.RecorderRunner
	signals    *[]string
	breadcrumb string
}

func unitsQueryKey(id string) string {
	return "systemctl list-units --all --plain --no-legend --no-pager powernode-" + id + "-*"
}

func newRebaseHarness(t *testing.T, mods []rebaseModule, o rebaseOpts) *rebaseHarness {
	t.Helper()
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json")
	manifestRoot := filepath.Join(tmpRoot, "manifests")
	layout := mount.DefaultLayout()
	layout.Root = tmpRoot
	layout = layout.Resolve()

	// Root mode: both indirections, so neither the host's real "/" nor a CI
	// runner's decides the answer.
	origMode, origChecked := pivotAwareRootMode, pivotAwareRootModeChecked
	switch {
	case o.rootProbeErr:
		pivotAwareRootMode = func() lifecycle.RootMode { return lifecycle.RootModeChroot }
		pivotAwareRootModeChecked = func() (lifecycle.RootMode, error) {
			return lifecycle.RootModeChroot, errors.New("statfs /: input/output error")
		}
	case o.chroot:
		pivotAwareRootMode = func() lifecycle.RootMode { return lifecycle.RootModeChroot }
		pivotAwareRootModeChecked = func() (lifecycle.RootMode, error) { return lifecycle.RootModeChroot, nil }
	default:
		pivotAwareRootMode = func() lifecycle.RootMode { return lifecycle.RootModeNative }
		pivotAwareRootModeChecked = func() (lifecycle.RootMode, error) { return lifecycle.RootModeNative, nil }
	}
	origBoot := currentBootID
	currentBootID = func() string {
		if o.kernelBootUnknown {
			return ""
		}
		return rebaseThisBoot
	}
	origIdentity, origSudoers := applyIdentity, applySudoers
	applyIdentity = func(*etcidentity.Set) error { return nil }
	applySudoers = func([]etcsudoers.Grant) error { return nil }

	// Switches.
	origEnable, origDisable, origCmdline := StateRebaseEnableSentinel, StateRebaseDisableSentinel, procCmdlinePath
	StateRebaseEnableSentinel = filepath.Join(tmpRoot, "state-rebase.enabled")
	StateRebaseDisableSentinel = filepath.Join(tmpRoot, "state-rebase.disabled")
	procCmdlinePath = filepath.Join(tmpRoot, "cmdline")
	cmdline := "ro quiet\n"
	if o.killCmd {
		cmdline = "ro quiet powernode.state_rebase=off\n"
	}
	writeRebaseFixture(t, procCmdlinePath, cmdline)
	if o.enforce {
		writeRebaseFixture(t, StateRebaseEnableSentinel, "")
	}
	if o.killFile {
		writeRebaseFixture(t, StateRebaseDisableSentinel, "")
	}
	t.Cleanup(func() {
		pivotAwareRootMode, pivotAwareRootModeChecked = origMode, origChecked
		currentBootID = origBoot
		applyIdentity, applySudoers = origIdentity, origSudoers
		StateRebaseEnableSentinel, StateRebaseDisableSentinel, procCmdlinePath = origEnable, origDisable, origCmdline
	})

	unitDir := filepath.Join(tmpRoot, "units")
	if err := os.MkdirAll(unitDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if o.unitDirUnreadable {
		unitDir = filepath.Join(tmpRoot, "units-is-a-file")
		writeRebaseFixture(t, unitDir, "x")
	}
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", unitDir)
	t.Cleanup(SetPendingComposePathForTest(filepath.Join(tmpRoot, "pending-compose.json")))
	breadcrumbPath := filepath.Join(tmpRoot, "boot-composed.json")
	t.Cleanup(SetBootBreadcrumbPathForTest(breadcrumbPath))

	// state.json
	st := &mount.State{LastAttachedManifestHashes: map[string]string{},
		UnmaterializedModules: o.unmaterialized, RebasedAgainst: o.stateRebasedAgainst}
	for _, m := range mods {
		if m.inState {
			st.AttachedModules = append(st.AttachedModules, mount.Module{ID: m.id, Digest: m.digest, Priority: 100})
			st.LastAttachedManifestHashes[m.id] = "stamp-" + m.id
		}
	}
	if err := mount.SaveState(statePath, st); err != nil {
		t.Fatalf("SaveState: %v", err)
	}

	for _, m := range mods {
		if !m.noCache {
			writeManifestFixture(t, manifestRoot, m.manifest())
		}
		if m.unitFile && !o.unitDirUnreadable {
			writeRebaseFixture(t, filepath.Join(unitDir, lifecycle.UnitName(m.id, "svc")), "[Service]\nExecStart=/bin/true\n")
		}
	}

	// Mount table.
	mounted := map[string]bool{}
	var lowers []string
	addLower := func(d string) {
		p := layout.ModuleMountPath(d)
		for _, l := range lowers {
			if l == p {
				return
			}
		}
		lowers = append(lowers, p)
	}
	for _, m := range mods {
		if m.mounted {
			mounted[m.digest] = true
		}
		if m.inUnion {
			addLower(m.digest)
		}
		if m.composed {
			if !m.bcNotMounted {
				mounted[m.boot()] = true
			}
			if !m.bcNotInUnion {
				addLower(m.boot())
			}
		}
	}
	var lines []string
	digests := make([]string, 0, len(mounted))
	for d := range mounted {
		digests = append(digests, d)
	}
	sort.Strings(digests)
	for i, d := range digests {
		id := 40 + i
		lines = append(lines, fmt.Sprintf("%d 27 7:%d / %s ro,relatime shared:%d - erofs /dev/loop%d ro",
			id, id, layout.ModuleMountPath(d), id, id))
	}
	lowerOpt := "lowerdir=" + strings.Join(lowers, ":")
	if o.lowerdirPlus {
		parts := make([]string, 0, len(lowers))
		for _, l := range lowers {
			parts = append(parts, "lowerdir+="+l)
		}
		lowerOpt = strings.Join(parts, ",")
	}
	if o.rootWithoutLowers {
		lowerOpt = "xino=off"
	}
	lines = append(lines, fmt.Sprintf("27 1 0:24 / %s rw,relatime shared:1 - overlay overlay rw,%s,upperdir=%s,workdir=%s",
		filepath.Join(layout.Root, "/"), lowerOpt, filepath.Join(tmpRoot, "scratch/upper"), filepath.Join(tmpRoot, "scratch/work")))
	if o.mountInfoGarbage {
		lines = append(lines, "this line has no separator")
	}
	mi := filepath.Join(tmpRoot, "mountinfo")
	writeRebaseFixture(t, mi, strings.Join(lines, "\n")+"\n")
	if o.mountInfoUnreadable {
		mi = filepath.Join(tmpRoot, "no-such-mountinfo")
	}
	t.Cleanup(mount.SetMountInfoPathForTest(mi))

	// Breadcrumb.
	kind := o.breadcrumb
	if kind == "" {
		kind = "this"
	}
	at := o.composedAt
	if at.IsZero() {
		at = rebaseComposedAt
	}
	switch kind {
	case "this", "other", "incomplete", "no-boot-id":
		bc := &BootComposedBreadcrumb{BootID: rebaseThisBoot, ComposedAt: at}
		switch kind {
		case "other":
			bc.BootID = rebaseOtherBoot
		case "incomplete":
			bc.Incomplete = true
		case "no-boot-id":
			bc.BootID = ""
		}
		for _, m := range mods {
			if m.composed {
				raw, _ := json.Marshal(m.manifest())
				bc.Modules = append(bc.Modules, LKGModule{ID: m.id, Digest: m.boot(), HasDataFile: true, EffectivePriority: 100, Manifest: raw})
			}
		}
		if err := WriteBreadcrumb(breadcrumbPath, bc); err != nil {
			t.Fatalf("WriteBreadcrumb: %v", err)
		}
	case "corrupt":
		writeRebaseFixture(t, breadcrumbPath, "{not json")
	case "none":
	default:
		t.Fatalf("unknown breadcrumb kind %q", kind)
	}

	// Platform: the assigned list plus one full manifest per assigned module.
	responses := map[string]string{}
	var listed []string
	for _, m := range mods {
		if !m.assigned {
			continue
		}
		listed = append(listed, fmt.Sprintf(`{"id":%q, "name":%q, "priority":100, "effective_priority":100, "has_data_file":true}`, m.id, m.id))
		body, _ := json.Marshal(m.manifest())
		responses["/api/v1/system/node_api/modules/"+m.id] = `{"success": true, "data": ` + string(body) + `}`
	}
	responses["/api/v1/system/node_api/modules"] = `{"success": true, "data": {"modules": [` + strings.Join(listed, ",") + `]}}`
	client := &stubModulesClient{responses: responses}

	runner := &mount.RecorderRunner{StubOutput: map[string][]byte{}, StubErr: map[string]error{}}
	for _, m := range mods {
		if m.units {
			runner.StubOutput[unitsQueryKey(m.id)] = []byte("powernode-" + m.id + "-svc.service loaded active running svc\n")
		}
		if o.findmntFails {
			runner.StubErr["findmnt --noheadings "+layout.ModuleMountPath(m.digest)] = errors.New("findmnt: exit status 1")
		}
	}
	if o.unitQueryFails != "" {
		runner.StubErr[unitsQueryKey(o.unitQueryFails)] = errors.New("Failed to connect to bus")
	}

	var signals []string
	r, err := NewReconciler(ReconcilerConfig{
		ModulesClient:  client,
		ManifestClient: client,
		ManifestRoot:   manifestRoot,
		Puller:         &stubPuller{cacheDir: layout.ModulesCacheRoot},
		Verifier:       verify.AlwaysOK{},
		MountRunner:    runner,
		Layout:         layout,
		StatePath:      statePath,
		DryRun:         o.dryRun,
		OnError:        func(stage string, err error) { signals = append(signals, stage+": "+err.Error()) },
	})
	if err != nil {
		t.Fatalf("NewReconciler: %v", err)
	}
	if o.selfHosted {
		r.selfHostLatched = true
	}
	return &rebaseHarness{r: r, statePath: statePath, layout: layout, runner: runner, signals: &signals, breadcrumb: breadcrumbPath}
}

func writeRebaseFixture(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func writeManifestFixture(t *testing.T, root string, m *manifest.Manifest) {
	t.Helper()
	dir := filepath.Join(root, m.ID)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	b, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	writeRebaseFixture(t, filepath.Join(dir, "manifest.json"), string(b))
}

func (h *rebaseHarness) run(t *testing.T) *mount.State {
	t.Helper()
	if err := h.r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}
	return h.state(t)
}

func (h *rebaseHarness) state(t *testing.T) *mount.State {
	t.Helper()
	st, err := mount.LoadState(h.statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	return st
}

func (h *rebaseHarness) key(t *testing.T) string {
	t.Helper()
	bc, err := LoadBreadcrumb(h.breadcrumb)
	if err != nil {
		t.Fatalf("LoadBreadcrumb: %v", err)
	}
	return stateRebaseKey(bc)
}

func attachedIDs(st *mount.State) []string {
	out := make([]string, 0, len(st.AttachedModules))
	for _, m := range st.AttachedModules {
		out = append(out, m.ID+"@"+m.Digest)
	}
	sort.Strings(out)
	return out
}

func (h *rebaseHarness) signalsFor(stage string) []string {
	var out []string
	for _, s := range *h.signals {
		if strings.HasPrefix(s, stage+":") {
			out = append(out, s)
		}
	}
	return out
}

// anyRebaseSignal reports every signal the rebase itself can emit.
func (h *rebaseHarness) anyRebaseSignal() []string {
	var out []string
	for _, st := range []string{stageStateRebased, stageStateWouldRebase, stageStateRebaseSkipped, stageDigestDiverges} {
		out = append(out, h.signalsFor(st)...)
	}
	return out
}

// touchedNode reports whether the recorder saw any command that ACTS on the
// module — anything naming its digest or unit prefix other than the read-only
// systemd unit query the rebase itself issues.
func touchedNode(run *mount.RecorderRunner, id, digest string) bool {
	for _, inv := range run.Invocations {
		if inv.Op == "Output" && inv.Name == "systemctl" && len(inv.Args) > 0 && inv.Args[0] == "list-units" {
			continue
		}
		all := inv.Name + " " + strings.Join(inv.Args, " ")
		if strings.Contains(all, strings.TrimPrefix(digest, "sha256:")) || strings.Contains(all, "powernode-"+id+"-") {
			return true
		}
	}
	return false
}

func hasEntry(st *mount.State, id string) bool {
	for _, m := range st.AttachedModules {
		if m.ID == id {
			return true
		}
	}
	return false
}

// opsHubFixture is ops-hub as verified 2026-09-21, shrunk: three composed,
// assigned, mounted modules in the live union; one superseded live-refresh
// version still mounted but not in state; two devpins recorded in state and
// nothing else — not assigned, not composed, not mounted, no units, whose
// cached manifests DO declare services (they are postgres/ruby runtimes).
func opsHubFixture() []rebaseModule {
	composed := func(id, d string) rebaseModule {
		return rebaseModule{id: id, digest: d, assigned: true, inState: true, composed: true, units: true, services: true}
	}
	return []rebaseModule{
		composed("m-rails", "sha256:aaa1"),
		composed("m-traefik", "sha256:aaa2"),
		composed("m-postgres", "sha256:aaa3"),
		{id: "m-rails-prev", digest: "sha256:aaa0", mounted: true},
		{id: "devpin-postgres", digest: "sha256:dead1", inState: true, services: true},
		{id: "devpin-ruby", digest: "sha256:dead2", inState: true, services: true},
	}
}

var opsHubComposed = []string{"m-postgres@sha256:aaa3", "m-rails@sha256:aaa1", "m-traefik@sha256:aaa2"}

// The ops-hub reproduction, rebase ENABLED: the devpins go, the composed
// modules stay, and dropping them is pure bookkeeping — no detach proposed, no
// fence refusal, no command against the node.
func TestStateRebase_OpsHubDevpinsDroppedWhenEnabled(t *testing.T) {
	h := newRebaseHarness(t, opsHubFixture(), rebaseOpts{selfHosted: true, enforce: true,
		unmaterialized: []string{"devpin-ruby", "m-rails"}})
	before, err := os.ReadFile(h.statePath)
	if err != nil {
		t.Fatal(err)
	}
	st := h.run(t)

	if got := attachedIDs(st); strings.Join(got, ",") != strings.Join(opsHubComposed, ",") {
		t.Errorf("attached = %v, want exactly the composed modules %v", got, opsHubComposed)
	}
	for _, id := range []string{"devpin-postgres", "devpin-ruby"} {
		if _, ok := st.LastAttachedManifestHashes[id]; ok {
			t.Errorf("LastAttachedManifestHashes still carries dropped %s", id)
		}
		if containsID(st.UnmaterializedModules, id) {
			t.Errorf("UnmaterializedModules still carries dropped %s", id)
		}
	}
	for _, id := range []string{"m-rails", "m-traefik", "m-postgres"} {
		if _, ok := st.LastAttachedManifestHashes[id]; !ok {
			t.Errorf("LastAttachedManifestHashes lost kept module %s", id)
		}
	}
	if refused := h.signalsFor("reconciler:self_host_detach_refused"); len(refused) != 0 {
		t.Errorf("self-host fence still refusing dead bookkeeping: %v", refused)
	}
	if det := h.signalsFor("reconciler:detach"); len(det) != 0 {
		t.Errorf("a detach was attempted: %v", det)
	}
	rebased := h.signalsFor(stageStateRebased)
	if len(rebased) != 1 || !strings.Contains(rebased[0], "devpin-postgres") || !strings.Contains(rebased[0], "devpin-ruby") ||
		strings.Contains(rebased[0], "m-rails@") {
		t.Errorf("want one %s signal naming both devpins and no composed module, got %v", stageStateRebased, rebased)
	}
	for _, m := range []struct{ id, d string }{{"devpin-postgres", "sha256:dead1"}, {"devpin-ruby", "sha256:dead2"}} {
		if touchedNode(h.runner, m.id, m.d) {
			t.Errorf("dropping dead %s ran a command against the node", m.id)
		}
	}
	if st.RebasedAgainst != h.key(t) {
		t.Errorf("RebasedAgainst = %q, want the breadcrumb key %q", st.RebasedAgainst, h.key(t))
	}
	backup, err := os.ReadFile(h.statePath + ".pre-rebase-" + h.key(t))
	if err != nil {
		t.Fatalf("no pre-rebase backup: %v", err)
	}
	if string(backup) != string(before) {
		t.Errorf("pre-rebase backup is not the state.json the rebase started from")
	}
}

// The DEFAULT is report-only: the same fixture changes nothing, says what it
// would drop, and leaves the fence behaving exactly as today.
func TestStateRebase_ReportOnlyByDefault(t *testing.T) {
	h := newRebaseHarness(t, opsHubFixture(), rebaseOpts{selfHosted: true})
	before, _ := os.ReadFile(h.statePath)
	st := h.run(t)

	if !hasEntry(st, "devpin-postgres") || !hasEntry(st, "devpin-ruby") {
		t.Errorf("report-only mode dropped entries: %v", attachedIDs(st))
	}
	if st.RebasedAgainst != "" {
		t.Errorf("report-only mode stamped RebasedAgainst = %q", st.RebasedAgainst)
	}
	if _, err := os.Stat(h.statePath + ".pre-rebase-" + h.key(t)); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("report-only mode wrote a pre-rebase backup (stat err %v)", err)
	}
	would := h.signalsFor(stageStateWouldRebase)
	if len(would) != 1 || !strings.Contains(would[0], "devpin-postgres") || !strings.Contains(would[0], "devpin-ruby") ||
		!strings.Contains(would[0], "REPORT-ONLY") {
		t.Errorf("want one REPORT-ONLY %s naming both devpins, got %v", stageStateWouldRebase, would)
	}
	if s := h.signalsFor(stageStateRebased); len(s) != 0 {
		t.Errorf("report-only mode claimed a rebase: %v", s)
	}
	if refused := h.signalsFor("reconciler:self_host_detach_refused"); len(refused) != 1 {
		t.Errorf("report-only must leave the fence as today (one refusal), got %v", refused)
	}
	_ = before

	// Once per process: a second report-only tick does not repeat itself.
	h.run(t)
	if n := len(h.signalsFor(stageStateWouldRebase)); n != 1 {
		t.Errorf("report-only signal repeated on the second tick: %d", n)
	}
}

// The kill switch — sentinel or cmdline — beats the enable sentinel and turns
// the rebase off entirely: no report, no change.
func TestStateRebase_KillSwitchOverridesEnable(t *testing.T) {
	for _, tc := range []struct {
		name string
		o    rebaseOpts
	}{
		{"disable sentinel", rebaseOpts{selfHosted: true, enforce: true, killFile: true}},
		{"kernel cmdline", rebaseOpts{selfHosted: true, enforce: true, killCmd: true}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := newRebaseHarness(t, opsHubFixture(), tc.o)
			st := h.run(t)
			if !hasEntry(st, "devpin-postgres") || st.RebasedAgainst != "" {
				t.Errorf("kill switch ignored: attached %v, stamp %q", attachedIDs(st), st.RebasedAgainst)
			}
			if s := h.anyRebaseSignal(); len(s) != 0 {
				t.Errorf("kill switch still emitted rebase signals: %v", s)
			}
		})
	}
}

// Each keep condition, both arms: with its evidence the candidate survives;
// with the same fixture minus that one piece of evidence it is dropped. A
// sibling dead entry is dropped in both arms, proving the rebase ran.
func TestStateRebase_EachKeepConditionBothArms(t *testing.T) {
	cases := []struct {
		name string
		with func(*rebaseModule)
	}{
		{"digest mounted", func(m *rebaseModule) { m.mounted = true }},
		{"digest is a lower of /", func(m *rebaseModule) { m.inUnion = true }},
		{"systemd has a loaded unit", func(m *rebaseModule) { m.units = true }},
		{"ID composed at another digest", func(m *rebaseModule) { m.composed, m.bcDigest = true, "sha256:c0ffee" }},
	}
	for _, tc := range cases {
		for _, withEvidence := range []bool{true, false} {
			t.Run(fmt.Sprintf("%s/evidence=%t", tc.name, withEvidence), func(t *testing.T) {
				cand := rebaseModule{id: "cand", digest: "sha256:cafe", inState: true, services: true}
				if withEvidence {
					tc.with(&cand)
				}
				mods := []rebaseModule{
					{id: "m-base", digest: "sha256:ba5e", assigned: true, inState: true, composed: true},
					cand,
					{id: "dead-one", digest: "sha256:dead3", inState: true, services: true},
				}
				h := newRebaseHarness(t, mods, rebaseOpts{selfHosted: true, enforce: true})
				st := h.run(t)
				if hasEntry(st, "cand") != withEvidence {
					t.Errorf("cand kept=%t, want %t (attached %v, signals %v)", hasEntry(st, "cand"), withEvidence, attachedIDs(st), *h.signals)
				}
				if !hasEntry(st, "m-base") {
					t.Errorf("composed module dropped: %v", attachedIDs(st))
				}
				if hasEntry(st, "dead-one") {
					t.Errorf("dead sibling kept — the rebase did not run: %v", *h.signals)
				}
			})
		}
	}
}

// A self-hosted node keeps refusing to detach a module that is still live:
// the rebase keeps it, so the fence sees it exactly as before.
func TestStateRebase_LiveModuleStillFencedOnSelfHosted(t *testing.T) {
	mods := []rebaseModule{
		{id: "m-base", digest: "sha256:ba5e", assigned: true, inState: true, composed: true},
		{id: "live-svc", digest: "sha256:1ive", inState: true, services: true, units: true},
		{id: "dead-one", digest: "sha256:dead3", inState: true, services: true},
	}
	h := newRebaseHarness(t, mods, rebaseOpts{selfHosted: true, enforce: true})
	st := h.run(t)
	if !hasEntry(st, "live-svc") || hasEntry(st, "dead-one") {
		t.Fatalf("want live-svc kept and dead-one dropped: %v", attachedIDs(st))
	}
	refused := h.signalsFor("reconciler:self_host_detach_refused")
	if len(refused) != 1 || !strings.Contains(refused[0], "live-svc") || strings.Contains(refused[0], "dead-one") {
		t.Errorf("want the fence to refuse exactly the live module, got %v", refused)
	}
}

// Out of scope by design: an ID the boot composed at another digest is KEPT
// and reported, never dropped (dropping it would turn into a first-attach with
// no outgoing prune).
func TestStateRebase_StaleDigestKeptAndReported(t *testing.T) {
	mods := []rebaseModule{
		{id: "m1", digest: "sha256:x", assigned: true, inState: true, composed: true, bcDigest: "sha256:y"},
		{id: "dead-one", digest: "sha256:dead3", inState: true, services: true},
	}
	h := newRebaseHarness(t, mods, rebaseOpts{selfHosted: true, enforce: true})
	st := h.run(t)
	if !containsID(attachedIDs(st), "m1@sha256:x") {
		t.Errorf("stale-digest entry changed: %v", attachedIDs(st))
	}
	div := h.signalsFor(stageDigestDiverges)
	if len(div) != 1 || !strings.Contains(div[0], "m1 (state sha256:x, boot sha256:y)") {
		t.Errorf("want one %s naming m1, got %v", stageDigestDiverges, div)
	}
	rebased := h.signalsFor(stageStateRebased)
	if len(rebased) != 1 || strings.Contains(rebased[0], "m1@") || !strings.Contains(rebased[0], "dead-one") {
		t.Errorf("want the rebase to drop dead-one and never name m1, got %v", rebased)
	}
}

// A desired module the agent itself re-mounts every tick (ensure-mounted),
// absent from the breadcrumb, is KEPT: mounted is live, the safe direction.
func TestStateRebase_EnsureMountedDesiredModuleKept(t *testing.T) {
	mods := []rebaseModule{
		{id: "m-base", digest: "sha256:ba5e", assigned: true, inState: true, composed: true},
		{id: "m-desired", digest: "sha256:de5d", assigned: true, inState: true, mounted: true},
		{id: "dead-one", digest: "sha256:dead3", inState: true, services: true},
	}
	h := newRebaseHarness(t, mods, rebaseOpts{selfHosted: true, enforce: true})
	st := h.run(t)
	// m-desired is assigned, so a drop would be re-attached by the same pass;
	// the rebase's own signal is the oracle for "kept".
	rebased := h.signalsFor(stageStateRebased)
	if len(rebased) != 1 || strings.Contains(rebased[0], "m-desired") || !strings.Contains(rebased[0], "dead-one") {
		t.Errorf("want the rebase to drop dead-one and never name m-desired, got %v", rebased)
	}
	if !hasEntry(st, "m-desired") || hasEntry(st, "dead-one") {
		t.Errorf("want m-desired kept and dead-one dropped: %v", attachedIDs(st))
	}
}

// An agent upgraded mid-boot meets a legacy, never-stamped state holding a
// module hot-applied during this boot: not in the breadcrumb, but mounted with
// a running unit. It is kept; only the dead entry goes.
func TestStateRebase_LegacyMidBootHotAppliedKept(t *testing.T) {
	mods := []rebaseModule{
		{id: "m-base", digest: "sha256:ba5e", assigned: true, inState: true, composed: true},
		{id: "m-hot", digest: "sha256:407", assigned: true, inState: true, mounted: true, units: true, services: true},
		{id: "dead-one", digest: "sha256:dead3", inState: true, services: true},
	}
	h := newRebaseHarness(t, mods, rebaseOpts{selfHosted: true, enforce: true, stateRebasedAgainst: ""})
	st := h.run(t)
	rebased := h.signalsFor(stageStateRebased)
	if len(rebased) != 1 || strings.Contains(rebased[0], "m-hot") || !strings.Contains(rebased[0], "dead-one") {
		t.Errorf("want the rebase to drop dead-one and never name m-hot, got %v", rebased)
	}
	if !hasEntry(st, "m-hot") || hasEntry(st, "dead-one") {
		t.Errorf("want m-hot kept and dead-one dropped: %v", attachedIDs(st))
	}
}

// Fail closed: whenever a precondition or a probe cannot answer, the rebase
// changes nothing, writes no backup, does not stamp (so it retries), and —
// except on a chroot node, where it simply does not apply — says why. The
// reason is asserted, not just the skip: several guards overlap (an empty
// union also fails the cross-check), and a skip for the WRONG reason would
// hide a removed guard.
func TestStateRebase_FailsClosed(t *testing.T) {
	fx := func(mut func([]rebaseModule) []rebaseModule) []rebaseModule {
		m := opsHubFixture()
		if mut != nil {
			m = mut(m)
		}
		return m
	}
	cases := []struct {
		name string
		mods []rebaseModule
		o    rebaseOpts
		// why is the reason the skip signal must give; "" = silent.
		why string
	}{
		{"no breadcrumb", fx(nil), rebaseOpts{breadcrumb: "none"}, "no usable boot breadcrumb"},
		{"corrupt breadcrumb", fx(nil), rebaseOpts{breadcrumb: "corrupt"}, "no usable boot breadcrumb"},
		{"breadcrumb from another boot", fx(nil), rebaseOpts{breadcrumb: "other"}, "is from boot " + rebaseOtherBoot},
		{"incomplete breadcrumb", fx(nil), rebaseOpts{breadcrumb: "incomplete"}, "marked incomplete"},
		{"breadcrumb without a boot id", fx(nil), rebaseOpts{breadcrumb: "no-boot-id"}, "carries no boot id"},
		{"kernel boot id unavailable", fx(nil), rebaseOpts{kernelBootUnknown: true}, "kernel boot id is unavailable"},
		{"mount table unreadable", fx(nil), rebaseOpts{mountInfoUnreadable: true}, "cannot read the mount table strictly"},
		{"mount table has an unparseable line", fx(nil), rebaseOpts{mountInfoGarbage: true}, "cannot read the mount table strictly"},
		{"root union lists no lowers", fx(nil), rebaseOpts{rootWithoutLowers: true}, "lists no lower layers"},
		{"cross-check: a composed module is not mounted", fx(func(m []rebaseModule) []rebaseModule {
			m[1].bcNotMounted = true
			return m
		}), rebaseOpts{}, "disagrees with the boot breadcrumb for m-traefik"},
		{"cross-check: a composed module is not a lower of /", fx(func(m []rebaseModule) []rebaseModule {
			m[1].bcNotInUnion = true
			return m
		}), rebaseOpts{}, "disagrees with the boot breadcrumb for m-traefik"},
		{"systemd unit query fails", fx(nil), rebaseOpts{unitQueryFails: "devpin-ruby"}, "cannot list systemd units for devpin-ruby"},
		{"dead module's manifest unresolved", fx(func(m []rebaseModule) []rebaseModule {
			m[4].noCache = true
			return m
		}), rebaseOpts{}, "render impact of dropping"},
		{"root-mode probe fails", fx(nil), rebaseOpts{rootProbeErr: true}, "cannot determine the root mode"},
		{"chroot node", fx(nil), rebaseOpts{chroot: true}, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			tc.o.enforce, tc.o.selfHosted = true, true
			h := newRebaseHarness(t, tc.mods, tc.o)
			st := h.run(t)
			if !hasEntry(st, "devpin-postgres") || !hasEntry(st, "devpin-ruby") {
				t.Errorf("fail-safe violated: attached %v", attachedIDs(st))
			}
			if st.RebasedAgainst != "" {
				t.Errorf("stamped %q on a pass that could not rebase", st.RebasedAgainst)
			}
			if s := h.signalsFor(stageStateRebased); len(s) != 0 {
				t.Errorf("claimed a rebase: %v", s)
			}
			matches, _ := filepath.Glob(h.statePath + ".pre-rebase-*")
			if len(matches) != 0 {
				t.Errorf("wrote a backup on a no-op pass: %v", matches)
			}
			skipped := h.signalsFor(stageStateRebaseSkipped)
			if tc.why == "" && len(skipped) != 0 {
				t.Errorf("chroot is not applicable, not a skip: %v", skipped)
			}
			if tc.why != "" && (len(skipped) != 1 || !strings.Contains(skipped[0], tc.why)) {
				t.Errorf("want exactly one %s saying %q, got %v", stageStateRebaseSkipped, tc.why, skipped)
			}
		})
	}
}

// Positive control for the fail-closed arms above: the lowerdir+= spelling of
// the live union is READ, not mistaken for an empty one — the rebase proceeds,
// and a candidate kept only by being a lower of / is still kept.
func TestStateRebase_LowerdirPlusUnionIsRead(t *testing.T) {
	mods := append(opsHubFixture(), rebaseModule{id: "union-only", digest: "sha256:0417", inState: true, inUnion: true, services: true})
	h := newRebaseHarness(t, mods, rebaseOpts{selfHosted: true, enforce: true, lowerdirPlus: true})
	st := h.run(t)
	if hasEntry(st, "devpin-postgres") || !hasEntry(st, "union-only") {
		t.Errorf("lowerdir+= union: want devpins dropped and union-only kept, got %v (signals %v)", attachedIDs(st), *h.signals)
	}
}

// findmnt failing must not read as "not mounted" — the rebase never asks it.
func TestStateRebase_FindmntErrorDoesNotReadAsUnmounted(t *testing.T) {
	mods := append(opsHubFixture(), rebaseModule{id: "mounted-only", digest: "sha256:3043", inState: true, mounted: true, services: true})
	h := newRebaseHarness(t, mods, rebaseOpts{selfHosted: true, enforce: true, findmntFails: true})
	st := h.run(t)
	if !hasEntry(st, "mounted-only") || hasEntry(st, "devpin-ruby") {
		t.Errorf("want mounted-only kept and devpins dropped despite findmnt errors: %v", attachedIDs(st))
	}
}

// A soft-reboot recomposes the root under the SAME kernel boot id; the new
// breadcrumb's compose time makes it a new key, so the rebase runs again. The
// control (same breadcrumb) is a no-op.
func TestStateRebase_SoftRebootRebasesAgain(t *testing.T) {
	stamped := stateRebaseKey(&BootComposedBreadcrumb{BootID: rebaseThisBoot, ComposedAt: rebaseComposedAt})

	h := newRebaseHarness(t, opsHubFixture(), rebaseOpts{selfHosted: true, enforce: true, stateRebasedAgainst: stamped,
		composedAt: rebaseComposedAt.Add(20 * time.Minute)})
	st := h.run(t)
	if hasEntry(st, "devpin-postgres") || st.RebasedAgainst == stamped || st.RebasedAgainst != h.key(t) {
		t.Errorf("soft-reboot: want a fresh rebase and stamp, got attached %v stamp %q", attachedIDs(st), st.RebasedAgainst)
	}

	c := newRebaseHarness(t, opsHubFixture(), rebaseOpts{selfHosted: true, enforce: true, stateRebasedAgainst: stamped})
	cst := c.run(t)
	if !hasEntry(cst, "devpin-postgres") || len(c.anyRebaseSignal()) != 0 {
		t.Errorf("control: a state already rebased against this composition must be left alone: %v %v", attachedIDs(cst), c.anyRebaseSignal())
	}
}

// Once per composition: the second tick after an enforcing rebase is a no-op.
func TestStateRebase_SecondTickIsNoOp(t *testing.T) {
	h := newRebaseHarness(t, opsHubFixture(), rebaseOpts{selfHosted: true, enforce: true})
	first := h.run(t)
	n := len(*h.signals)
	second := h.run(t)
	if strings.Join(attachedIDs(first), ",") != strings.Join(attachedIDs(second), ",") || first.RebasedAgainst != second.RebasedAgainst {
		t.Errorf("second tick changed state: %v -> %v", attachedIDs(first), attachedIDs(second))
	}
	for _, s := range (*h.signals)[n:] {
		for _, st := range []string{stageStateRebased, stageStateWouldRebase, stageStateRebaseSkipped} {
			if strings.HasPrefix(s, st+":") {
				t.Errorf("second tick emitted %s", s)
			}
		}
	}
}

// DryRun never persists, even with the rebase enabled: it only reports.
func TestStateRebase_DryRunDoesNotPersist(t *testing.T) {
	h := newRebaseHarness(t, opsHubFixture(), rebaseOpts{enforce: true, dryRun: true})
	before, _ := os.ReadFile(h.statePath)
	h.run(t)
	after, _ := os.ReadFile(h.statePath)
	if string(before) != string(after) {
		t.Errorf("DryRun rewrote state.json")
	}
	if matches, _ := filepath.Glob(h.statePath + ".pre-rebase-*"); len(matches) != 0 {
		t.Errorf("DryRun wrote a backup: %v", matches)
	}
	if len(h.signalsFor(stageStateWouldRebase)) != 1 || len(h.signalsFor(stageStateRebased)) != 0 {
		t.Errorf("DryRun: want a would-drop report and no rebase, got %v", *h.signals)
	}
}

// Never adds: a module the breadcrumb composed but state.json does not name
// (and the platform does not assign) stays absent.
func TestStateRebase_NeverAdds(t *testing.T) {
	mods := []rebaseModule{
		{id: "m-base", digest: "sha256:ba5e", assigned: true, inState: true, composed: true},
		{id: "m-composed-only", digest: "sha256:c0", composed: true},
		{id: "dead-one", digest: "sha256:dead3", inState: true, services: true},
	}
	h := newRebaseHarness(t, mods, rebaseOpts{selfHosted: true, enforce: true})
	st := h.run(t)
	if hasEntry(st, "m-composed-only") {
		t.Errorf("the rebase added a module state never named: %v", attachedIDs(st))
	}
	if hasEntry(st, "dead-one") {
		t.Errorf("control: dead entry kept, so this test proves nothing about adding: %v", attachedIDs(st))
	}
}

// F1: a dropped module leaves the identity/sudoers/egress render, so the
// report must name everything only it contributed, every id that differs from
// the surviving declaration, and whether egress enforcement switches off.
func TestStateRebase_ReportNamesRenderImpact(t *testing.T) {
	dead := rebaseModule{id: "devpin-pg", digest: "sha256:dead1", inState: true, services: true,
		users: []manifest.ManifestUser{
			{Name: "pgdev", UID: 5001, PrimaryGID: 5001, PrimaryGroup: "pgdev", Shell: "/bin/false", Home: "/var/lib/pgdev"},
			{Name: "postgres", UID: 998, PrimaryGID: 998, PrimaryGroup: "postgres", Shell: "/bin/false", Home: "/var/lib/postgresql"},
		},
		egress: []string{"10.9.9.9:5432"}}
	survivor := func(egress []string) rebaseModule {
		return rebaseModule{id: "m-postgres", digest: "sha256:aaa3", assigned: true, inState: true, composed: true,
			users:  []manifest.ManifestUser{{Name: "postgres", UID: 999, PrimaryGID: 999, PrimaryGroup: "postgres", Shell: "/bin/false", Home: "/var/lib/postgresql"}},
			egress: egress}
	}

	t.Run("survivors enforce egress", func(t *testing.T) {
		h := newRebaseHarness(t, []rebaseModule{survivor([]string{"1.1.1.1:443"}), dead}, rebaseOpts{})
		h.run(t)
		would := h.signalsFor(stageStateWouldRebase)
		if len(would) != 1 {
			t.Fatalf("want one report, got %v", *h.signals)
		}
		for _, want := range []string{"pgdev(uid 5001, devpin-pg)", "user postgres: devpin-pg says 998, surviving 999",
			"10.9.9.9:5432(devpin-pg)", "egress enforcement turns off: false"} {
			if !strings.Contains(would[0], want) {
				t.Errorf("report missing %q: %s", want, would[0])
			}
		}
		if strings.Contains(would[0], "users only they declare [postgres") {
			t.Errorf("postgres is not sole-source (the survivor declares it): %s", would[0])
		}
	})
	t.Run("enforce refuses an id conflict", func(t *testing.T) {
		h := newRebaseHarness(t, []rebaseModule{survivor([]string{"1.1.1.1:443"}), dead}, rebaseOpts{selfHosted: true, enforce: true})
		st := h.run(t)
		if !hasEntry(st, "devpin-pg") || st.RebasedAgainst != "" {
			t.Errorf("enforce dropped a module whose user id conflicts with a survivor: %v stamp %q", attachedIDs(st), st.RebasedAgainst)
		}
		skipped := h.signalsFor(stageStateRebaseSkipped)
		if len(skipped) != 1 || !strings.Contains(skipped[0], "user postgres: devpin-pg says 998, surviving 999") {
			t.Errorf("want a skip naming the conflict, got %v", skipped)
		}
	})
	t.Run("control: enforce drops the same module without the conflict", func(t *testing.T) {
		noConflict := dead
		noConflict.users = dead.users[:1]
		h := newRebaseHarness(t, []rebaseModule{survivor([]string{"1.1.1.1:443"}), noConflict}, rebaseOpts{selfHosted: true, enforce: true})
		st := h.run(t)
		rebased := h.signalsFor(stageStateRebased)
		if hasEntry(st, "devpin-pg") || len(rebased) != 1 || !strings.Contains(rebased[0], "pgdev(uid 5001, devpin-pg)") {
			t.Errorf("want devpin-pg dropped with its sole-source user named: %v %v", attachedIDs(st), rebased)
		}
	})
	t.Run("only the dropped module enforces egress", func(t *testing.T) {
		h := newRebaseHarness(t, []rebaseModule{survivor(nil), dead}, rebaseOpts{})
		h.run(t)
		would := h.signalsFor(stageStateWouldRebase)
		if len(would) != 1 || !strings.Contains(would[0], "egress enforcement turns off: true") {
			t.Errorf("want the report to say egress enforcement turns off, got %v", would)
		}
	})
}

// The single-module CLI paths are not rebases: they carry the stamp through
// and never set it.
func TestStateRebase_CLIPathsNeverStamp(t *testing.T) {
	for _, seed := range []string{"", "k-already"} {
		t.Run("DetachOne/seed="+seed, func(t *testing.T) {
			h := newRebaseHarness(t, opsHubFixture(), rebaseOpts{enforce: true, stateRebasedAgainst: seed})
			if _, err := h.r.DetachOne(context.Background(), "devpin-ruby"); err != nil {
				t.Fatalf("DetachOne: %v", err)
			}
			if st := h.state(t); st.RebasedAgainst != seed || hasEntry(st, "devpin-ruby") {
				t.Errorf("DetachOne: stamp %q (want %q), devpin-ruby present=%t", st.RebasedAgainst, seed, hasEntry(st, "devpin-ruby"))
			}
		})
		t.Run("AttachOne/seed="+seed, func(t *testing.T) {
			mods := append(opsHubFixture(), rebaseModule{id: "m-new", digest: "sha256:ee", assigned: true})
			h := newRebaseHarness(t, mods, rebaseOpts{enforce: true, stateRebasedAgainst: seed})
			if _, err := h.r.AttachOne(context.Background(), "m-new"); err != nil {
				t.Fatalf("AttachOne: %v", err)
			}
			if st := h.state(t); st.RebasedAgainst != seed || !hasEntry(st, "m-new") {
				t.Errorf("AttachOne: stamp %q (want %q), m-new present=%t", st.RebasedAgainst, seed, hasEntry(st, "m-new"))
			}
		})
	}
}

// Regression pins — the self-host fence is OUT of scope for this change and
// must behave exactly as before: a service-bearing module leaving a self-hosted
// node is refused whatever the liveness evidence; a version bump passes.
func TestSelfHostFence_UnchangedByRebase(t *testing.T) {
	cases := []struct {
		name string
		mod  rebaseModule
		o    rebaseOpts
	}{
		{"dead, services declared", rebaseModule{services: true}, rebaseOpts{selfHosted: true}},
		{"unit file present", rebaseModule{services: true, unitFile: true}, rebaseOpts{selfHosted: true}},
		{"digest mounted", rebaseModule{services: true, mounted: true}, rebaseOpts{selfHosted: true}},
		{"in live union", rebaseModule{services: true, inUnion: true}, rebaseOpts{selfHosted: true}},
		{"mountinfo unreadable", rebaseModule{services: true}, rebaseOpts{selfHosted: true, mountInfoUnreadable: true}},
		{"unit dir unreadable", rebaseModule{services: true}, rebaseOpts{selfHosted: true, unitDirUnreadable: true}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			m := c.mod
			m.id, m.digest = "leaving", "sha256:1eave"
			h := newRebaseHarness(t, []rebaseModule{m}, c.o)
			mf, _ := manifest.LoadFromDisk(h.r.cfg.ManifestRoot, "leaving")
			out := h.r.filterUnsafeDetaches(
				mount.ModuleStack{{ID: "leaving", Digest: "sha256:1eave"}},
				nil,
				map[string]*manifest.Manifest{"leaving": mf})
			if len(out) != 0 {
				t.Errorf("%s: fence allowed a service-bearing detach on a self-hosted node", c.name)
			}
		})
	}
	t.Run("version bump passes", func(t *testing.T) {
		m := rebaseModule{id: "leaving", digest: "sha256:1eave", services: true, unitFile: true, mounted: true}
		h := newRebaseHarness(t, []rebaseModule{m}, rebaseOpts{selfHosted: true})
		out := h.r.filterUnsafeDetaches(
			mount.ModuleStack{{ID: "leaving", Digest: "sha256:1eave"}},
			mount.ModuleStack{{ID: "leaving", Digest: "sha256:ne4"}},
			map[string]*manifest.Manifest{})
		if len(out) != 1 {
			t.Errorf("a version bump was refused: %v", *h.signals)
		}
	})
}
