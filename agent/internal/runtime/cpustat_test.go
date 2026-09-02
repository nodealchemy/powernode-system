// cpustat_test.go — APO-2a (IMP-ff9043758d8b): memory_pct was the only load
// signal the platform's ProjectMetricsCollector could see. load_average is
// shipped but is deliberately NOT converted to a percentage server-side
// (IMP-938ee27f4921), so the node must MEASURE percent-busy itself and ship
// it as cpu_pct.
package runtime

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeStat(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
}

// A first sample has no interval behind it. There is no honest percentage to
// report, and 0.0 ("idle") is the most misleading value the agent could pick.
func TestCPUSamplerFirstSampleIsNotMeasured(t *testing.T) {
	path := filepath.Join(t.TempDir(), "stat")
	writeStat(t, path, "cpu  100 0 100 800 0 0 0 0 0 0\n")

	s := &cpuSampler{path: path}
	if pct, ok := s.Sample(); ok {
		t.Fatalf("first sample must be unmeasured, got %v", pct)
	}
}

// busy = 1 - (idle_delta / total_delta). 100 user + 100 system + 800 idle
// added over the interval => 200/1000 = 20%.
func TestCPUSamplerComputesBusyPercentAcrossInterval(t *testing.T) {
	path := filepath.Join(t.TempDir(), "stat")
	writeStat(t, path, "cpu  100 0 100 800 0 0 0 0 0 0\n")
	s := &cpuSampler{path: path}
	s.Sample() // baseline

	writeStat(t, path, "cpu  200 0 200 1600 0 0 0 0 0 0\n")
	pct, ok := s.Sample()
	if !ok {
		t.Fatalf("second sample must be measurable")
	}
	if pct != 20.0 {
		t.Fatalf("expected 20.0%% busy, got %v", pct)
	}
}

// iowait is NOT busy CPU. Counting it as busy is exactly the conflation that
// makes load average unusable as a percentage.
func TestCPUSamplerCountsIowaitAsIdle(t *testing.T) {
	path := filepath.Join(t.TempDir(), "stat")
	writeStat(t, path, "cpu  100 0 100 800 0 0 0 0 0 0\n")
	s := &cpuSampler{path: path}
	s.Sample()

	writeStat(t, path, "cpu  100 0 100 800 1000 0 0 0 0 0\n") // 1000 jiffies of pure iowait
	pct, ok := s.Sample()
	if !ok {
		t.Fatalf("second sample must be measurable")
	}
	if pct != 0.0 {
		t.Fatalf("iowait must count as idle, expected 0.0, got %v", pct)
	}
}

// guest/guest_nice are already included in user/nice. Summing them again
// inflates the denominator and understates utilization.
func TestCPUSamplerDoesNotDoubleCountGuest(t *testing.T) {
	path := filepath.Join(t.TempDir(), "stat")
	writeStat(t, path, "cpu  100 0 100 800 0 0 0 0 0 0\n")
	s := &cpuSampler{path: path}
	s.Sample()

	writeStat(t, path, "cpu  200 0 200 1600 0 0 0 0 500 500\n")
	pct, ok := s.Sample()
	if !ok {
		t.Fatalf("second sample must be measurable")
	}
	if pct != 20.0 {
		t.Fatalf("guest columns must not enter the total, expected 20.0, got %v", pct)
	}
}

// Two reads inside one jiffy: no interval, so no measurement. Dividing by a
// zero delta would be a NaN on the wire.
func TestCPUSamplerNoAdvanceIsNotMeasured(t *testing.T) {
	path := filepath.Join(t.TempDir(), "stat")
	writeStat(t, path, "cpu  100 0 100 800 0 0 0 0 0 0\n")
	s := &cpuSampler{path: path}
	s.Sample()

	if pct, ok := s.Sample(); ok {
		t.Fatalf("an unadvanced counter is not a measurement, got %v", pct)
	}
}

// A counter that went BACKWARDS is a reset (kernel/CPU hotplug). Differencing
// against the old baseline fabricates a huge number; the sampler must decline
// and re-baseline so the NEXT interval is measurable.
func TestCPUSamplerCounterResetDeclinesThenRebaselines(t *testing.T) {
	path := filepath.Join(t.TempDir(), "stat")
	writeStat(t, path, "cpu  1000 0 1000 8000 0 0 0 0 0 0\n")
	s := &cpuSampler{path: path}
	s.Sample()

	writeStat(t, path, "cpu  100 0 100 800 0 0 0 0 0 0\n") // reset
	if pct, ok := s.Sample(); ok {
		t.Fatalf("a counter reset must not yield a measurement, got %v", pct)
	}

	writeStat(t, path, "cpu  200 0 200 1600 0 0 0 0 0 0\n")
	pct, ok := s.Sample()
	if !ok {
		t.Fatalf("the sampler must re-baseline on reset so the next interval is measurable")
	}
	if pct != 20.0 {
		t.Fatalf("expected 20.0 after re-baseline, got %v", pct)
	}
}

func TestCPUSamplerUnreadableOrMalformedIsNotMeasured(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "does-not-exist")
	if _, ok := (&cpuSampler{path: missing}).Sample(); ok {
		t.Fatalf("a missing /proc/stat must not yield a measurement")
	}

	path := filepath.Join(t.TempDir(), "stat")
	writeStat(t, path, "cpu  100 0\n") // too few columns
	if _, ok := (&cpuSampler{path: path}).Sample(); ok {
		t.Fatalf("a malformed cpu line must not yield a measurement")
	}

	writeStat(t, path, "intr 1 2 3\nctxt 99\n") // no aggregate cpu line at all
	if _, ok := (&cpuSampler{path: path}).Sample(); ok {
		t.Fatalf("a /proc/stat with no aggregate cpu line must not yield a measurement")
	}
}

// The wire half: cpu_pct must reach the heartbeat body as a real number once
// an interval exists, and as an explicit absence before that. `*float64`
// without omitempty for the same reason MemoryFreeKB is: 0.0 (a genuinely
// idle node) is a real reading and must never be indistinguishable from
// "not measured".
func TestBuildHeartbeatCarriesCPUPct(t *testing.T) {
	path := filepath.Join(t.TempDir(), "stat")
	writeStat(t, path, "cpu  100 0 100 800 0 0 0 0 0 0\n")

	svc := testService(t)
	svc.cpu = &cpuSampler{path: path}

	first := svc.buildHeartbeat("boot-1", nil)
	if first.CPUPct != nil {
		t.Fatalf("the first heartbeat has no interval behind it, expected nil, got %v", *first.CPUPct)
	}
	body, err := json.Marshal(first)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if !strings.Contains(string(body), `"cpu_pct":null`) {
		t.Fatalf("an unmeasured cpu_pct must be explicit on the wire, got: %s", body)
	}

	writeStat(t, path, "cpu  200 0 200 1600 0 0 0 0 0 0\n")
	second := svc.buildHeartbeat("boot-1", nil)
	if second.CPUPct == nil {
		t.Fatalf("the second heartbeat must carry a measured cpu_pct")
	}
	if *second.CPUPct != 20.0 {
		t.Fatalf("expected 20.0, got %v", *second.CPUPct)
	}
}

// buildHeartbeat must work with no sampler pre-wired (production path):
// it lazily binds /proc/stat rather than skipping the metric forever.
func TestBuildHeartbeatBindsDefaultCPUSampler(t *testing.T) {
	svc := testService(t)
	svc.buildHeartbeat("boot-1", nil)
	if svc.cpu == nil {
		t.Fatalf("buildHeartbeat must bind a cpu sampler")
	}
	if svc.cpu.path != procStatPath {
		t.Fatalf("expected the default %s, got %s", procStatPath, svc.cpu.path)
	}
}
