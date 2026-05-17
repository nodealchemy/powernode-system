package migration

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

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
