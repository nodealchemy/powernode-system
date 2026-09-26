package runtime

import (
	"reflect"
	"testing"
)

// F3(d), review round 3: buildHeartbeat must surface a boot's fail-closed
// refusals for the LIFE of the boot, not just the tick they happened on — it
// reads them from the persisted breadcrumb (LoadBreadcrumb(BootBreadcrumbPath)),
// not from any in-memory state, because renderPivotUnits runs once at boot,
// long before the heartbeat loop exists.
func TestBuildHeartbeat_PivotSecurityFailClosedUnitsFromBreadcrumb(t *testing.T) {
	bc := &BootComposedBreadcrumb{SecurityFailClosedUnits: []string{"powernode-hub-backend-rails-setup.service"}}
	if err := WriteBreadcrumb(BootBreadcrumbPath, bc); err != nil {
		t.Fatalf("WriteBreadcrumb: %v", err)
	}

	svc := &Service{cfg: Config{
		AgentVersion: "test",
		StatePath:    t.TempDir() + "/state.json", // does not exist -> LoadState error, zero State, non-fatal
		OnError:      func(string, error) {},
	}}

	got := svc.buildHeartbeat("boot-1", nil).PivotSecurityFailClosedUnits
	want := []string{"powernode-hub-backend-rails-setup.service"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("PivotSecurityFailClosedUnits = %v, want %v", got, want)
	}
}

// A boot with no fail-closed refusals must report the field as
// nil/omitted, never an empty-but-present list — the same absence
// discipline every other boot/LKG field in this payload follows.
func TestBuildHeartbeat_PivotSecurityFailClosedUnitsAbsentWhenClean(t *testing.T) {
	bc := &BootComposedBreadcrumb{}
	if err := WriteBreadcrumb(BootBreadcrumbPath, bc); err != nil {
		t.Fatalf("WriteBreadcrumb: %v", err)
	}

	svc := &Service{cfg: Config{
		AgentVersion: "test",
		StatePath:    t.TempDir() + "/state.json",
		OnError:      func(string, error) {},
	}}

	if got := svc.buildHeartbeat("boot-1", nil).PivotSecurityFailClosedUnits; len(got) != 0 {
		t.Errorf("expected no PivotSecurityFailClosedUnits on a clean boot, got %v", got)
	}
}

// RuntimeSecurityFailClosedUnits is the LIVE sibling — read straight from the
// Reconciler (not a breadcrumb), and must reflect whatever the Reconciler
// currently reports, including nil for a Service built without one (a
// buildHeartbeat call from a test that never ran Run(), same guard
// TestBuildHeartbeat_PivotConfinementOmittedDropsCapabilityBoundingSet relies
// on for other fields).
func TestBuildHeartbeat_RuntimeSecurityFailClosedUnitsFromReconciler(t *testing.T) {
	r := &Reconciler{}
	r.recordSecurityFailClosed([]string{"powernode-full-mod-app.service"})

	svc := &Service{
		cfg: Config{
			AgentVersion: "test",
			StatePath:    t.TempDir() + "/state.json",
			OnError:      func(string, error) {},
		},
		reconciler: r,
	}

	got := svc.buildHeartbeat("boot-1", nil).RuntimeSecurityFailClosedUnits
	want := []string{"powernode-full-mod-app.service"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("RuntimeSecurityFailClosedUnits = %v, want %v", got, want)
	}
}

func TestBuildHeartbeat_RuntimeSecurityFailClosedUnitsNilWithoutReconciler(t *testing.T) {
	svc := &Service{cfg: Config{
		AgentVersion: "test",
		StatePath:    t.TempDir() + "/state.json",
		OnError:      func(string, error) {},
	}}

	if got := svc.buildHeartbeat("boot-1", nil).RuntimeSecurityFailClosedUnits; len(got) != 0 {
		t.Errorf("expected no RuntimeSecurityFailClosedUnits without a Reconciler, got %v", got)
	}
}
