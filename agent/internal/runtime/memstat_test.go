// memstat_test.go — IMP-6151ae14f4e5: heartbeat.go declared MemoryFreeKB and
// LoadAverage but nothing in non-test Go ever assigned either, so the wire
// never carried them. System::RuntimeMetricsWriter (server side, 44eaea13)
// is fully wired to consume both — it just never received a sample.
package runtime

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestBuildHeartbeatCarriesMemoryFreeKB is the RED test for the defect:
// buildHeartbeat's actual output must carry a real (non-nil) MemoryFreeKB,
// sourced from a real /proc/meminfo read — not injected by a spec.
//
// A bare substring check on the JSON key is NOT sufficient here: the field
// dropped `omitempty` (IMP-6151ae14f4e5, so a genuine 0 is distinguishable
// from "not measured"), so `"memory_free_kb"` appears in the wire body
// whether the value is a real reading or an unset `null`. That would let a
// broken/deleted read pass silently. Assert the struct field itself is
// non-nil, and pin the wire shape it produces (a bare number, not `null`).
func TestBuildHeartbeatCarriesMemoryFreeKB(t *testing.T) {
	payload := testService(t).buildHeartbeat("boot-1", nil)

	if payload.MemoryFreeKB == nil {
		t.Fatalf("heartbeat must carry a real memory_free_kb read from /proc/meminfo, got nil")
	}
	if *payload.MemoryFreeKB <= 0 {
		t.Fatalf("expected a positive kB reading on this host, got %d", *payload.MemoryFreeKB)
	}

	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if strings.Contains(string(body), `"memory_free_kb":null`) {
		t.Fatalf("a measured reading must not marshal as null, got: %s", body)
	}
}

// TestBuildHeartbeatCarriesLoadAverage pins the same shape for load_average:
// System::RuntimeMetricsWriter accepts and stores it (bounded, for operator
// visibility) even though cpu_pct is deliberately not derived from it.
func TestBuildHeartbeatCarriesLoadAverage(t *testing.T) {
	payload := testService(t).buildHeartbeat("boot-1", nil)

	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if !strings.Contains(string(body), `"load_average"`) {
		t.Fatalf("heartbeat must carry load_average read from /proc/loadavg, got: %s", body)
	}
}

// TestReadMemAvailableKB_UsesMemAvailableNotMemFree pins the field choice:
// MemFree excludes reclaimable page cache/slab and reads alarmingly low on a
// healthy node, which would make this a false-alarm generator the first time
// an operator sets an SLO on it. MemAvailable is the kernel's own estimate of
// what a new workload can actually get.
func TestReadMemAvailableKB_UsesMemAvailableNotMemFree(t *testing.T) {
	path := writeFixture(t, "meminfo", strings.Join([]string{
		"MemTotal:       16306912 kB",
		"MemFree:         1000000 kB", // deliberately far from MemAvailable
		"MemAvailable:   13107628 kB",
		"Buffers:          347036 kB",
		"",
	}, "\n"))

	kb, ok := readMemAvailableKB(path)
	if !ok {
		t.Fatalf("expected a successful read")
	}
	if kb != 13107628 {
		t.Fatalf("expected MemAvailable's value 13107628, got %d (looks like MemFree leaked through)", kb)
	}
}

func TestReadMemAvailableKB_MissingFile(t *testing.T) {
	if _, ok := readMemAvailableKB(filepath.Join(t.TempDir(), "does-not-exist")); ok {
		t.Fatalf("expected ok=false for a missing file")
	}
}

func TestReadMemAvailableKB_NoMemAvailableLine(t *testing.T) {
	path := writeFixture(t, "meminfo", "MemTotal:       16306912 kB\nMemFree: 1000000 kB\n")
	if _, ok := readMemAvailableKB(path); ok {
		t.Fatalf("expected ok=false when MemAvailable is absent, not a fabricated 0")
	}
}

func TestReadMemAvailableKB_Unparseable(t *testing.T) {
	path := writeFixture(t, "meminfo", "MemAvailable:   not-a-number kB\n")
	if _, ok := readMemAvailableKB(path); ok {
		t.Fatalf("expected ok=false for an unparseable value, not a fabricated 0")
	}
}

func TestReadLoadAverage_FirstThreeFields(t *testing.T) {
	path := writeFixture(t, "loadavg", "0.08 0.06 0.16 1/335 875551\n")

	la, ok := readLoadAverage(path)
	if !ok {
		t.Fatalf("expected a successful read")
	}
	if la != "0.08 0.06 0.16" {
		t.Fatalf("expected the first three fields joined by a space, got %q", la)
	}
}

func TestReadLoadAverage_MissingFile(t *testing.T) {
	if _, ok := readLoadAverage(filepath.Join(t.TempDir(), "does-not-exist")); ok {
		t.Fatalf("expected ok=false for a missing file")
	}
}

func TestReadLoadAverage_TooFewFields(t *testing.T) {
	path := writeFixture(t, "loadavg", "0.08 0.06\n")
	if _, ok := readLoadAverage(path); ok {
		t.Fatalf("expected ok=false when fewer than 3 fields are present, not a partial read")
	}
}

func writeFixture(t *testing.T, name, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	return path
}
