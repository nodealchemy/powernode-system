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
	// G4: recordSecurityFailClosed only accumulates into the PENDING set —
	// publishSecurityFailClosed is the one call that moves the atomically-
	// published value a heartbeat reads.
	r.publishSecurityFailClosed()

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

// G5 (review round 5): the boot breadcrumb is a one-time boot fact, re-read
// unchanged on every heartbeat. Once the LIVE path proves it can write a
// unit's security drop-in (Reconciler.SecurityFailClosedRecovered), a stale
// boot-time pivot refusal for that SAME unit must stop being reported —
// otherwise SecurityFailClosedSensor alarms for the node's entire uptime on
// a condition the live path already fixed.
func TestBuildHeartbeat_PivotSecurityFailClosedUnitsSuppressedOnceLiveRecovers(t *testing.T) {
	bc := &BootComposedBreadcrumb{SecurityFailClosedUnits: []string{
		"powernode-hub-backend-rails-setup.service",
		"powernode-hub-worker-sidekiq.service",
	}}
	if err := WriteBreadcrumb(BootBreadcrumbPath, bc); err != nil {
		t.Fatalf("WriteBreadcrumb: %v", err)
	}

	r := &Reconciler{}
	r.recordSecurityFailClosedRecovered([]string{"powernode-hub-backend-rails-setup.service"})

	svc := &Service{
		cfg: Config{
			AgentVersion: "test",
			StatePath:    t.TempDir() + "/state.json",
			OnError:      func(string, error) {},
		},
		reconciler: r,
	}

	got := svc.buildHeartbeat("boot-1", nil).PivotSecurityFailClosedUnits
	want := []string{"powernode-hub-worker-sidekiq.service"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("PivotSecurityFailClosedUnits = %v, want %v (rails-setup recovered live and must drop off, sidekiq must remain)", got, want)
	}
}

// The ONGOING half of G5: a unit the live path recovered must still be fully
// visible via RuntimeSecurityFailClosedUnits if it later fails AGAIN — the
// pivot suppression must never hide a CURRENT problem, only a stale one.
func TestBuildHeartbeat_RecoveredUnitStillVisibleIfRuntimeFailsAgain(t *testing.T) {
	bc := &BootComposedBreadcrumb{SecurityFailClosedUnits: []string{"powernode-hub-backend-rails-setup.service"}}
	if err := WriteBreadcrumb(BootBreadcrumbPath, bc); err != nil {
		t.Fatalf("WriteBreadcrumb: %v", err)
	}

	r := &Reconciler{}
	r.recordSecurityFailClosedRecovered([]string{"powernode-hub-backend-rails-setup.service"})
	r.recordSecurityFailClosed([]string{"powernode-hub-backend-rails-setup.service"})
	r.publishSecurityFailClosed()

	svc := &Service{
		cfg: Config{
			AgentVersion: "test",
			StatePath:    t.TempDir() + "/state.json",
			OnError:      func(string, error) {},
		},
		reconciler: r,
	}

	payload := svc.buildHeartbeat("boot-1", nil)
	if len(payload.PivotSecurityFailClosedUnits) != 0 {
		t.Errorf("the stale boot-time pivot refusal must stay suppressed, got %v", payload.PivotSecurityFailClosedUnits)
	}
	want := []string{"powernode-hub-backend-rails-setup.service"}
	if !reflect.DeepEqual(payload.RuntimeSecurityFailClosedUnits, want) {
		t.Errorf("RuntimeSecurityFailClosedUnits must still report the CURRENT failure, got %v, want %v",
			payload.RuntimeSecurityFailClosedUnits, want)
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
