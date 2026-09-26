package runtime

import (
	"reflect"
	"testing"
)

// IMP-caef5c00d63f phase 2. Closing the capability-bounding-set gap on the
// pivot path must retract the heartbeat's own report of that gap — a
// self-reported omission that outlives its cause overstates what is NOT
// enforced, which is the wrong direction for a security field an operator
// reads to decide what a pivoted (hub) node actually confines. Only
// mandatory_access_control (SELinux/AppArmor — untouched by this fix) should
// still be reported as omitted on a pivot node.
func TestBuildHeartbeat_PivotConfinementOmittedDropsCapabilityBoundingSet(t *testing.T) {
	forcePivotNative(t)
	svc := &Service{cfg: Config{
		AgentVersion: "test",
		StatePath:    t.TempDir() + "/state.json", // does not exist -> LoadState error, zero State, non-fatal
		OnError:      func(string, error) {},
	}}

	got := svc.buildHeartbeat("boot-1", nil).PivotConfinementOmitted
	want := []string{"mandatory_access_control"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("PivotConfinementOmitted = %v, want %v (capability_bounding_set is now enforced on the pivot path)", got, want)
	}
}
