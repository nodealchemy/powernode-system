package migration

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// TestMain sandboxes the mount package's filesystem seam for the WHOLE
// package: ReconcileStorageVolume ensureDirs server-supplied absolute mount
// points (/var/lib/postgresql), which on a non-root dev box fails EACCES
// (path absent, /var/lib unwritable) and in root CI silently creates real
// directories. Neither belongs in a unit test (IMP-ae2160046005).
func TestMain(m *testing.M) {
	restore := mount.SetMkdirAllForTest(func(string, os.FileMode) error { return nil })
	code := m.Run()
	restore()
	os.Exit(code)
}

// fakeClient is a stand-in for transport.Client that records POSTs and
// returns canned GET responses keyed by path.
type fakeClient struct {
	GetResponses  map[string]string // path → JSON envelope
	PostInvocations []postInvocation
	PostError       error
}

type postInvocation struct {
	Path string
	Body map[string]any
}

func (f *fakeClient) GetJSON(path string) (*http.Response, error) {
	body, ok := f.GetResponses[path]
	if !ok {
		return nil, errors.New("no canned response for " + path)
	}
	return &http.Response{
		StatusCode: 200,
		Body:       io.NopCloser(strings.NewReader(body)),
	}, nil
}

func (f *fakeClient) PostJSON(path string, body []byte) (*http.Response, error) {
	if f.PostError != nil {
		return nil, f.PostError
	}
	asMap := map[string]any{}
	_ = json.Unmarshal(body, &asMap)
	f.PostInvocations = append(f.PostInvocations, postInvocation{Path: path, Body: asMap})
	return &http.Response{
		StatusCode: 200,
		Body:       io.NopCloser(bytes.NewReader([]byte(`{"success":true,"data":{}}`))),
	}, nil
}

func TestRunner_NoMigrations_NoOp(t *testing.T) {
	c := &fakeClient{GetResponses: map[string]string{
		"/api/v1/system/node_api/storage_migrations": `{"success":true,"data":{"storage_migrations":[]}}`,
	}}
	r := &Runner{Client: c, MountRunner: &mount.RecorderRunner{}}
	if err := r.Tick(context.Background()); err != nil {
		t.Fatalf("tick failed: %v", err)
	}
	if len(c.PostInvocations) != 0 {
		t.Fatalf("expected zero post invocations, got %d", len(c.PostInvocations))
	}
}

func TestRunner_ApprovedMigration_AdvancesToPreparing(t *testing.T) {
	payload := `{"success":true,"data":{"storage_migrations":[{
		"id":"mig-1","status":"approved","role":"postgres",
		"source_subpath":"deployments/x/postgres",
		"target_subpath":"deployments/x/postgres",
		"plan":{"agent_contract":{"v":1}},
		"source_binding":{
			"volume_id":"vol-src","transport":"nfs","mount_type":"nfs",
			"mount_point":"/tmp/mig-src","role":"postgres",
			"subpath":"deployments/x/postgres",
			"nfs":{"server":"src.dsm","export_path":"/v1/Powernode","mount_options":"nfsvers=4.1,hard","subpath":"deployments/x/postgres"}
		},
		"target_binding":{
			"volume_id":"vol-tgt","transport":"nfs","mount_type":"nfs",
			"mount_point":"/tmp/mig-tgt","role":"postgres",
			"subpath":"deployments/x/postgres",
			"nfs":{"server":"tgt.dsm","export_path":"/v2/Powernode","mount_options":"nfsvers=4.1,hard","subpath":"deployments/x/postgres"}
		}
	}]}}`

	c := &fakeClient{GetResponses: map[string]string{
		"/api/v1/system/node_api/storage_migrations": payload,
	}}
	rec := &mount.RecorderRunner{}
	r := &Runner{Client: c, MountRunner: rec}

	if err := r.Tick(context.Background()); err != nil {
		t.Fatalf("tick failed: %v", err)
	}

	// Expect ≥2 mount invocations (one per binding) + a status report.
	mountCount := 0
	for _, inv := range rec.Invocations {
		if inv.Name == "mount" {
			mountCount++
		}
	}
	if mountCount < 2 {
		t.Fatalf("expected ≥2 mount calls, got %d (invocations: %+v)", mountCount, rec.Invocations)
	}

	if len(c.PostInvocations) != 1 {
		t.Fatalf("expected 1 post invocation, got %d", len(c.PostInvocations))
	}
	got := c.PostInvocations[0]
	if !strings.Contains(got.Path, "/storage_migrations/mig-1/progress") {
		t.Fatalf("expected progress path, got %q", got.Path)
	}
	if got.Body["status"] != "preparing" {
		t.Fatalf("expected status=preparing, got %v", got.Body["status"])
	}
}

func TestRunner_SyncingMigration_RunsRsyncAndAdvances(t *testing.T) {
	payload := `{"success":true,"data":{"storage_migrations":[{
		"id":"mig-2","status":"syncing","role":"postgres",
		"source_subpath":"deployments/x/postgres",
		"target_subpath":"deployments/x/postgres",
		"plan":{},
		"source_binding":{"volume_id":"s","transport":"nfs","mount_point":"/tmp/sm-src","nfs":{"server":"a","export_path":"/x"}},
		"target_binding":{"volume_id":"t","transport":"nfs","mount_point":"/tmp/sm-tgt","nfs":{"server":"b","export_path":"/y"}}
	}]}}`

	c := &fakeClient{GetResponses: map[string]string{
		"/api/v1/system/node_api/storage_migrations": payload,
	}}
	rec := &mount.RecorderRunner{}
	r := &Runner{Client: c, MountRunner: rec}

	if err := r.Tick(context.Background()); err != nil {
		t.Fatalf("tick failed: %v", err)
	}

	// Look for the rsync invocation.
	var sawRsync bool
	for _, inv := range rec.Invocations {
		if inv.Name == "rsync" {
			joined := strings.Join(inv.Args, " ")
			if strings.Contains(joined, "/tmp/sm-src/") && strings.Contains(joined, "/tmp/sm-tgt/") {
				sawRsync = true
			}
		}
	}
	if !sawRsync {
		t.Fatalf("expected rsync src→dst invocation; got %+v", rec.Invocations)
	}

	// Expect verifying transition (syncing → verifying after rsync ok).
	var sawVerifying bool
	for _, p := range c.PostInvocations {
		if p.Body["status"] == "verifying" {
			sawVerifying = true
		}
	}
	if !sawVerifying {
		t.Fatalf("expected verifying transition; got posts=%+v", c.PostInvocations)
	}
}

func TestRunner_VerifyingMigration_AdvancesToCutover(t *testing.T) {
	payload := `{"success":true,"data":{"storage_migrations":[{
		"id":"mig-3","status":"verifying",
		"source_binding":{"volume_id":"s","mount_point":"/tmp/v-src"},
		"target_binding":{"volume_id":"t","mount_point":"/tmp/v-tgt"}
	}]}}`

	c := &fakeClient{GetResponses: map[string]string{
		"/api/v1/system/node_api/storage_migrations": payload,
	}}
	rec := &mount.RecorderRunner{}
	r := &Runner{Client: c, MountRunner: rec}

	if err := r.Tick(context.Background()); err != nil {
		t.Fatalf("tick failed: %v", err)
	}

	// Verifying runs an rsync --checksum --dry-run.
	var sawCheckRsync bool
	for _, inv := range rec.Invocations {
		if inv.Name == "rsync" {
			joined := strings.Join(inv.Args, " ")
			if strings.Contains(joined, "--checksum") && strings.Contains(joined, "--dry-run") {
				sawCheckRsync = true
			}
		}
	}
	if !sawCheckRsync {
		t.Fatalf("expected verify rsync --checksum --dry-run; got %+v", rec.Invocations)
	}

	if c.PostInvocations[0].Body["status"] != "cutover" {
		t.Fatalf("expected cutover transition, got %v", c.PostInvocations[0].Body)
	}
}

func TestRunner_CutoverFallback_NoCoordination(t *testing.T) {
	// No consumer_mount_point + no consumer_units → fallback: just
	// umount the source scratch and report completed.
	payload := `{"success":true,"data":{"storage_migrations":[{
		"id":"mig-4","status":"cutover",
		"source_binding":{"volume_id":"s","mount_point":"/tmp/co-src"},
		"target_binding":{"volume_id":"t","mount_point":"/tmp/co-tgt"}
	}]}}`

	c := &fakeClient{GetResponses: map[string]string{
		"/api/v1/system/node_api/storage_migrations": payload,
	}}
	rec := &mount.RecorderRunner{}
	r := &Runner{Client: c, MountRunner: rec}

	if err := r.Tick(context.Background()); err != nil {
		t.Fatalf("tick failed: %v", err)
	}

	var sawUmount bool
	for _, inv := range rec.Invocations {
		if inv.Name == "umount" && len(inv.Args) == 1 && inv.Args[0] == "/tmp/co-src" {
			sawUmount = true
		}
	}
	if !sawUmount {
		t.Fatalf("expected umount /tmp/co-src; got %+v", rec.Invocations)
	}
	if c.PostInvocations[0].Body["status"] != "completed" {
		t.Fatalf("expected completed transition, got %v", c.PostInvocations[0].Body)
	}
}

func TestRunner_CutoverFullCoordination_StopRemountStart(t *testing.T) {
	payload := `{"success":true,"data":{"storage_migrations":[{
		"id":"mig-5","status":"cutover",
		"role":"postgres",
		"consumer_mount_point":"/var/lib/postgresql",
		"consumer_units":["postgresql.service"],
		"source_binding":{"volume_id":"s","transport":"nfs","mount_point":"/tmp/full-src","nfs":{"server":"a","export_path":"/x"}},
		"target_binding":{"volume_id":"t","transport":"nfs","mount_point":"/tmp/full-tgt","nfs":{"server":"b","export_path":"/y","subpath":"deployments/x/postgres"},"subpath":"deployments/x/postgres"}
	}]}}`

	c := &fakeClient{GetResponses: map[string]string{
		"/api/v1/system/node_api/storage_migrations": payload,
	}}
	rec := &mount.RecorderRunner{}
	r := &Runner{Client: c, MountRunner: rec}

	if err := r.Tick(context.Background()); err != nil {
		t.Fatalf("tick failed: %v", err)
	}

	// Verify the recorded shell-out sequence contains the key
	// transitions, in order:
	//   systemctl stop postgresql.service
	//   (possibly umount /var/lib/postgresql; only if mounted)
	//   mount -t nfs ... /var/lib/postgresql
	//   systemctl start postgresql.service
	//   umount of scratch paths
	var stopIdx, mountCanonIdx, startIdx int = -1, -1, -1
	for i, inv := range rec.Invocations {
		switch {
		case inv.Name == "systemctl" && len(inv.Args) >= 2 && inv.Args[0] == "stop" && inv.Args[1] == "postgresql.service":
			stopIdx = i
		case inv.Name == "mount" && inv.Op == "Run":
			joined := strings.Join(inv.Args, " ")
			if strings.Contains(joined, "/var/lib/postgresql") && strings.Contains(joined, "-t nfs") {
				mountCanonIdx = i
			}
		case inv.Name == "systemctl" && len(inv.Args) >= 2 && inv.Args[0] == "start" && inv.Args[1] == "postgresql.service":
			startIdx = i
		}
	}
	if stopIdx < 0 {
		t.Fatalf("expected systemctl stop postgresql.service; got %+v", rec.Invocations)
	}
	if mountCanonIdx < 0 {
		t.Fatalf("expected mount -t nfs at /var/lib/postgresql; got %+v", rec.Invocations)
	}
	if startIdx < 0 {
		t.Fatalf("expected systemctl start postgresql.service; got %+v", rec.Invocations)
	}
	if !(stopIdx < mountCanonIdx && mountCanonIdx < startIdx) {
		t.Fatalf("expected ordering stop<mount<start; got stop=%d mount=%d start=%d", stopIdx, mountCanonIdx, startIdx)
	}

	if c.PostInvocations[0].Body["status"] != "completed" {
		t.Fatalf("expected completed transition, got %v", c.PostInvocations[0].Body)
	}
}

// === Increment 9 — revert_binding! (R) / cleanup (C) =======================

func TestRunner_RevertRequested_RemountsSourceAtCanonical(t *testing.T) {
	// status is "failed" (terminal) — the normal switch would no-op on
	// this; RevertRequested must be checked BEFORE the status switch.
	payload := `{"success":true,"data":{"storage_migrations":[{
		"id":"mig-r1","status":"failed",
		"revert_requested":true,
		"consumer_mount_point":"/var/lib/postgresql",
		"consumer_units":["postgresql.service"],
		"source_binding":{"volume_id":"s","transport":"nfs","mount_point":"/tmp/rev-src","nfs":{"server":"a","export_path":"/x","full_export_path":"a:/x/deployments/foo/postgres"}},
		"target_binding":{"volume_id":"t","transport":"nfs","mount_point":"/tmp/rev-tgt","nfs":{"server":"b","export_path":"/y"}}
	}]}}`

	c := &fakeClient{GetResponses: map[string]string{
		"/api/v1/system/node_api/storage_migrations": payload,
	}}
	rec := &mount.RecorderRunner{}
	r := &Runner{Client: c, MountRunner: rec}

	if err := r.Tick(context.Background()); err != nil {
		t.Fatalf("tick failed: %v", err)
	}

	var stopIdx, mountCanonIdx, startIdx int = -1, -1, -1
	for i, inv := range rec.Invocations {
		switch {
		case inv.Name == "systemctl" && len(inv.Args) >= 2 && inv.Args[0] == "stop" && inv.Args[1] == "postgresql.service":
			stopIdx = i
		case inv.Name == "mount" && inv.Op == "Run":
			joined := strings.Join(inv.Args, " ")
			if strings.Contains(joined, "/var/lib/postgresql") {
				mountCanonIdx = i
			}
		case inv.Name == "systemctl" && len(inv.Args) >= 2 && inv.Args[0] == "start" && inv.Args[1] == "postgresql.service":
			startIdx = i
		}
	}
	if stopIdx < 0 || mountCanonIdx < 0 || startIdx < 0 {
		t.Fatalf("expected stop→mount(source)→start sequence; got %+v", rec.Invocations)
	}
	if !(stopIdx < mountCanonIdx && mountCanonIdx < startIdx) {
		t.Fatalf("expected ordering stop<mount<start; got stop=%d mount=%d start=%d", stopIdx, mountCanonIdx, startIdx)
	}
	// Never touches the target binding's mount point — revert must
	// never remount target while reverting to source.
	for _, inv := range rec.Invocations {
		joined := strings.Join(inv.Args, " ")
		if strings.Contains(joined, "/tmp/rev-tgt") {
			t.Fatalf("revert must not touch target_binding; got %+v", inv)
		}
	}

	if len(c.PostInvocations) != 1 {
		t.Fatalf("expected 1 post invocation, got %d", len(c.PostInvocations))
	}
	got := c.PostInvocations[0]
	if !strings.Contains(got.Path, "/storage_migrations/mig-r1/revert_complete") {
		t.Fatalf("expected revert_complete path, got %q", got.Path)
	}
	if got.Body["status"] != "completed" {
		t.Fatalf("expected status=completed, got %v", got.Body["status"])
	}
}

func TestRunner_RevertRequested_NoCoordination_ReportsNothingToRevert(t *testing.T) {
	payload := `{"success":true,"data":{"storage_migrations":[{
		"id":"mig-r2","status":"failed",
		"revert_requested":true,
		"source_binding":{"volume_id":"s","mount_point":"/tmp/rev2-src"}
	}]}}`

	c := &fakeClient{GetResponses: map[string]string{
		"/api/v1/system/node_api/storage_migrations": payload,
	}}
	rec := &mount.RecorderRunner{}
	r := &Runner{Client: c, MountRunner: rec}

	if err := r.Tick(context.Background()); err != nil {
		t.Fatalf("tick failed: %v", err)
	}
	if len(c.PostInvocations) != 1 {
		t.Fatalf("expected 1 post invocation, got %d", len(c.PostInvocations))
	}
	if !strings.Contains(c.PostInvocations[0].Path, "/revert_complete") {
		t.Fatalf("expected revert_complete path, got %q", c.PostInvocations[0].Path)
	}
	if c.PostInvocations[0].Body["status"] != "completed" {
		t.Fatalf("expected completed status even with no coordination, got %v", c.PostInvocations[0].Body)
	}
}

func TestRunner_CleanupRequested_DeletesTargetAndSnapshotOnly(t *testing.T) {
	// status is "cancelled" (terminal) — again, CleanupRequested must
	// preempt the status switch.
	payload := `{"success":true,"data":{"storage_migrations":[{
		"id":"mig-c1","status":"cancelled",
		"cleanup_requested":true,
		"source_binding":{"volume_id":"s","transport":"nfs","mount_point":"/tmp/cln-src","subpath":"deployments/x/postgres","nfs":{"server":"a","export_path":"/x","subpath":"deployments/x/postgres"}},
		"target_binding":{"volume_id":"t","transport":"nfs","mount_point":"/tmp/cln-tgt","subpath":"deployments/x/postgres","nfs":{"server":"b","export_path":"/y","subpath":"deployments/x/postgres"}},
		"snapshot_binding":{"volume_id":"t","transport":"nfs","mount_point":"/tmp/cln-snap","subpath":"migrations/x/postgres","nfs":{"server":"b","export_path":"/y","subpath":"migrations/x/postgres"}}
	}]}}`

	c := &fakeClient{GetResponses: map[string]string{
		"/api/v1/system/node_api/storage_migrations": payload,
	}}
	rec := &mount.RecorderRunner{}
	r := &Runner{Client: c, MountRunner: rec}

	if err := r.Tick(context.Background()); err != nil {
		t.Fatalf("tick failed: %v", err)
	}

	var sawDeleteTarget, sawDeleteSnapshot, sawDeleteSource bool
	for _, inv := range rec.Invocations {
		if inv.Name != "find" {
			continue
		}
		joined := strings.Join(inv.Args, " ")
		switch {
		case strings.Contains(joined, "/tmp/cln-tgt"):
			sawDeleteTarget = true
		case strings.Contains(joined, "/tmp/cln-snap"):
			sawDeleteSnapshot = true
		case strings.Contains(joined, "/tmp/cln-src"):
			sawDeleteSource = true
		}
	}
	if !sawDeleteTarget {
		t.Fatalf("expected find -delete on target scratch; got %+v", rec.Invocations)
	}
	if !sawDeleteSnapshot {
		t.Fatalf("expected find -delete on snapshot scratch; got %+v", rec.Invocations)
	}
	if sawDeleteSource {
		t.Fatalf("cleanup must NEVER touch source; got %+v", rec.Invocations)
	}

	if len(c.PostInvocations) != 1 {
		t.Fatalf("expected 1 post invocation, got %d", len(c.PostInvocations))
	}
	got := c.PostInvocations[0]
	if !strings.Contains(got.Path, "/storage_migrations/mig-c1/cleanup_complete") {
		t.Fatalf("expected cleanup_complete path, got %q", got.Path)
	}
	if got.Body["status"] != "completed" {
		t.Fatalf("expected status=completed, got %v", got.Body["status"])
	}
	artifacts, ok := got.Body["artifacts"].([]any)
	if !ok || len(artifacts) != 2 {
		t.Fatalf("expected 2 artifacts reported, got %v", got.Body["artifacts"])
	}
}

func TestRunner_CleanupRequested_MissingSnapshotBinding_ReportsAlreadyClean(t *testing.T) {
	payload := `{"success":true,"data":{"storage_migrations":[{
		"id":"mig-c2","status":"failed",
		"cleanup_requested":true,
		"target_binding":{"volume_id":"t","transport":"nfs","mount_point":"/tmp/cln2-tgt","subpath":"deployments/x/postgres","nfs":{"server":"b","export_path":"/y","subpath":"deployments/x/postgres"}}
	}]}}`

	c := &fakeClient{GetResponses: map[string]string{
		"/api/v1/system/node_api/storage_migrations": payload,
	}}
	rec := &mount.RecorderRunner{}
	r := &Runner{Client: c, MountRunner: rec}

	if err := r.Tick(context.Background()); err != nil {
		t.Fatalf("tick failed: %v", err)
	}

	got := c.PostInvocations[0]
	artifacts, _ := got.Body["artifacts"].([]any)
	if len(artifacts) != 2 {
		t.Fatalf("expected 2 artifact entries (target + missing snapshot), got %v", artifacts)
	}
	snapshotArtifact, ok := artifacts[1].(map[string]any)
	if !ok || snapshotArtifact["already_clean"] != true {
		t.Fatalf("expected snapshot artifact already_clean=true for a nil binding, got %v", artifacts[1])
	}
}

// A delete failure (mount succeeded — there's real data there — but
// `find -delete` itself errors) must be a HARD failure, not silently
// downgraded to already_clean/completed. Reporting "completed" while
// data was never actually deleted would defeat the destructive
// operation's whole point.
func TestRunner_CleanupRequested_DeleteFailure_ReportsFailedNotCompleted(t *testing.T) {
	payload := `{"success":true,"data":{"storage_migrations":[{
		"id":"mig-c3","status":"failed",
		"cleanup_requested":true,
		"target_binding":{"volume_id":"t","transport":"nfs","mount_point":"/tmp/cln3-tgt","subpath":"deployments/x/postgres","nfs":{"server":"b","export_path":"/y","subpath":"deployments/x/postgres"}}
	}]}}`

	c := &fakeClient{GetResponses: map[string]string{
		"/api/v1/system/node_api/storage_migrations": payload,
	}}
	rec := &mount.RecorderRunner{
		StubErr: map[string]error{
			"find /tmp/cln3-tgt -mindepth 1 -delete": errors.New("permission denied"),
		},
	}
	var onErrorCalls int
	r := &Runner{Client: c, MountRunner: rec, OnError: func(string, error) { onErrorCalls++ }}

	// Tick itself doesn't propagate per-migration errors (by design —
	// one stumbling migration shouldn't block the batch); the failure
	// must surface via OnError AND the cleanup_complete report instead.
	if err := r.Tick(context.Background()); err != nil {
		t.Fatalf("tick failed: %v", err)
	}
	if onErrorCalls == 0 {
		t.Fatalf("expected the delete failure to surface via OnError")
	}

	if len(c.PostInvocations) != 1 {
		t.Fatalf("expected 1 post invocation, got %d", len(c.PostInvocations))
	}
	got := c.PostInvocations[0]
	if !strings.Contains(got.Path, "/cleanup_complete") {
		t.Fatalf("expected cleanup_complete path, got %q", got.Path)
	}
	if got.Body["status"] != "failed" {
		t.Fatalf("expected status=failed (NOT completed) when delete fails, got %v", got.Body["status"])
	}

	// Best-effort unmount still attempted after the delete failure.
	var sawUmount bool
	for _, inv := range rec.Invocations {
		if inv.Name == "umount" && len(inv.Args) == 1 && inv.Args[0] == "/tmp/cln3-tgt" {
			sawUmount = true
		}
	}
	if !sawUmount {
		t.Fatalf("expected best-effort umount after delete failure; got %+v", rec.Invocations)
	}
}

// Required agent-side guard (review finding): a binding with no
// effective subpath must be REFUSED before any mount is attempted —
// never treated as already_clean, never mounted at all. Without this,
// mount.ReconcileStorageVolume would mount the export ROOT (package
// mount has no non-empty-subpath guard anywhere) and `find -delete`
// would erase every other deployment's data on shared NFS.
func TestRunner_CleanupRequested_EmptySubpathBinding_RefusedWithoutMounting(t *testing.T) {
	payload := `{"success":true,"data":{"storage_migrations":[{
		"id":"mig-c4","status":"failed",
		"cleanup_requested":true,
		"target_binding":{"volume_id":"t","transport":"nfs","mount_point":"/tmp/cln4-tgt","nfs":{"server":"b","export_path":"/y"}}
	}]}}`

	c := &fakeClient{GetResponses: map[string]string{
		"/api/v1/system/node_api/storage_migrations": payload,
	}}
	rec := &mount.RecorderRunner{}
	var onErrorCalls int
	r := &Runner{Client: c, MountRunner: rec, OnError: func(string, error) { onErrorCalls++ }}

	if err := r.Tick(context.Background()); err != nil {
		t.Fatalf("tick failed: %v", err)
	}
	if onErrorCalls == 0 {
		t.Fatalf("expected the refusal to surface via OnError")
	}

	if len(rec.Invocations) != 0 {
		t.Fatalf("expected ZERO MountRunner invocations for an empty-subpath binding, got %+v", rec.Invocations)
	}

	if len(c.PostInvocations) != 1 {
		t.Fatalf("expected 1 post invocation, got %d", len(c.PostInvocations))
	}
	got := c.PostInvocations[0]
	if !strings.Contains(got.Path, "/cleanup_complete") {
		t.Fatalf("expected cleanup_complete path, got %q", got.Path)
	}
	if got.Body["status"] != "failed" {
		t.Fatalf("expected status=failed (a loud refusal, not already_clean), got %v", got.Body["status"])
	}
	reason, _ := got.Body["reason"].(string)
	if !strings.Contains(reason, "no subpath") {
		t.Fatalf("expected the failure reason to name the missing subpath, got %q", reason)
	}
}
