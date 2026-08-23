package runtime

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

var errStubReload = errors.New("stub: daemon-reload failed")

// writeMountInfoFixture drops a mountinfo body in a temp dir and returns
// its path, for mount.SetMountInfoPathForTest.
func writeMountInfoFixture(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "mountinfo")
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatalf("write mountinfo fixture: %v", err)
	}
	return p
}

// pinNextrootUnionWithoutLayers points the mount-table parser at a fixture
// holding a MOUNTED but layer-less overlay at /run/nextroot (so the gate
// enumerates zero layers) and a childless /persist carrier bind (so the
// submount walk finds its destination and, correctly, nothing beneath it).
//
// IMP-de738c292bf9 changed what this fixture must contain. It used to omit the
// overlay entirely, which was a convenient way to get an empty layer report —
// but an ABSENT union is now an error (mount.ErrNoOverlayAt), because in
// production the gate runs only AFTER MountUnion composed /run/nextroot, so
// "nothing is mounted there" means the composition was torn down underneath it
// rather than "no layer is doomed". The empty-layer report these tests want is
// still reachable honestly: an overlay that IS mounted and carries no
// lowerdir=. Pinned as an error by ...RefusesWhenTheNextrootUnionIsAbsent.
//
// EVERY gate test must pin the table, including the ones that do not care
// about layers or submounts. NextrootSurvivalGate reads it unconditionally
// — mount.LiveUnionLowerDirs for the layer report, mount.SubmountsBeneath
// for each bind destination — so an unpinned test reads the HOST's
// /proc/self/mountinfo: green on a machine with no prepared nextroot, red
// on a pivot node that currently holds one, which is precisely the machine
// and moment this feature targets. Host-dependent green is not green. And
// a fixture that omits the carrier bind refuses in the walk (fail closed,
// pinned by ...RefusesWhenABindDestinationIsAbsentFromTheMountTable), so
// the carrier line here is load-bearing for every passing-path test.
func pinNextrootUnionWithoutLayers(t *testing.T) {
	t.Helper()
	restore := mount.SetMountInfoPathForTest(writeMountInfoFixture(t,
		"27 1 8:1 / / rw,relatime shared:1 - ext4 /dev/sda1 rw\n"+
			"40 27 8:2 / /persist rw,relatime shared:2 - ext4 /dev/sda2 rw\n"+
			"88 27 0:99 / /run/nextroot rw,relatime shared:9 - overlay overlay rw,upperdir=/run/powernode/nextroot-scratch-gen1/upper,workdir=/run/powernode/nextroot-scratch-gen1/work\n"+
			"90 27 8:2 / /run/nextroot/persist rw,relatime shared:2 - ext4 /dev/sda2 rw\n"))
	t.Cleanup(restore)
}

// The concurrent-teardown case the layer report used to read as a clean bill of
// health: another recompose unmounts /run/nextroot between compose and
// gate-read, LiveUnionLowerDirs returned an empty set, and the gate reported
// "no layer doomed" while --execute proceeded. It is an ENVIRONMENT failure —
// the gate could not reach a verdict — not a refusal.
func TestNextrootSurvivalGate_RefusesWhenTheNextrootUnionIsAbsent(t *testing.T) {
	restore := mount.SetMountInfoPathForTest(writeMountInfoFixture(t,
		"27 1 8:1 / / rw,relatime shared:1 - ext4 /dev/sda1 rw\n"+
			"40 27 8:2 / /persist rw,relatime shared:2 - ext4 /dev/sda2 rw\n"+
			"90 27 8:2 / /run/nextroot/persist rw,relatime shared:2 - ext4 /dev/sda2 rw\n"))
	defer restore()

	run := gateRunner(map[string]string{
		unionUnit:   propsSurvive,
		carrierUnit: propsSurvive,
	})

	doomed, err := NextrootSurvivalGate(context.Background(), run, gateLayout(), gateBindDests)

	if err == nil {
		t.Fatalf("an absent nextroot union must not read as a clean empty layer report, got doomed=%v", doomed)
	}
	if !errors.Is(err, ErrGateEnvironment) {
		t.Errorf("an absent union is an environment failure, not a refusal, got %v", err)
	}
	if errors.Is(err, ErrGateRefused) {
		t.Errorf("must NOT be classified as a refusal — the fix is not drop-ins, got %v", err)
	}
}

func containsPath(paths []string, want string) bool {
	for _, p := range paths {
		if p == want {
			return true
		}
	}
	return false
}

// Property strings as `systemctl show` renders them for the three states
// that matter: configured to survive, scheduled for teardown, and a unit
// systemd has never heard of.
const (
	propsSurvive = "DefaultDependencies=no\nConflicts=\nLoadState=loaded\n"
	propsDoomed  = "DefaultDependencies=yes\nConflicts=umount.target\nLoadState=loaded\n"
	propsUnknown = "LoadState=not-found\n"
)

// gateRunner stubs `systemctl show` per UNIT NAME, so a test can give the
// union, the /persist carrier and the layer mounts different answers —
// which is the whole point of the gate: two of them are lethal and the
// rest are not.
func gateRunner(byUnit map[string]string) *mount.RecorderRunner {
	stub := map[string][]byte{"systemctl --version": []byte("systemd 255 (255.4)\n")}
	for unit, props := range byUnit {
		stub["systemctl show "+unit+" -p DefaultDependencies -p Conflicts -p LoadState"] = []byte(props)
	}
	return &mount.RecorderRunner{StubOutput: stub}
}

// The two mounts the gate exists for, at their STABLE unit names.
const (
	unionUnit   = "run-nextroot.mount"
	carrierUnit = "run-nextroot-persist.mount"
)

var gateBindDests = []string{"/run/nextroot/persist"}

func gateLayout() mount.Layout { return mount.NextrootLayout("gen1") }

// LETHAL MOUNT 1 — the union itself. systemd-soft-reboot switches into
// /run/nextroot only if it still finds an OS tree there. Tear the union
// down at umount.target and PID1's probe fails, the switch silently does
// NOT happen, and (before this gate) soft_recompose.go had already
// committed a boot breadcrumb asserting that it did.
func TestNextrootSurvivalGate_RefusesWhenTheUnionItselfWouldBeTornDown(t *testing.T) {
	pinNextrootUnionWithoutLayers(t)
	run := gateRunner(map[string]string{
		unionUnit:   propsDoomed,
		carrierUnit: propsSurvive,
	})
	_, err := NextrootSurvivalGate(context.Background(), run, gateLayout(), gateBindDests)
	if err == nil || !strings.Contains(err.Error(), "/run/nextroot") {
		t.Fatalf("want a refusal naming the union mount, got %v", err)
	}
}

// LETHAL MOUNT 2 — the carrier. After the /run-bind fix, /persist reaches
// the new root SOLELY via this bind (prepareNextrootMounts). persist.mount
// carrying DefaultDependencies=no does NOT extend to it: a per-unit drop-in
// applies to one unit, and this is a separate, mountinfo-generated one.
func TestNextrootSurvivalGate_RefusesWhenThePersistCarrierWouldBeTornDown(t *testing.T) {
	pinNextrootUnionWithoutLayers(t)
	run := gateRunner(map[string]string{
		unionUnit:   propsSurvive,
		carrierUnit: propsDoomed,
	})
	_, err := NextrootSurvivalGate(context.Background(), run, gateLayout(), gateBindDests)
	if err == nil || !strings.Contains(err.Error(), "/run/nextroot/persist") {
		t.Fatalf("want a refusal naming the /persist carrier, got %v", err)
	}
}

// Every CLAUSE of the compound guard, on every LETHAL mount, independently.
// A compound guard where only one half is exercised is how a broken guard
// ships (the standing two-critic rule for boot-critical code).
func TestNextrootSurvivalGate_RefusesOnEveryClauseOfEveryLethalMount(t *testing.T) {
	pinNextrootUnionWithoutLayers(t)
	clauses := map[string]string{
		"conflicts only": "DefaultDependencies=no\nConflicts=umount.target\nLoadState=loaded\n",
		"deps only":      "DefaultDependencies=yes\nConflicts=\nLoadState=loaded\n",
		"unit unknown":   propsUnknown,
		"no output":      "",
	}
	for _, lethal := range []string{unionUnit, carrierUnit} {
		for name, props := range clauses {
			byUnit := map[string]string{unionUnit: propsSurvive, carrierUnit: propsSurvive}
			byUnit[lethal] = props
			_, err := NextrootSurvivalGate(context.Background(), gateRunner(byUnit), gateLayout(), gateBindDests)
			if err == nil {
				t.Errorf("%s / %s: must refuse, got nil", lethal, name)
			}
		}
	}
}

// The passing case must actually be reachable — a gate that refuses
// unconditionally is not a safety feature, it is the soft-reboot tier
// deleted. This is the state the two shipped drop-ins produce.
func TestNextrootSurvivalGate_PassesWhenBothLethalMountsSurvive(t *testing.T) {
	pinNextrootUnionWithoutLayers(t)
	run := gateRunner(map[string]string{
		unionUnit:   propsSurvive,
		carrierUnit: propsSurvive,
		// The scratch is ALWAYS evaluated, so a clean report needs it
		// stubbed too; unstubbed it reads as unknown, which the advisory
		// arm reports rather than refuses (asserted below).
		`run-powernode-nextroot\x2dscratch\x2dgen1.mount`: propsSurvive,
	})
	doomed, err := NextrootSurvivalGate(context.Background(), run, gateLayout(), gateBindDests)
	if err != nil {
		t.Fatalf("both lethal mounts configured to survive must pass, got %v", err)
	}
	if len(doomed) != 0 {
		t.Errorf("nothing is scheduled for teardown, so the report should be empty, got %v", doomed)
	}
}

// An unknown LAYER unit is reported, never refused — the asymmetry that
// makes this gate usable. The same LoadState=not-found on a LETHAL mount
// refuses (TestNextrootSurvivalGate_RefusesOnEveryClauseOfEveryLethalMount);
// on the scratch it is advice. Without this the gate would refuse on every
// node whose scratch unit systemd has not adopted yet.
func TestNextrootSurvivalGate_UnknownLayerUnitIsAdvisoryNotFatal(t *testing.T) {
	pinNextrootUnionWithoutLayers(t)
	run := gateRunner(map[string]string{
		unionUnit:   propsSurvive,
		carrierUnit: propsSurvive,
	}) // scratch deliberately unstubbed -> LoadState unknown
	doomed, err := NextrootSurvivalGate(context.Background(), run, gateLayout(), gateBindDests)
	if err != nil {
		t.Fatalf("an unprovable LAYER mount must not refuse, got %v", err)
	}
	if !containsPath(doomed, "/run/powernode/nextroot-scratch-gen1") {
		t.Errorf("the scratch must still be reported when unprovable, got %v", doomed)
	}
}

// The layer mounts (erofs lowerdirs + the nextroot scratch upperdir) are
// REPORTED, never refused.
//
// This pins a REMEDIABILITY decision, not a safety finding — whether losing
// a layer mount harms the new root is unsettled, and the repo holds both
// answers (see NextrootSurvivalGate's comment: design doc §7 vs the live
// pivot-node observation in mount/union_lowers.go). What IS settled is that
// refusing on them cannot be remediated: their unit names are digest- and
// generation-derived, so no static drop-in can ever cover them, and a guard
// no shipped file can satisfy is a guard that deletes the tier.
func TestNextrootSurvivalGate_LayerTeardownIsReportedNotRefused(t *testing.T) {
	restore := mount.SetMountInfoPathForTest(writeMountInfoFixture(t,
		"27 1 0:24 / / rw,relatime shared:1 - overlay overlay rw,lowerdir=/run/powernode/modules/sha256_live,upperdir=/run/powernode/scratch/upper,workdir=/run/powernode/scratch/work\n"+
			"88 27 0:99 / /run/nextroot rw,relatime shared:9 - overlay overlay rw,lowerdir=/run/powernode/modules/sha256_aaa:/run/powernode/modules/sha256_bbb,upperdir=/run/powernode/nextroot-scratch-gen1/upper,workdir=/run/powernode/nextroot-scratch-gen1/work\n"+
			"90 88 8:2 / /run/nextroot/persist rw,relatime shared:2 - ext4 /dev/sda2 rw\n"))
	defer restore()

	run := gateRunner(map[string]string{
		unionUnit:   propsSurvive,
		carrierUnit: propsSurvive,
		// Exactly what a live pivot node reports for these (2026-08-11).
		"run-powernode-modules-sha256_aaa.mount":          propsDoomed,
		"run-powernode-modules-sha256_bbb.mount":          propsDoomed,
		`run-powernode-nextroot\x2dscratch\x2dgen1.mount`: propsDoomed,
	})
	doomed, err := NextrootSurvivalGate(context.Background(), run, gateLayout(), gateBindDests)
	if err != nil {
		t.Fatalf("layer teardown must be REPORTED, not refused — no drop-in can name a "+
			"digest-derived unit, so a refusal here disables the tier permanently; got %v", err)
	}
	for _, want := range []string{
		"/run/powernode/modules/sha256_aaa",
		"/run/powernode/modules/sha256_bbb",
		"/run/powernode/nextroot-scratch-gen1",
	} {
		if !containsPath(doomed, want) {
			t.Errorf("doomed layer report is missing %q; got %v", want, doomed)
		}
	}
}

// The gate must enumerate the union's ACTUAL lowerdirs, not a re-derivation
// of what the composer was asked to build. A layer that is in the live
// table but not in any expectation is precisely the case that bit the
// detach path before (union_lowers.go).
func TestNextrootSurvivalGate_ReadsLowerdirsFromTheLiveTableNotTheLayout(t *testing.T) {
	restore := mount.SetMountInfoPathForTest(writeMountInfoFixture(t,
		"88 27 0:99 / /run/nextroot rw,relatime shared:9 - overlay overlay rw,lowerdir=/run/powernode/modules/sha256_unexpected,upperdir=/run/powernode/nextroot-scratch-gen1/upper,workdir=/run/powernode/nextroot-scratch-gen1/work\n"+
			"90 88 8:2 / /run/nextroot/persist rw,relatime shared:2 - ext4 /dev/sda2 rw\n"))
	defer restore()

	run := gateRunner(map[string]string{
		unionUnit:   propsSurvive,
		carrierUnit: propsSurvive,
		"run-powernode-modules-sha256_unexpected.mount": propsDoomed,
	})
	doomed, err := NextrootSurvivalGate(context.Background(), run, gateLayout(), gateBindDests)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !containsPath(doomed, "/run/powernode/modules/sha256_unexpected") {
		t.Errorf("a lowerdir present only in the live mount table must still be enumerated, got %v", doomed)
	}
}

// Drop-ins shipped by a hot-reconcile are invisible to systemd until it
// rescans unit files. Probing first would read the PRE-delivery properties
// and refuse on a node that is in fact correctly configured.
func TestNextrootSurvivalGate_DaemonReloadPrecedesEveryProbe(t *testing.T) {
	pinNextrootUnionWithoutLayers(t)
	run := gateRunner(map[string]string{
		unionUnit:   propsSurvive,
		carrierUnit: propsSurvive,
	})
	if _, err := NextrootSurvivalGate(context.Background(), run, gateLayout(), gateBindDests); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	reloadAt, firstShowAt := -1, -1
	for i, inv := range run.Invocations {
		if inv.Name != "systemctl" || len(inv.Args) == 0 {
			continue
		}
		if inv.Args[0] == "daemon-reload" && reloadAt < 0 {
			reloadAt = i
		}
		if inv.Args[0] == "show" && firstShowAt < 0 {
			firstShowAt = i
		}
	}
	if reloadAt < 0 {
		t.Fatalf("gate never ran `systemctl daemon-reload`; invocations=%v", run.Invocations)
	}
	if firstShowAt >= 0 && reloadAt > firstShowAt {
		t.Errorf("daemon-reload ran at %d, AFTER the first probe at %d — the probe read stale properties", reloadAt, firstShowAt)
	}
}

// A daemon-reload that fails means the drop-ins are unproven, and unproven
// is the state this file treats as "do not proceed".
func TestNextrootSurvivalGate_RefusesWhenDaemonReloadFails(t *testing.T) {
	pinNextrootUnionWithoutLayers(t)
	run := gateRunner(map[string]string{unionUnit: propsSurvive, carrierUnit: propsSurvive})
	run.StubErr = map[string]error{"systemctl daemon-reload": errStubReload}
	if _, err := NextrootSurvivalGate(context.Background(), run, gateLayout(), gateBindDests); err == nil {
		t.Error("a failed daemon-reload leaves the drop-ins unproven and must refuse, got nil")
	}
}

// THE GATE MUST TYPE ITS OWN CAUSES (IMP-de738c292bf9).
//
// The report-side tests in soft_recompose_test.go construct a typed error and
// assert what writePrepareReport does with it — which pins the mapping but NOT
// that the gate ever produces one. A mutation that dropped ErrGateReloadFailed
// from the gate's wrap left every one of those tests green, so the
// classification is asserted HERE, against the gate's real error, on both
// sides: what it is and what it is not.
func TestNextrootSurvivalGate_ReloadFailureIsTypedAsEnvironmentNotRefusal(t *testing.T) {
	pinNextrootUnionWithoutLayers(t)
	run := gateRunner(map[string]string{unionUnit: propsSurvive, carrierUnit: propsSurvive})
	run.StubErr = map[string]error{"systemctl daemon-reload": errStubReload}

	_, err := NextrootSurvivalGate(context.Background(), run, gateLayout(), gateBindDests)

	if !errors.Is(err, ErrGateReloadFailed) {
		t.Errorf("a failed reload must be identifiable as ErrGateReloadFailed, got %v", err)
	}
	if !errors.Is(err, ErrGateEnvironment) {
		t.Errorf("ErrGateReloadFailed must also answer to the ErrGateEnvironment class, got %v", err)
	}
	if errors.Is(err, ErrGateRefused) {
		t.Errorf("the gate never reached a verdict, so this must NOT read as a refusal, got %v", err)
	}
	if !errors.Is(err, errStubReload) {
		t.Errorf("the underlying cause must survive the classification wrap, got %v", err)
	}
}

// The other side of the same contract: a mount that genuinely would not survive
// is a REFUSAL, and must not be reclassified as an environment failure — that
// would send a CI wrapper looking for permissions when the fix is drop-ins.
func TestNextrootSurvivalGate_DoomedMountIsTypedAsRefusalNotEnvironment(t *testing.T) {
	pinNextrootUnionWithoutLayers(t)
	run := gateRunner(map[string]string{unionUnit: propsDoomed, carrierUnit: propsSurvive})

	_, err := NextrootSurvivalGate(context.Background(), run, gateLayout(), gateBindDests)

	if !errors.Is(err, ErrGateRefused) {
		t.Errorf("a doomed lethal mount is a refusal, got %v", err)
	}
	if errors.Is(err, ErrGateEnvironment) {
		t.Errorf("a reached verdict must NOT read as 'could not reach a verdict', got %v", err)
	}
}

// RBIND-CARRIED SUBMOUNTS. prepareNextrootMounts uses `mount --rbind`, so
// every child mount of a bind source is reproduced beneath the destination
// as its OWN mountinfo-generated unit with its own survival properties — a
// drop-in on the destination's unit does not reach it. A gate that probes
// the destination as one unit passes while a nested submount (say, a
// storage volume ReconcileStorageVolume mounted under /persist) is torn
// down at umount.target, and the new root comes up with /persist present
// but the volume's data gone from under it.
func TestNextrootSurvivalGate_RefusesWhenAnRbindCarriedSubmountWouldBeTornDown(t *testing.T) {
	restore := mount.SetMountInfoPathForTest(writeMountInfoFixture(t,
		"27 1 8:1 / / rw,relatime shared:1 - ext4 /dev/sda1 rw\n"+
			"40 27 8:2 / /persist rw,relatime shared:2 - ext4 /dev/sda2 rw\n"+
			"90 27 8:2 / /run/nextroot/persist rw,relatime shared:2 - ext4 /dev/sda2 rw\n"+
			"95 90 8:16 / /run/nextroot/persist/volumes/pgdata rw,relatime shared:12 - ext4 /dev/sdb1 rw\n"))
	defer restore()

	run := gateRunner(map[string]string{
		unionUnit:                      propsSurvive,
		carrierUnit:                    propsSurvive,
		"persist-volumes-pgdata.mount": propsSurvive, // the SOURCE is configured...
		"run-nextroot-persist-volumes-pgdata.mount": propsDoomed, // ...but the COPY is not
	})
	_, err := NextrootSurvivalGate(context.Background(), run, gateLayout(), gateBindDests)
	if err == nil || !strings.Contains(err.Error(), "/run/nextroot/persist/volumes/pgdata") {
		t.Fatalf("a doomed submount beneath a bind destination must refuse, naming the submount; got %v", err)
	}
}

// A submount must be proven on BOTH sides of the rbind. The nextroot COPY
// has its own generated unit, but this file's own measurement (the
// persist.mount runs in the CriticalSoftRebootMounts comment) shows the
// copy's fate FOLLOWS the source's: unmounting the source releases the
// filesystem and takes the copy with it, whatever the copy's unit says.
// A gate that probes only the copy goes green once the operator ships the
// copy-side drop-in, while the un-drop-inned SOURCE unit still tears the
// volume down at umount.target — the exact silent data loss this gate
// exists to refuse.
func TestNextrootSurvivalGate_RefusesWhenASubmountSourceUnitWouldBeTornDown(t *testing.T) {
	restore := mount.SetMountInfoPathForTest(writeMountInfoFixture(t,
		"27 1 8:1 / / rw,relatime shared:1 - ext4 /dev/sda1 rw\n"+
			"40 27 8:2 / /persist rw,relatime shared:2 - ext4 /dev/sda2 rw\n"+
			"90 27 8:2 / /run/nextroot/persist rw,relatime shared:2 - ext4 /dev/sda2 rw\n"+
			"95 90 8:16 / /run/nextroot/persist/volumes/pgdata rw,relatime shared:12 - ext4 /dev/sdb1 rw\n"))
	defer restore()

	run := gateRunner(map[string]string{
		unionUnit:   propsSurvive,
		carrierUnit: propsSurvive,
		"run-nextroot-persist-volumes-pgdata.mount": propsSurvive, // the COPY is configured
		"persist-volumes-pgdata.mount":              propsDoomed,  // the SOURCE is not
	})
	_, err := NextrootSurvivalGate(context.Background(), run, gateLayout(), gateBindDests)
	if err == nil || !strings.Contains(err.Error(), "/persist/volumes/pgdata") {
		t.Fatalf("a doomed SOURCE unit must refuse even when the copy survives, naming the source; got %v", err)
	}
}

// A submount's unit systemd has never heard of REFUSES — submounts get
// the carrier's fail-closed treatment, not the layers' advisory one. The
// same LoadState on the scratch is advice
// (TestNextrootSurvivalGate_UnknownLayerUnitIsAdvisoryNotFatal); here it
// is durable data under /persist, and unproven means do not proceed.
func TestNextrootSurvivalGate_RefusesWhenASubmountUnitIsUnknownToSystemd(t *testing.T) {
	restore := mount.SetMountInfoPathForTest(writeMountInfoFixture(t,
		"27 1 8:1 / / rw,relatime shared:1 - ext4 /dev/sda1 rw\n"+
			"90 27 8:2 / /run/nextroot/persist rw,relatime shared:2 - ext4 /dev/sda2 rw\n"+
			"95 90 8:16 / /run/nextroot/persist/volumes/pgdata rw,relatime shared:12 - ext4 /dev/sdb1 rw\n"))
	defer restore()

	run := gateRunner(map[string]string{
		unionUnit:                      propsSurvive,
		carrierUnit:                    propsSurvive,
		"persist-volumes-pgdata.mount": propsSurvive,
	}) // the COPY's unit deliberately unstubbed -> unknown to systemd
	_, err := NextrootSurvivalGate(context.Background(), run, gateLayout(), gateBindDests)
	if err == nil || !strings.Contains(err.Error(), "/run/nextroot/persist/volumes/pgdata") {
		t.Fatalf("an unprovable submount must refuse naming it, got %v", err)
	}
}

// The green path with submounts present must be reachable: a submount
// whose unit IS configured to survive passes, and is not smuggled into
// the advisory teardown report either.
func TestNextrootSurvivalGate_PassesWhenEverySubmountSurvives(t *testing.T) {
	restore := mount.SetMountInfoPathForTest(writeMountInfoFixture(t,
		"27 1 8:1 / / rw,relatime shared:1 - ext4 /dev/sda1 rw\n"+
			// The composed union itself — layer-less, so the layer report stays
			// empty without pretending the nextroot is unmounted (an absent one
			// is now an error; IMP-de738c292bf9).
			"88 27 0:99 / /run/nextroot rw,relatime shared:9 - overlay overlay rw,upperdir=/run/powernode/nextroot-scratch-gen1/upper,workdir=/run/powernode/nextroot-scratch-gen1/work\n"+
			"90 27 8:2 / /run/nextroot/persist rw,relatime shared:2 - ext4 /dev/sda2 rw\n"+
			"95 90 8:16 / /run/nextroot/persist/volumes/pgdata rw,relatime shared:12 - ext4 /dev/sdb1 rw\n"))
	defer restore()

	run := gateRunner(map[string]string{
		unionUnit:   propsSurvive,
		carrierUnit: propsSurvive,
		// BOTH sides of the rbind must be stubbed surviving — the gate
		// probes the source unit and the copy unit, and either alone is
		// insufficient (...RefusesWhenASubmountSourceUnitWouldBeTornDown).
		"persist-volumes-pgdata.mount":                    propsSurvive,
		"run-nextroot-persist-volumes-pgdata.mount":       propsSurvive,
		`run-powernode-nextroot\x2dscratch\x2dgen1.mount`: propsSurvive,
	})
	doomed, err := NextrootSurvivalGate(context.Background(), run, gateLayout(), gateBindDests)
	if err != nil {
		t.Fatalf("a surviving submount must not refuse, got %v", err)
	}
	if len(doomed) != 0 {
		t.Errorf("nothing is scheduled for teardown, so the report should be empty, got %v", doomed)
	}
}

// FAIL CLOSED when the source side cannot be derived: the source-unit
// probe maps a submount back to its origin by stripping the sysroot from
// its path, which only works for destinations established under the
// sysroot (as prepareNextrootMounts does). A submount outside it has no
// derivable source, and a submount whose origin is unknown must refuse —
// every unit that IS derivable surviving (as stubbed here) must not
// rescue it.
func TestNextrootSurvivalGate_RefusesASubmountWhoseSourceCannotBeDerived(t *testing.T) {
	restore := mount.SetMountInfoPathForTest(writeMountInfoFixture(t,
		"27 1 8:1 / / rw,relatime shared:1 - ext4 /dev/sda1 rw\n"+
			"60 27 8:7 / /elsewhere rw,relatime shared:6 - ext4 /dev/sda7 rw\n"+
			"61 60 8:8 / /elsewhere/x rw,relatime shared:7 - ext4 /dev/sda8 rw\n"))
	defer restore()

	run := gateRunner(map[string]string{
		unionUnit:           propsSurvive,
		"elsewhere.mount":   propsSurvive,
		"elsewhere-x.mount": propsSurvive,
	})
	_, err := NextrootSurvivalGate(context.Background(), run, gateLayout(), []string{"/elsewhere"})
	if err == nil || !strings.Contains(err.Error(), "/elsewhere/x") {
		t.Fatalf("a submount outside the sysroot has no derivable source and must refuse naming it, got %v", err)
	}
}

// FAIL CLOSED on the walk itself: a bind destination the mount table does
// not contain is not "no submounts" — it means the table cannot be
// trusted about what the rbind carried, and the gate must refuse rather
// than pass on ignorance. (This is the shape the LiveUnionLowerDirs
// ([], nil) defect taught: an empty answer is not a clean bill.)
func TestNextrootSurvivalGate_RefusesWhenABindDestinationIsAbsentFromTheMountTable(t *testing.T) {
	restore := mount.SetMountInfoPathForTest(writeMountInfoFixture(t,
		"27 1 8:1 / / rw,relatime shared:1 - ext4 /dev/sda1 rw\n")) // no carrier entry
	defer restore()

	run := gateRunner(map[string]string{unionUnit: propsSurvive, carrierUnit: propsSurvive})
	_, err := NextrootSurvivalGate(context.Background(), run, gateLayout(), gateBindDests)
	if err == nil || !strings.Contains(err.Error(), "/run/nextroot/persist") {
		t.Fatalf("a bind destination absent from the mount table must refuse naming it, got %v", err)
	}
}

// FAIL CLOSED on a table the walk cannot fully parse. LiveUnionLowerDirs
// skips lines it cannot read (the advisory arm tolerates it); the
// submount walk must not, because the skipped line could be the doomed
// submount itself.
func TestNextrootSurvivalGate_RefusesWhenTheMountTableHasAnUnparseableLine(t *testing.T) {
	restore := mount.SetMountInfoPathForTest(writeMountInfoFixture(t,
		"27 1 8:1 / / rw,relatime shared:1 - ext4 /dev/sda1 rw\n"+
			"90 27 8:2 / /run/nextroot/persist rw,relatime shared:2 - ext4 /dev/sda2 rw\n"+
			"THIS LINE IS NOT MOUNTINFO\n"))
	defer restore()

	run := gateRunner(map[string]string{unionUnit: propsSurvive, carrierUnit: propsSurvive})
	if _, err := NextrootSurvivalGate(context.Background(), run, gateLayout(), gateBindDests); err == nil {
		t.Fatal("an unparseable mount table proves nothing about submounts and must refuse, got nil")
	}
}

// The gate must check the bind destinations prepareNextrootMounts ACTUALLY
// established, not a hard-coded /persist assumption: adding a bind source
// adds a load-bearing carrier, and the gate has to see it.
func TestNextrootSurvivalGate_ChecksEveryBindDestinationGiven(t *testing.T) {
	pinNextrootUnionWithoutLayers(t)
	run := gateRunner(map[string]string{
		unionUnit:                 propsSurvive,
		carrierUnit:               propsSurvive,
		"run-nextroot-etcd.mount": propsDoomed,
	})
	_, err := NextrootSurvivalGate(context.Background(), run, gateLayout(),
		[]string{"/run/nextroot/persist", "/run/nextroot/etcd"})
	if err == nil || !strings.Contains(err.Error(), "/run/nextroot/etcd") {
		t.Fatalf("want a refusal naming the second bind destination, got %v", err)
	}
}
