package storage

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

var errEBUSY = errors.New("exit status 32: target is busy")

func cifsCredEnvelope(username, password string) string {
	return `{"success":true,"data":{"kind":"cifs_user_pass","username":"` + username + `","password":"` + password + `"}}`
}

func cifsTask(assignmentID, mountPath string, remount bool, previousCredentialIDs ...string) *MountTask {
	return &MountTask{
		AssignmentID:          assignmentID,
		UnitName:              "powernode-storage-test.mount",
		MountPath:             mountPath,
		Recipe:                MountRecipe{Type: "cifs", Source: "//server/share"},
		Credential:            CredentialRef{ID: "new-cred-id", Kind: "cifs_user_pass", URL: "/credential"},
		Remount:               remount,
		PreviousCredentialIDs: previousCredentialIDs,
	}
}

// IMP-e48612a32273 — the whole point of `remount`: a plain `systemctl
// start` on an already-active .mount unit is a no-op, so a rotation's
// rewritten unit/cred file are never picked up without asking for restart
// explicitly.
func TestMountCIFS_RemountCallsRestartNotStart(t *testing.T) {
	dir := t.TempDir()
	orig := MountCredsDir
	MountCredsDir = dir
	defer func() { MountCredsDir = orig }()

	origUnitDir := SystemdUnitDir
	SystemdUnitDir = t.TempDir()
	defer func() { SystemdUnitDir = origUnitDir }()

	rec := &mount.RecorderRunner{}
	client := stubGetter{body: cifsCredEnvelope("n-abc123", "s3cr3t")}
	task := cifsTask("assign-1", t.TempDir(), true)

	confirmed, err := mountCIFS(context.Background(), rec, client, task)
	if err != nil {
		t.Fatalf("mountCIFS returned error: %v", err)
	}
	// Rollout-skew review (arm 1): a genuine restart is ALWAYS confirmed —
	// StorageHandler#Execute reports mounted_credential_id only when this is
	// true, which is how the platform tells "the consumer actually picked
	// this up" from an old agent's no-op start.
	if !confirmed {
		t.Error("expected a restart to be reported as confirmed")
	}

	sawRestart, sawStart := false, false
	for _, inv := range rec.Invocations {
		if inv.Op == "Run" && inv.Name == "systemctl" && len(inv.Args) == 2 {
			switch inv.Args[0] {
			case "restart":
				sawRestart = true
			case "start":
				sawStart = true
			}
		}
	}
	if !sawRestart {
		t.Errorf("expected systemctl restart, invocations: %+v", rec.Invocations)
	}
	if sawStart {
		t.Errorf("expected NO systemctl start on a remount, invocations: %+v", rec.Invocations)
	}
}

// IMP-e48612a32273 — server BLOCKER-adjacent GO ordering guard (review
// asked this be confirmed with a test): the rewritten unit file (carrying
// the NEW credentials= path) must be written and daemon-reload run BEFORE
// the restart is issued — otherwise systemd would restart the unit using
// whatever it had cached from the PREVIOUS unit file/reload.
func TestMountCIFS_WritesUnitAndReloadsBeforeRestarting(t *testing.T) {
	dir := t.TempDir()
	orig := MountCredsDir
	MountCredsDir = dir
	defer func() { MountCredsDir = orig }()

	unitDir := t.TempDir()
	origUnitDir := SystemdUnitDir
	SystemdUnitDir = unitDir
	defer func() { SystemdUnitDir = origUnitDir }()

	rec := &mount.RecorderRunner{}
	client := stubGetter{body: cifsCredEnvelope("n-abc123", "s3cr3t")}
	task := cifsTask("assign-1", t.TempDir(), true)

	if _, err := mountCIFS(context.Background(), rec, client, task); err != nil {
		t.Fatalf("mountCIFS returned error: %v", err)
	}

	reloadIdx, restartIdx := -1, -1
	for i, inv := range rec.Invocations {
		if inv.Op != "Run" || inv.Name != "systemctl" || len(inv.Args) == 0 {
			continue
		}
		switch inv.Args[0] {
		case "daemon-reload":
			reloadIdx = i
		case "restart":
			restartIdx = i
		}
	}
	if reloadIdx == -1 || restartIdx == -1 {
		t.Fatalf("expected both daemon-reload and restart, invocations: %+v", rec.Invocations)
	}
	if reloadIdx >= restartIdx {
		t.Fatalf("expected daemon-reload (index %d) BEFORE restart (index %d)", reloadIdx, restartIdx)
	}

	// The unit file on disk must already carry the NEW credentials= path by
	// the time daemon-reload/restart run — mountCIFS returning success
	// alone doesn't prove the write happened before the reload, only that
	// it happened at all.
	unitBytes, err := os.ReadFile(filepath.Join(unitDir, task.UnitName))
	if err != nil {
		t.Fatalf("read written unit file: %v", err)
	}
	if !strings.Contains(string(unitBytes), filepath.Join(dir, "new-cred-id.cred")) {
		t.Errorf("expected unit file to reference the new cred file path, got:\n%s", unitBytes)
	}
}

// Plural cleanup (rework hole (b), review correction): a rotate-rotate-
// confirm sequence can leave MORE than one stale cred file behind — every
// id in PreviousCredentialIDs must be removed on a successful restart, not
// just the first/last one.
func TestMountCIFS_SuccessfulRemountRemovesAllPreviousCredFiles(t *testing.T) {
	dir := t.TempDir()
	orig := MountCredsDir
	MountCredsDir = dir
	defer func() { MountCredsDir = orig }()

	origUnitDir := SystemdUnitDir
	SystemdUnitDir = t.TempDir()
	defer func() { SystemdUnitDir = origUnitDir }()

	oldPath1 := filepath.Join(dir, "old-cred-id-1.cred")
	oldPath2 := filepath.Join(dir, "old-cred-id-2.cred")
	for _, p := range []string{oldPath1, oldPath2} {
		if err := os.WriteFile(p, []byte("stale"), 0o600); err != nil {
			t.Fatalf("seed old cred file %s: %v", p, err)
		}
	}

	rec := &mount.RecorderRunner{}
	client := stubGetter{body: cifsCredEnvelope("n-abc123", "s3cr3t")}
	task := cifsTask("assign-1", t.TempDir(), true, "old-cred-id-1", "old-cred-id-2")

	if _, err := mountCIFS(context.Background(), rec, client, task); err != nil {
		t.Fatalf("mountCIFS returned error: %v", err)
	}

	for _, p := range []string{oldPath1, oldPath2} {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Errorf("expected %s to be removed; stat error: %v", p, err)
		}
	}
	newPath := filepath.Join(dir, "new-cred-id.cred")
	if _, err := os.Stat(newPath); err != nil {
		t.Errorf("expected new cred file to exist: %v", err)
	}
}

// The regression guard for the above: a NON-remount (the ordinary
// first-mount case, Remount left at its zero value) must still use start,
// never restart — restarting every first mount would add EBUSY risk with
// no benefit and is not what this task changed.
func TestMountCIFS_FirstMountCallsStartNotRestart(t *testing.T) {
	dir := t.TempDir()
	orig := MountCredsDir
	MountCredsDir = dir
	defer func() { MountCredsDir = orig }()

	origUnitDir := SystemdUnitDir
	SystemdUnitDir = t.TempDir()
	defer func() { SystemdUnitDir = origUnitDir }()

	rec := &mount.RecorderRunner{}
	client := stubGetter{body: cifsCredEnvelope("n-abc123", "s3cr3t")}
	task := cifsTask("assign-1", t.TempDir(), false)

	// RecorderRunner defaults `systemctl is-active` to empty output/no
	// error — IsActive reads that as "not active" — so this exercises the
	// genuine "started from inactive" arm without an explicit stub.
	confirmed, err := mountCIFS(context.Background(), rec, client, task)
	if err != nil {
		t.Fatalf("mountCIFS returned error: %v", err)
	}
	// Rollout-skew review (arm 2): starting a genuinely INACTIVE unit is
	// confirmed — the consumer really did pick up this credential.
	if !confirmed {
		t.Error("expected starting an inactive unit to be reported as confirmed")
	}

	sawRestart, sawStart := false, false
	for _, inv := range rec.Invocations {
		if inv.Op == "Run" && inv.Name == "systemctl" && len(inv.Args) == 2 {
			switch inv.Args[0] {
			case "restart":
				sawRestart = true
			case "start":
				sawStart = true
			}
		}
	}
	if !sawStart {
		t.Errorf("expected systemctl start, invocations: %+v", rec.Invocations)
	}
	if sawRestart {
		t.Errorf("expected NO systemctl restart on a first mount, invocations: %+v", rec.Invocations)
	}
}

// Rollout-skew review (arm 3) — the exact old-agent failure mode: `start`
// on a unit that's ALREADY active is a no-op. mountCIFS must recognize this
// (via the PRIOR is-active check) and report it unconfirmed — the caller
// (StorageHandler#Execute) uses this to send `already_active: true` with NO
// credential id, rather than falsely claiming the consumer picked up
// whatever credential this task named.
func TestMountCIFS_StartOnAlreadyActiveUnitIsNotConfirmed(t *testing.T) {
	dir := t.TempDir()
	orig := MountCredsDir
	MountCredsDir = dir
	defer func() { MountCredsDir = orig }()

	origUnitDir := SystemdUnitDir
	SystemdUnitDir = t.TempDir()
	defer func() { SystemdUnitDir = origUnitDir }()

	rec := &mount.RecorderRunner{
		StubOutput: map[string][]byte{
			"systemctl is-active powernode-storage-test.mount": []byte("active\n"),
		},
	}
	client := stubGetter{body: cifsCredEnvelope("n-abc123", "s3cr3t")}
	task := cifsTask("assign-1", t.TempDir(), false)

	confirmed, err := mountCIFS(context.Background(), rec, client, task)
	if err != nil {
		t.Fatalf("mountCIFS returned error: %v", err)
	}
	if confirmed {
		t.Error("expected start on an already-active unit to be reported UNCONFIRMED")
	}

	sawStart := false
	for _, inv := range rec.Invocations {
		if inv.Op == "Run" && inv.Name == "systemctl" && len(inv.Args) == 2 && inv.Args[0] == "start" {
			sawStart = true
		}
	}
	if !sawStart {
		t.Errorf("expected systemctl start to still be called (the no-op itself), invocations: %+v", rec.Invocations)
	}
}

// Old cred file is removed ONLY once the restart actually succeeds.
func TestMountCIFS_SuccessfulRemountRemovesOldCredFile(t *testing.T) {
	dir := t.TempDir()
	orig := MountCredsDir
	MountCredsDir = dir
	defer func() { MountCredsDir = orig }()

	origUnitDir := SystemdUnitDir
	SystemdUnitDir = t.TempDir()
	defer func() { SystemdUnitDir = origUnitDir }()

	oldPath := filepath.Join(dir, "old-cred-id.cred")
	if err := os.WriteFile(oldPath, []byte("stale"), 0o600); err != nil {
		t.Fatalf("seed old cred file: %v", err)
	}

	rec := &mount.RecorderRunner{}
	client := stubGetter{body: cifsCredEnvelope("n-abc123", "s3cr3t")}
	task := cifsTask("assign-1", t.TempDir(), true, "old-cred-id")

	if _, err := mountCIFS(context.Background(), rec, client, task); err != nil {
		t.Fatalf("mountCIFS returned error: %v", err)
	}

	if _, err := os.Stat(oldPath); !os.IsNotExist(err) {
		t.Errorf("expected old cred file to be removed; stat error: %v", err)
	}
	newPath := filepath.Join(dir, "new-cred-id.cred")
	if _, err := os.Stat(newPath); err != nil {
		t.Errorf("expected new cred file to exist: %v", err)
	}
}

// IMP-e48612a32273 (a) / red-first for the failure mode: when the restart
// itself fails (simulating EBUSY — an open fd/cwd/mmap under the mount),
// BOTH the old and new credential files must remain. Never a lazy or
// forced cleanup on failure — the old mount, if still active, keeps
// working on its existing session.
func TestMountCIFS_FailedRemountKeepsBothCredFiles(t *testing.T) {
	dir := t.TempDir()
	orig := MountCredsDir
	MountCredsDir = dir
	defer func() { MountCredsDir = orig }()

	origUnitDir := SystemdUnitDir
	SystemdUnitDir = t.TempDir()
	defer func() { SystemdUnitDir = origUnitDir }()

	oldPath := filepath.Join(dir, "old-cred-id.cred")
	if err := os.WriteFile(oldPath, []byte("stale"), 0o600); err != nil {
		t.Fatalf("seed old cred file: %v", err)
	}

	rec := &mount.RecorderRunner{
		StubErr: map[string]error{
			"systemctl restart powernode-storage-test.mount": errEBUSY,
		},
	}
	client := stubGetter{body: cifsCredEnvelope("n-abc123", "s3cr3t")}
	task := cifsTask("assign-1", t.TempDir(), true, "old-cred-id")

	// Rollout-skew review (arm 4): a failure never claims confirmation —
	// StorageHandler#Execute never even reaches the result-builder on a
	// non-nil error (the task is reported failed, not completed), but the
	// zero-value `false` here documents that EBUSY/failure can never be
	// mistaken for a successful (re)start regardless.
	confirmed, err := mountCIFS(context.Background(), rec, client, task)
	if err == nil {
		t.Fatal("expected mountCIFS to return the restart error")
	}
	if confirmed {
		t.Error("expected a failed restart to never report confirmed")
	}

	if _, err := os.Stat(oldPath); err != nil {
		t.Errorf("expected old cred file to remain on failure: %v", err)
	}
	newPath := filepath.Join(dir, "new-cred-id.cred")
	if _, err := os.Stat(newPath); err != nil {
		t.Errorf("expected new cred file to still exist: %v", err)
	}
}
