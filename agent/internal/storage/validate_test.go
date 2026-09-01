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
			// The REAL wire value. Sdwan::PrefixAllocator.compose_address_128
			// stamps a /128 on every peer address, and it reaches the payload
			// unmodified via Peer#assigned_address -> CredentialIssuer. A bare
			// "fd00::1" here is a fixture no producer emits.
			{PeerIP: "fd00::abcd/128", UID: 100100, GID: 100100, Options: []string{"rw", "sync", "no_subtree_check"}},
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
	// The prefix is kept correct so this example isolates the SUFFIX rule.
	task.UnitName = mountUnitPrefix + "rails.service"

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
// The suffix rule alone leaves the sharpest case open: persist.mount and
// sysroot.mount are REAL units on these nodes, they end in ".mount", and
// storage.unmount would `systemctl stop` one and delete its unit file — taking
// out the agent's own durable state. systemd.go's comment already claimed the
// prefix invariant; only now is it enforced.
func TestApplyRefusesUnitNameWithoutThePlatformPrefix(t *testing.T) {
	unitDir, _ := redirectUnitDir(t)

	for _, name := range []string{"persist.mount", "sysroot.mount", "var-lib-powernode.mount"} {
		task := legitMountTask(t)
		task.UnitName = name

		rec := &mount.RecorderRunner{}
		if err := Apply(context.Background(), rec, nil, task); !errors.Is(err, taskguard.ErrRefused) {
			t.Fatalf("expected a refusal for unprefixed unit_name %q, got %v", name, err)
		}
		if entries, _ := os.ReadDir(unitDir); len(entries) != 0 {
			t.Fatalf("expected no unit written for %q, got %d entries", name, len(entries))
		}
		if len(rec.Invocations) != 0 {
			t.Fatalf("expected no actuation for %q, got %+v", name, rec.Invocations)
		}
	}
}

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

// The LAN-fallback shape, pinned as ACCEPTED. TaskPayloadBuilder#requires_wg?
// returns true for every non-object recipe while #wg_interface_hint returns
// nil whenever sdwan_network_id is nil, and that association is optional with
// on_delete: :nullify — so this exact combination is what the platform sends
// for an NFS assignment on a node with no SDWAN network.
//
// An earlier revision refused it. Because the reconciler re-dispatches
// storage.mount on drift, that would not have failed at deploy: it would have
// put every LAN-fallback assignment into permanent backoff at the next sweep,
// with a clean-looking rollout.
func TestApplyAcceptsRequiresWGWithNoInterfaceHint(t *testing.T) {
	unitDir, _ := redirectUnitDir(t)

	task := legitMountTask(t)
	task.RequiresWGInterface = true
	task.WGInterfaceHint = ""

	rec := &mount.RecorderRunner{}
	if err := Apply(context.Background(), rec, nil, task); err != nil {
		t.Fatalf("the LAN-fallback mount shape was refused: %v", err)
	}
	body, err := os.ReadFile(filepath.Join(unitDir, task.UnitName))
	if err != nil {
		t.Fatalf("expected the unit to be written: %v", err)
	}
	if strings.Contains(string(body), "Requires=") {
		t.Fatalf("expected no tunnel dependency when the hint is absent:\n%s", body)
	}
}

// A credential id is REQUIRED for the recipes that stage a credential file:
// an empty one collapses every assignment onto the same predictable filename
// under /run/sdwan/mount-creds, so one tenant's secret overwrites another's.
func TestApplyRefusesCredentialFileRecipeWithNoCredentialID(t *testing.T) {
	redirectUnitDir(t)

	task := legitMountTask(t)
	task.Recipe.Type = "cifs"
	task.Credential.ID = ""

	rec := &mount.RecorderRunner{}
	if err := Apply(context.Background(), rec, nil, task); !errors.Is(err, taskguard.ErrRefused) {
		t.Fatalf("expected a refusal for a cifs mount with no credential id, got %v", err)
	}
	if len(rec.Invocations) != 0 {
		t.Fatalf("expected no actuation after refusal, got %+v", rec.Invocations)
	}
}

// ...and NOT required for nfs4, which uses a peer-IP ACL and legitimately
// carries none.
func TestApplyAcceptsNFSMountWithNoCredentialID(t *testing.T) {
	redirectUnitDir(t)

	task := legitMountTask(t)
	task.Credential = CredentialRef{}

	rec := &mount.RecorderRunner{}
	if err := Apply(context.Background(), rec, nil, task); err != nil {
		t.Fatalf("an nfs4 mount with no credential id was refused: %v", err)
	}
}

func TestApplySambaUserRefusesCreateWithNoPassword(t *testing.T) {
	rec := &mount.RecorderRunner{}
	task := &SmbUserApplyTask{
		StorageID: "019f7cb5-3858-7000-8000-000000000006",
		AccountID: "019f7cb5-3858-7000-8000-000000000007",
		Action:    "create",
		Username:  "svc-share",
		Password:  "",
	}
	// smb_user.go passes the password positionally, so an empty one
	// provisions a share principal with no password at all.
	if err := ApplySambaUser(context.Background(), rec, task); !errors.Is(err, taskguard.ErrRefused) {
		t.Fatalf("expected a refusal for a create with no password, got %v", err)
	}
	if len(rec.Invocations) != 0 {
		t.Fatalf("expected samba-tool never to run, got %+v", rec.Invocations)
	}
}

// --- The producer-contract half of the oracle --------------------------------
//
// Validate() only, no filesystem: these are values the platform's own
// producers emit, taken from System::Storage::MountPathInferenceService (the
// table of supported StorageAssignment mount paths), the shipped gateway smoke
// seed, and StorageAssignment's model-level format. Every one of them was
// refused by an earlier revision of this file. A rule-level mutation oracle
// cannot see a producer-contract mismatch; only fixtures taken FROM the
// producer can.
func TestValidateAcceptsSupportedMountPaths(t *testing.T) {
	supported := []string{
		"/var/lib/powernode/storage/smoke-gateway", // db/seeds/smoke_test_storage_assignment_gateway.rb
		"/var/lib/postgres",                        // MountPathInferenceService, service_user
		"/etc/nginx",                               // MountPathInferenceService, service_user "nginx"
		"/etc/traefik",                             // MountPathInferenceService, service_user "traefik"
		"/etc/someapp",                             // MountPathInferenceService, :root
		"/boot/firmware",                           // MountPathInferenceService, :root
		"/var/www",                                 // MountPathInferenceService, "www-data"
		"/var/log/nginx",
		"/home/pnadmin/share", // MountPathInferenceService, :operator
		"/srv/exports/data",
		"/tmp/scratch",
		"/srv/data/", // a trailing slash is legal under the model's own format
	}
	for _, p := range supported {
		task := &MountTask{
			AssignmentID: "019f7cb5-3858-7000-8000-000000000001",
			UnitName:     mountUnitPrefix + "x.mount",
			MountPath:    p,
			Recipe:       MountRecipe{Type: "nfs4", Source: "fd00::1:/srv/exports/data"},
			Encryption:   EncryptionSpec{Mode: "none"},
		}
		if err := task.Validate(); err != nil {
			t.Errorf("supported mount_path %q was refused: %v", p, err)
		}
	}
}

// The headline case must survive the carve-out above: the root ITSELF, and any
// ancestor of it, is still refused even though its subtree is now usable.
func TestValidateStillRefusesTheRootsThemselves(t *testing.T) {
	for _, p := range []string{"/", "/etc", "/boot", "/var/lib/powernode", "/usr/local/bin", "/var", "/var/lib"} {
		task := &ChownTask{MountPath: p, OldUID: 0, NewUID: 1000}
		if err := task.Validate(); !errors.Is(err, taskguard.ErrRefused) {
			t.Errorf("expected %q to stay refused, got %v", p, err)
		}
	}
}

func TestValidateAcceptsRealPeerAddresses(t *testing.T) {
	task := legitExportsTask()
	for _, addr := range []string{"fd00::abcd/128", "fd00::1", "10.125.0.227", "10.0.0.0/24"} {
		task.Entries[0].PeerIP = addr
		if err := task.Validate(); err != nil {
			t.Errorf("peer_ip %q was refused: %v", addr, err)
		}
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

// A SPACE is the field separator in /etc/exports, so this "path" is really two
// fields: the rendered line exports /etc to the world, rw, no_root_squash,
// while every whole-string prefix comparison still sees one tidy path. The
// critical-root denylist cannot catch it; only the no-space rule can.
func TestApplyExportsRefusesExportPathContainingASpace(t *testing.T) {
	exportsDir, _ := redirectExportsDir(t)

	task := legitExportsTask()
	task.ExportPath = "/etc 0.0.0.0/0(rw,no_root_squash,no_subtree_check)"

	rec := &mount.RecorderRunner{}
	if err := ApplyExports(context.Background(), rec, task); !errors.Is(err, taskguard.ErrRefused) {
		t.Fatalf("expected a refusal for an export_path containing a space, got %v", err)
	}
	entries, _ := os.ReadDir(exportsDir)
	for _, e := range entries {
		body, _ := os.ReadFile(filepath.Join(exportsDir, e.Name()))
		if strings.Contains(string(body), "no_root_squash") {
			t.Fatalf("a world-writable export line was written:\n%s", body)
		}
	}
	if len(entries) != 0 {
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
	// Redirect /etc/exports as well. Without this the test leans on an
	// incidental EACCES when the suite runs non-root — which reads exactly
	// like a refusal — and, if the guard ever regressed under a root runner,
	// it would splice a line into the node's REAL export table.
	redirectEtcExports(t)

	task := legitGatewayTask(t)
	task.ReExportPath = "/etc"

	rec := &mount.RecorderRunner{}
	if err := ProvisionGateway(context.Background(), rec, task); !errors.Is(err, taskguard.ErrRefused) {
		t.Fatalf("expected a refusal for re_export_path /etc, got %v", err)
	}
	if entries, _ := os.ReadDir(unitDir); len(entries) != 0 {
		t.Fatalf("expected no unit written, got %d entries", len(entries))
	}
}

// A symlinked target defeats every textual denylist: filepath.Clean does not
// resolve links, and /var/run is a symlink to /run on every systemd distro.
// exportfs and mount both resolve, so the node would export the real tree.
func TestProvisionGatewayRefusesSymlinkedPathResolvingIntoACriticalRoot(t *testing.T) {
	redirectUnitDir(t)
	redirectEtcExports(t)

	dir := t.TempDir()
	link := filepath.Join(dir, "innocuous")
	if err := os.Symlink("/run", link); err != nil {
		t.Skipf("cannot create symlink: %v", err)
	}

	task := legitGatewayTask(t)
	task.ReExportPath = filepath.Join(link, "sdwan")

	rec := &mount.RecorderRunner{}
	if err := ProvisionGateway(context.Background(), rec, task); !errors.Is(err, taskguard.ErrRefused) {
		t.Fatalf("expected a refusal for a path resolving into /run, got %v", err)
	}
	if len(rec.Invocations) != 0 {
		t.Fatalf("expected no actuation after refusal, got %+v", rec.Invocations)
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

func redirectEtcExports(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "exports")
	orig := EtcExportsPath
	EtcExportsPath = path
	t.Cleanup(func() { EtcExportsPath = orig })
	return path
}

func TestProvisionGatewayAcceptsLegitimateTask(t *testing.T) {
	unitDir, _ := redirectUnitDir(t)
	redirectEtcExports(t)

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
