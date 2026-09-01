package storage

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/taskguard"
)

// These tests are the refusal oracle for IMP-671662bfd2dd. Every fixture is
// crafted to ESCAPE a directory or INJECT a line into a rendered config file —
// a merely odd-looking value proves nothing. None of them is a working exploit
// chain: the injected directives are inert markers, and the assertion is that
// the actuator never renders or writes them.
//
// Each test drives a REAL package entry point (Apply / ApplyExports /
// ProvisionGateway / ApplyChown) and asserts on observable side effects — the
// bytes on disk and the commands the runner was asked to execute — not on an
// error string. A refusal that still writes the file is not a refusal.

// redirectUnitDir points the systemd unit writes at a scratch directory and
// returns the parent it must never escape.
func redirectUnitDir(t *testing.T) (unitDir, parent string) {
	t.Helper()
	parent = t.TempDir()
	unitDir = filepath.Join(parent, "systemd", "system")
	if err := os.MkdirAll(unitDir, 0o755); err != nil {
		t.Fatalf("mkdir unit dir: %v", err)
	}
	orig := SystemdUnitDir
	SystemdUnitDir = unitDir
	t.Cleanup(func() { SystemdUnitDir = orig })
	return unitDir, parent
}

func redirectExportsDir(t *testing.T) (exportsDir, parent string) {
	t.Helper()
	parent = t.TempDir()
	exportsDir = filepath.Join(parent, "exports.d")
	if err := os.MkdirAll(exportsDir, 0o755); err != nil {
		t.Fatalf("mkdir exports dir: %v", err)
	}
	orig := ExportsDir
	ExportsDir = exportsDir
	t.Cleanup(func() { ExportsDir = orig })
	return exportsDir, parent
}

func legitMountTask(t *testing.T) *MountTask {
	t.Helper()
	return &MountTask{
		AssignmentID: "019f7cb5-3858-7000-8000-000000000001",
		UnitName:     "powernode-storage-mnt-data.mount",
		MountPath:    filepath.Join(t.TempDir(), "data"),
		Recipe: MountRecipe{
			Type:    "nfs4",
			Source:  "fd00::1:/srv/exports/data",
			Options: []string{"_netdev"},
		},
		Options:    []string{"rw", "vers=4.2"},
		Credential: CredentialRef{ID: "019f7cb5-3858-7000-8000-0000000000c1", Kind: "peer_ip_acl"},
		Encryption: EncryptionSpec{Mode: "none"},
	}
}

func legitExportsTask() *ExportsApplyTask {
	return &ExportsApplyTask{
		StorageID:       "019f7cb5-3858-7000-8000-000000000002",
		AccountID:       "019f7cb5-3858-7000-8000-000000000003",
		ExportPath:      "/srv/exports/data",
		DeploymentShape: "self_hosted",
		Entries: []ExportsEntry{
			{PeerIP: "fd00::1", UID: 100100, GID: 100100, Options: []string{"rw", "sync", "no_subtree_check"}},
		},
	}
}

func legitGatewayTask(t *testing.T) *GatewayProvisionTask {
	t.Helper()
	return &GatewayProvisionTask{
		StorageID:            "019f7cb5-3858-7000-8000-000000000004",
		AccountID:            "019f7cb5-3858-7000-8000-000000000005",
		UpstreamSourceHost:   "fd00::9",
		UpstreamExportPath:   "/srv/upstream",
		UpstreamMountOptions: []string{"vers=4.2", "proto=tcp", "hard"},
		ReExportPath:         filepath.Join(t.TempDir(), "reexport"),
		FSID:                 "deadbeef",
		GatewayUnitName:      "powernode-storage-gw-019f7cb5.mount",
	}
}

// --- RULE: unit_name must not escape the systemd unit directory -------------

func TestApplyRefusesUnitNameEscapingUnitDir(t *testing.T) {
	unitDir, parent := redirectUnitDir(t)
	escapeTarget := filepath.Join(parent, "escaped.mount")

	task := legitMountTask(t)
	// filepath.Join CLEANS this, it does not confine it: the result lands in
	// `parent`, two levels above the unit directory.
	task.UnitName = "../../escaped.mount"

	rec := &mount.RecorderRunner{}
	err := Apply(context.Background(), rec, nil, task)

	if err == nil {
		t.Fatal("expected Apply to refuse a unit_name that escapes the unit directory")
	}
	if _, statErr := os.Stat(escapeTarget); statErr == nil {
		t.Fatalf("unit_name escaped the unit directory: %s was written", escapeTarget)
	}
	if len(rec.Invocations) != 0 {
		t.Fatalf("expected no actuation after refusal, got %+v", rec.Invocations)
	}
	if entries, _ := os.ReadDir(unitDir); len(entries) != 0 {
		t.Fatalf("expected no unit written, got %d entries", len(entries))
	}
}

func TestApplyRefusesUnitNameNamingAServiceUnit(t *testing.T) {
	unitDir, _ := redirectUnitDir(t)

	task := legitMountTask(t)
	// A .service name is what turns unit-body injection into `systemctl start`
	// of a caller-chosen command. The platform's only producer emits .mount.
	task.UnitName = "powernode-019f7cb5-rails.service"

	rec := &mount.RecorderRunner{}
	if err := Apply(context.Background(), rec, nil, task); err == nil {
		t.Fatal("expected Apply to refuse a non-.mount unit_name")
	}
	if entries, _ := os.ReadDir(unitDir); len(entries) != 0 {
		t.Fatalf("expected no unit written, got %d entries", len(entries))
	}
	if len(rec.Invocations) != 0 {
		t.Fatalf("expected no actuation after refusal, got %+v", rec.Invocations)
	}
}

// The absent-field case needs the SENTINEL, not "an error came back": with no
// guard, filepath.Join(dir, "") yields the directory itself and os.WriteFile
// fails with EISDIR — an incidental failure that looks exactly like a refusal.
// This test passed before the validator existed for that reason.
func TestApplyRefusesEmptyUnitName(t *testing.T) {
	redirectUnitDir(t)

	task := legitMountTask(t)
	task.UnitName = ""

	rec := &mount.RecorderRunner{}
	err := Apply(context.Background(), rec, nil, task)
	if !errors.Is(err, taskguard.ErrRefused) {
		t.Fatalf("expected a taskguard refusal for an empty unit_name, got %v", err)
	}
	if len(rec.Invocations) != 0 {
		t.Fatalf("expected no actuation after refusal, got %+v", rec.Invocations)
	}
}

// Zero-valued numeric fields, pinned: a chown payload that names uid 0 as the
// OLD owner is the privilege-escalation shape, and it must be the PATH rule
// that stops it — uid 0 on a legitimate target stays legal, because that is
// how a genuine reassignment off root ownership is expressed.
func TestApplyChownAcceptsRootOldUIDOnALegitimateTarget(t *testing.T) {
	var invoked [][]string
	orig := runFind
	runFind = func(_ context.Context, args []string) error {
		invoked = append(invoked, args)
		return nil
	}
	t.Cleanup(func() { runFind = orig })

	task := &ChownTask{MountPath: "/srv/exports/data", OldUID: 0, OldGID: 0, NewUID: 100100, NewGID: 100100}
	if err := ApplyChown(context.Background(), task); err != nil {
		t.Fatalf("legitimate chown off root ownership was refused: %v", err)
	}
	if len(invoked) != 2 {
		t.Fatalf("expected a uid pass and a gid pass, got %d", len(invoked))
	}
}

// The other absent-field trap in this payload: renderMountUnit silently drops
// Requires=/After= when the hint is empty, so a mount that declares it needs
// the SDWAN tunnel would otherwise fire before the tunnel exists.
func TestApplyRefusesRequiresWGWithNoInterfaceHint(t *testing.T) {
	redirectUnitDir(t)

	task := legitMountTask(t)
	task.RequiresWGInterface = true
	task.WGInterfaceHint = ""

	rec := &mount.RecorderRunner{}
	if err := Apply(context.Background(), rec, nil, task); !errors.Is(err, taskguard.ErrRefused) {
		t.Fatalf("expected a refusal when requires_wg_interface has no hint, got %v", err)
	}
}

// --- RULE: a mount option must not inject a unit directive ------------------

func TestApplyRefusesMountOptionContainingNewline(t *testing.T) {
	unitDir, _ := redirectUnitDir(t)

	task := legitMountTask(t)
	// Inert marker, not a working exploit: the point is that a newline inside
	// one option ends the Options= line and starts a new directive.
	task.Options = append(task.Options, "rw\nZZInjectedDirective=1")

	rec := &mount.RecorderRunner{}
	if err := Apply(context.Background(), rec, nil, task); err == nil {
		t.Fatal("expected Apply to refuse a mount option containing a newline")
	}

	written := filepath.Join(unitDir, "powernode-storage-mnt-data.mount")
	body, readErr := os.ReadFile(written)
	if readErr == nil {
		t.Fatalf("unit body was rendered despite the injected directive:\n%s", body)
	}
	if len(rec.Invocations) != 0 {
		t.Fatalf("expected no actuation after refusal, got %+v", rec.Invocations)
	}
}

func TestApplyRefusesWGInterfaceHintContainingNewline(t *testing.T) {
	unitDir, _ := redirectUnitDir(t)

	task := legitMountTask(t)
	task.RequiresWGInterface = true
	// renderMountUnit interpolates the hint into Requires=/After= with the
	// same fmt.Sprintf and no escaping — a second injection point that the
	// options rule does not cover.
	task.WGInterfaceHint = "wg-sdwan-abc123\nZZInjectedDirective=1"

	rec := &mount.RecorderRunner{}
	if err := Apply(context.Background(), rec, nil, task); err == nil {
		t.Fatal("expected Apply to refuse a wg_interface_hint containing a newline")
	}
	if body, readErr := os.ReadFile(filepath.Join(unitDir, "powernode-storage-mnt-data.mount")); readErr == nil {
		t.Fatalf("unit body was rendered despite the injected directive:\n%s", body)
	}
}

// --- RULE: mount_path must not mask a critical system path ------------------

func TestApplyRefusesMountPathMaskingEtc(t *testing.T) {
	unitDir, _ := redirectUnitDir(t)

	task := legitMountTask(t)
	task.MountPath = "/etc" // Where=/etc masks the node's configuration tree

	rec := &mount.RecorderRunner{}
	if err := Apply(context.Background(), rec, nil, task); err == nil {
		t.Fatal("expected Apply to refuse mount_path /etc")
	}
	if entries, _ := os.ReadDir(unitDir); len(entries) != 0 {
		t.Fatalf("expected no unit written, got %d entries", len(entries))
	}
}

// --- RULE: chown mount_path must not target a critical system path ----------

func TestApplyChownRefusesEtc(t *testing.T) {
	var invoked [][]string
	orig := runFind
	runFind = func(_ context.Context, args []string) error {
		invoked = append(invoked, args)
		return nil
	}
	t.Cleanup(func() { runFind = orig })

	// The existing guard refuses exactly two values, "" and "/". /etc with
	// old_uid 0 passes it and hands the configuration tree to an unprivileged
	// uid as root.
	task := &ChownTask{MountPath: "/etc", OldUID: 0, OldGID: 0, NewUID: 1000, NewGID: 1000}
	if err := ApplyChown(context.Background(), task); err == nil {
		t.Fatal("expected ApplyChown to refuse mount_path /etc")
	}
	if len(invoked) != 0 {
		t.Fatalf("expected find never to run, got %+v", invoked)
	}
}

func TestApplyChownRefusesCallbackPathLeavingThePlatformOrigin(t *testing.T) {
	orig := runFind
	runFind = func(_ context.Context, _ []string) error { return nil }
	t.Cleanup(func() { runFind = orig })

	// transport.Client builds its URL as PlatformURL + path, so a callback
	// path that does not begin with "/" re-points the agent's mTLS POST.
	task := &ChownTask{
		MountPath:    "/srv/data",
		OldUID:       1000,
		NewUID:       1001,
		CallbackPath: "@example.invalid/collect",
	}
	if err := ApplyChown(context.Background(), task); err == nil {
		t.Fatal("expected ApplyChown to refuse a callback_path that is not platform-relative")
	}
}

// --- RULE: exports file name must not escape the exports directory ----------

func TestApplyExportsRefusesAccountIDEscapingExportsDir(t *testing.T) {
	exportsDir, parent := redirectExportsDir(t)

	task := legitExportsTask()
	// The file name is fmt.Sprintf("powernode-%s-%s.exports", AccountID,
	// StorageID); a leading slash makes "powernode-" its own component so the
	// following ".." pops it, and the result lands outside ExportsDir.
	task.AccountID = "/../escaped"

	rec := &mount.RecorderRunner{}
	if err := ApplyExports(context.Background(), rec, task); err == nil {
		t.Fatal("expected ApplyExports to refuse an account_id that escapes the exports directory")
	}
	matches, _ := filepath.Glob(filepath.Join(parent, "escaped-*"))
	if len(matches) != 0 {
		t.Fatalf("account_id escaped the exports directory: %v", matches)
	}
	if entries, _ := os.ReadDir(exportsDir); len(entries) != 0 {
		t.Fatalf("expected no exports file written, got %d entries", len(entries))
	}
	if len(rec.Invocations) != 0 {
		t.Fatalf("expected exportfs never to run, got %+v", rec.Invocations)
	}
}

func TestApplyExportsRefusesRootExportPath(t *testing.T) {
	exportsDir, _ := redirectExportsDir(t)

	task := legitExportsTask()
	task.ExportPath = "/" // exports the node's root filesystem

	rec := &mount.RecorderRunner{}
	if err := ApplyExports(context.Background(), rec, task); err == nil {
		t.Fatal("expected ApplyExports to refuse export_path /")
	}
	if entries, _ := os.ReadDir(exportsDir); len(entries) != 0 {
		t.Fatalf("expected no exports file written, got %d entries", len(entries))
	}
}

func TestApplyExportsRefusesEntryOptionContainingNewline(t *testing.T) {
	exportsDir, _ := redirectExportsDir(t)

	task := legitExportsTask()
	// A newline inside one option terminates the export line and starts
	// another one that nothing in the payload appears to authorise.
	task.Entries[0].Options = []string{"rw", "sync\nZZ_INJECTED_LINE"}

	rec := &mount.RecorderRunner{}
	if err := ApplyExports(context.Background(), rec, task); err == nil {
		t.Fatal("expected ApplyExports to refuse an export option containing a newline")
	}
	entries, _ := os.ReadDir(exportsDir)
	for _, e := range entries {
		body, _ := os.ReadFile(filepath.Join(exportsDir, e.Name()))
		if strings.Contains(string(body), "ZZ_INJECTED_LINE") {
			t.Fatalf("injected export line was written:\n%s", body)
		}
	}
	if len(entries) != 0 {
		t.Fatalf("expected no exports file written, got %d entries", len(entries))
	}
}

func TestApplyExportsRefusesNonAddressPeerIP(t *testing.T) {
	exportsDir, _ := redirectExportsDir(t)

	task := legitExportsTask()
	task.Entries[0].PeerIP = "* # "

	rec := &mount.RecorderRunner{}
	if err := ApplyExports(context.Background(), rec, task); err == nil {
		t.Fatal("expected ApplyExports to refuse a peer_ip that is not an address")
	}
	if entries, _ := os.ReadDir(exportsDir); len(entries) != 0 {
		t.Fatalf("expected no exports file written, got %d entries", len(entries))
	}
}

// --- RULE: gateway unit name must not escape either ------------------------

func TestProvisionGatewayRefusesUnitNameEscapingUnitDir(t *testing.T) {
	unitDir, parent := redirectUnitDir(t)
	escapeTarget := filepath.Join(parent, "gw-escaped.mount")

	task := legitGatewayTask(t)
	task.GatewayUnitName = "../../gw-escaped.mount"

	rec := &mount.RecorderRunner{}
	if err := ProvisionGateway(context.Background(), rec, task); err == nil {
		t.Fatal("expected ProvisionGateway to refuse a gateway_unit_name that escapes the unit directory")
	}
	if _, statErr := os.Stat(escapeTarget); statErr == nil {
		t.Fatalf("gateway_unit_name escaped the unit directory: %s was written", escapeTarget)
	}
	if entries, _ := os.ReadDir(unitDir); len(entries) != 0 {
		t.Fatalf("expected no unit written, got %d entries", len(entries))
	}
	if len(rec.Invocations) != 0 {
		t.Fatalf("expected no actuation after refusal, got %+v", rec.Invocations)
	}
}

func TestProvisionGatewayRefusesReExportPathMaskingEtc(t *testing.T) {
	unitDir, _ := redirectUnitDir(t)

	task := legitGatewayTask(t)
	task.ReExportPath = "/etc"

	rec := &mount.RecorderRunner{}
	if err := ProvisionGateway(context.Background(), rec, task); err == nil {
		t.Fatal("expected ProvisionGateway to refuse re_export_path /etc")
	}
	if entries, _ := os.ReadDir(unitDir); len(entries) != 0 {
		t.Fatalf("expected no unit written, got %d entries", len(entries))
	}
}

// --- RULE: samba username/password must not become samba-tool flags ---------

func TestApplySambaUserRefusesFlagLikeUsername(t *testing.T) {
	rec := &mount.RecorderRunner{}
	task := &SmbUserApplyTask{
		StorageID: "019f7cb5-3858-7000-8000-000000000006",
		AccountID: "019f7cb5-3858-7000-8000-000000000007",
		Action:    "create",
		Username:  "--option=zz",
		Password:  "s3cret",
	}
	if err := ApplySambaUser(context.Background(), rec, task); err == nil {
		t.Fatal("expected ApplySambaUser to refuse a flag-like username")
	}
	if len(rec.Invocations) != 0 {
		t.Fatalf("expected samba-tool never to run, got %+v", rec.Invocations)
	}
}

func TestApplySambaUserRefusalDoesNotEchoThePassword(t *testing.T) {
	rec := &mount.RecorderRunner{}
	const secret = "correct-horse-battery-staple"
	task := &SmbUserApplyTask{
		StorageID: "019f7cb5-3858-7000-8000-000000000006",
		AccountID: "019f7cb5-3858-7000-8000-000000000007",
		Action:    "create",
		Username:  "svc-share",
		Password:  secret + "\nZZ",
	}
	err := ApplySambaUser(context.Background(), rec, task)
	if err == nil {
		t.Fatal("expected ApplySambaUser to refuse a password containing a newline")
	}
	if strings.Contains(err.Error(), secret) {
		t.Fatal("refusal message echoed the password")
	}
}

// --- The other half of the oracle: legitimate values still work -------------

func TestApplyAcceptsLegitimateMountTask(t *testing.T) {
	unitDir, _ := redirectUnitDir(t)

	task := legitMountTask(t)
	rec := &mount.RecorderRunner{}
	if err := Apply(context.Background(), rec, nil, task); err != nil {
		t.Fatalf("legitimate mount task was refused: %v", err)
	}
	body, err := os.ReadFile(filepath.Join(unitDir, task.UnitName))
	if err != nil {
		t.Fatalf("expected the unit to be written: %v", err)
	}
	if !strings.Contains(string(body), "Where="+task.MountPath) {
		t.Fatalf("unit body missing Where=: %s", body)
	}
	if len(rec.Invocations) == 0 {
		t.Fatal("expected daemon-reload + start to run for a legitimate task")
	}
}

func TestApplyExportsAcceptsLegitimateTask(t *testing.T) {
	exportsDir, _ := redirectExportsDir(t)

	rec := &mount.RecorderRunner{}
	if err := ApplyExports(context.Background(), rec, legitExportsTask()); err != nil {
		t.Fatalf("legitimate exports task was refused: %v", err)
	}
	entries, _ := os.ReadDir(exportsDir)
	if len(entries) != 1 {
		t.Fatalf("expected exactly one exports file, got %d", len(entries))
	}
}

func TestProvisionGatewayAcceptsLegitimateTask(t *testing.T) {
	unitDir, _ := redirectUnitDir(t)
	exportsParent := t.TempDir()
	orig := EtcExportsPath
	EtcExportsPath = filepath.Join(exportsParent, "exports")
	t.Cleanup(func() { EtcExportsPath = orig })

	task := legitGatewayTask(t)
	rec := &mount.RecorderRunner{}
	if err := ProvisionGateway(context.Background(), rec, task); err != nil {
		t.Fatalf("legitimate gateway task was refused: %v", err)
	}
	if _, err := os.Stat(filepath.Join(unitDir, task.GatewayUnitName)); err != nil {
		t.Fatalf("expected the gateway unit to be written: %v", err)
	}
}

func TestApplyChownAcceptsLegitimatePath(t *testing.T) {
	var invoked [][]string
	orig := runFind
	runFind = func(_ context.Context, args []string) error {
		invoked = append(invoked, args)
		return nil
	}
	t.Cleanup(func() { runFind = orig })

	task := &ChownTask{MountPath: "/var/lib/postgres", OldUID: 70110, NewUID: 70111}
	if err := ApplyChown(context.Background(), task); err != nil {
		t.Fatalf("legitimate chown task was refused: %v", err)
	}
	if len(invoked) != 1 {
		t.Fatalf("expected exactly one find pass, got %d", len(invoked))
	}
}

func TestApplyChownAcceptsAbsentCallbackPath(t *testing.T) {
	orig := runFind
	runFind = func(_ context.Context, _ []string) error { return nil }
	t.Cleanup(func() { runFind = orig })

	// Absent is legal — the handler substitutes the platform default. Pinning
	// this stops the callback rule from being tightened into an outage.
	task := &ChownTask{MountPath: "/var/lib/postgres", OldUID: 1, NewUID: 2, CallbackPath: ""}
	if err := ApplyChown(context.Background(), task); err != nil {
		t.Fatalf("absent callback_path was refused: %v", err)
	}
}

func TestUnapplyRefusesUnitNameEscapingUnitDir(t *testing.T) {
	unitDir, parent := redirectUnitDir(t)
	victim := filepath.Join(parent, "victim.mount")
	if err := os.WriteFile(victim, []byte("[Unit]\n"), 0o644); err != nil {
		t.Fatalf("seed victim unit: %v", err)
	}

	rec := &mount.RecorderRunner{}
	task := &UnmountTask{
		AssignmentID: "019f7cb5-3858-7000-8000-000000000008",
		UnitName:     "../../victim.mount",
		MountPath:    "/srv/data",
	}
	if err := Unapply(context.Background(), rec, task, EncryptionSpec{}, ""); err == nil {
		t.Fatal("expected Unapply to refuse a unit_name that escapes the unit directory")
	}
	if _, err := os.Stat(victim); err != nil {
		t.Fatalf("unit_name escaped the unit directory: %s was removed", victim)
	}
	if len(rec.Invocations) != 0 {
		t.Fatalf("expected systemctl stop never to run, got %+v", rec.Invocations)
	}
	_ = unitDir
}
