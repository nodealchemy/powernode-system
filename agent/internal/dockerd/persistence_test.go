package dockerd

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestManager_PersistAndLoadState_Roundtrip(t *testing.T) {
	a := &stubApplier{
		Cert:    &CertMaterial{ServerCertPEM: "exists"},
		Running: true,
		Version: "25.0.3",
	}
	m, fp, _ := newTestManager(t, []string{"docker-engine"}, a)
	defer fp.close()

	tmpDir := t.TempDir()
	m.StatePath = filepath.Join(tmpDir, "dockerd_state.json")

	m.Reconcile(context.Background())
	if fp.Ready != 1 {
		t.Fatalf("T1: expected ReportReady once, got %d", fp.Ready)
	}
	if m.state.readyReportedFor != "25.0.3" {
		t.Fatalf("expected readyReportedFor=25.0.3, got %q", m.state.readyReportedFor)
	}

	// Simulate agent restart
	a2 := &stubApplier{
		Cert:    &CertMaterial{ServerCertPEM: "exists"},
		Running: true,
		Version: "25.0.3",
	}
	m2 := NewManager(fp.client(), &stubModulesAPI{Modules: []string{"docker-engine"}}, a2,
		"node-1", "fd00::1", func(string, error) {})
	m2.StatePath = m.StatePath
	m2.loadState()

	if m2.state.readyReportedFor != "25.0.3" {
		t.Fatalf("expected reloaded readyReportedFor=25.0.3, got %q", m2.state.readyReportedFor)
	}

	m2.Reconcile(context.Background())
	if fp.Ready != 1 {
		t.Fatalf("T2 (after restart): ReportReady should be skipped (already reported); got %d total", fp.Ready)
	}
}

func TestManager_LoadState_MissingFileNoOp(t *testing.T) {
	a := &stubApplier{}
	m, fp, _ := newTestManager(t, []string{}, a)
	defer fp.close()

	tmpDir := t.TempDir()
	m.StatePath = filepath.Join(tmpDir, "nonexistent.json")
	m.loadState()
	if m.LastError() != nil {
		t.Fatalf("loadState should be silent on missing file, got %v", m.LastError())
	}
}

func TestManager_LoadState_CorruptedFile_Tolerant(t *testing.T) {
	a := &stubApplier{}
	m, fp, _ := newTestManager(t, []string{}, a)
	defer fp.close()

	tmpDir := t.TempDir()
	m.StatePath = filepath.Join(tmpDir, "corrupt.json")
	if err := os.WriteFile(m.StatePath, []byte("not-json{{{{"), 0o644); err != nil {
		t.Fatalf("setup: %v", err)
	}
	m.loadState()
	if m.state.readyReportedFor != "" {
		t.Fatalf("corrupt state should leave fields zero, got readyReportedFor=%q", m.state.readyReportedFor)
	}
}

func TestManager_PersistState_PersistsExpectedFields(t *testing.T) {
	a := &stubApplier{Cert: &CertMaterial{ServerCertPEM: "exists"}, Running: true, Version: "25.0.3"}
	m, fp, _ := newTestManager(t, []string{"docker-engine"}, a)
	defer fp.close()

	tmpDir := t.TempDir()
	m.StatePath = filepath.Join(tmpDir, "dockerd_state.json")
	m.state.readyReportedFor = "v999"
	m.state.stoppedReportedAt = time.Date(2026, 5, 4, 12, 0, 0, 0, time.UTC)
	m.persistState()

	body, err := os.ReadFile(m.StatePath)
	if err != nil {
		t.Fatalf("read state: %v", err)
	}
	bs := string(body)
	if !strings.Contains(bs, `"ready_reported_for":"v999"`) {
		t.Fatalf("expected ready_reported_for=v999, got %s", bs)
	}
	if !strings.Contains(bs, `"schema_version":2`) {
		t.Fatalf("expected schema_version=2 (slice 10), got %s", bs)
	}
}
