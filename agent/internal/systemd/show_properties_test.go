package systemd

import (
	"context"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// TestShowProperties_ParsesMultipleKeyValueLines (round Y) is the shape the
// confinement staleness probe relies on: one systemctl call answering
// several properties at once, parsed into a map keyed by property name.
func TestShowProperties_ParsesMultipleKeyValueLines(t *testing.T) {
	runner := &mount.RecorderRunner{
		StubOutput: map[string][]byte{
			"systemctl show app.service --property=ActiveState,MainPID,NeedDaemonReload": []byte("ActiveState=active\nMainPID=4242\nNeedDaemonReload=no\n"),
		},
	}
	got, err := ShowProperties(context.Background(), runner, "app.service", "ActiveState", "MainPID", "NeedDaemonReload")
	if err != nil {
		t.Fatalf("ShowProperties: %v", err)
	}
	want := map[string]string{"ActiveState": "active", "MainPID": "4242", "NeedDaemonReload": "no"}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("property %s: got %q, want %q (full: %v)", k, got[k], v, got)
		}
	}
}

// TestShowProperties_NotFoundUnitReportsInactive mirrors a renamed unit:
// systemctl show on a nonexistent unit exits 0 and reports
// LoadState=not-found, ActiveState=inactive — not an error.
func TestShowProperties_NotFoundUnitReportsInactive(t *testing.T) {
	runner := &mount.RecorderRunner{
		StubOutput: map[string][]byte{
			"systemctl show gone.service --property=ActiveState,MainPID": []byte("ActiveState=inactive\nMainPID=0\n"),
		},
	}
	got, err := ShowProperties(context.Background(), runner, "gone.service", "ActiveState", "MainPID")
	if err != nil {
		t.Fatalf("ShowProperties: %v", err)
	}
	if got["ActiveState"] != "inactive" || got["MainPID"] != "0" {
		t.Errorf("got %v, want ActiveState=inactive MainPID=0", got)
	}
}

func TestShowProperties_RejectsNilRunnerEmptyPropsAndBadUnit(t *testing.T) {
	if _, err := ShowProperties(context.Background(), nil, "app.service", "ActiveState"); err == nil {
		t.Error("expected error for nil runner")
	}
	runner := &mount.RecorderRunner{}
	if _, err := ShowProperties(context.Background(), runner, "app.service"); err == nil {
		t.Error("expected error for no properties requested")
	}
	if _, err := ShowProperties(context.Background(), runner, "-evil", "ActiveState"); err == nil {
		t.Error("expected error for an invalid unit name")
	}
}
