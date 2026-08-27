package runtime

import (
	"bufio"
	"os"
	"strconv"
	"strings"
)

// readMemAvailableKB reads MemAvailable from a /proc/meminfo-formatted
// file (IMP-6151ae14f4e5). MemAvailable — not MemFree — is the kernel's
// own estimate of memory a new workload could get without swapping: it
// already accounts for reclaimable page cache/slab. MemFree excludes
// that reclaimable cache and reads alarmingly low on a healthy node with
// a large cache, which would turn this into a false-alarm generator the
// first time an operator sets an SLO on it.
//
// Returns (0, false) when the file can't be read, has no MemAvailable
// line, or the value doesn't parse — the caller must leave the heartbeat
// field unset rather than report a fabricated 0. A genuine 0 (memory
// exhausted) is the one reading that must never be confused with "not
// measured".
func readMemAvailableKB(path string) (int64, bool) {
	f, err := os.Open(path)
	if err != nil {
		return 0, false
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "MemAvailable:") {
			continue
		}
		// "MemAvailable:", "<value>", "kB"
		fields := strings.Fields(line)
		if len(fields) < 2 {
			return 0, false
		}
		kb, err := strconv.ParseInt(fields[1], 10, 64)
		if err != nil {
			return 0, false
		}
		return kb, true
	}
	return 0, false
}

// readLoadAverage reads the 1/5/15-minute load averages — the first
// three whitespace-separated fields of a /proc/loadavg-formatted file —
// and re-joins them with a single space, matching the kernel's own
// format ("0.15 0.20 0.10"). System::RuntimeMetricsWriter stores this
// verbatim (bounded to 64 chars) for operator visibility; cpu_pct is
// deliberately NOT derived from it (IMP-938ee27f4921): load average
// folds in I/O-wait run-queue length and converting to a percentage
// needs a per-instance core count this agent doesn't reliably have on
// physical/pivot nodes.
//
// Returns ("", false) when the file can't be read or doesn't carry at
// least three fields.
func readLoadAverage(path string) (string, bool) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", false
	}
	fields := strings.Fields(string(b))
	if len(fields) < 3 {
		return "", false
	}
	return strings.Join(fields[:3], " "), true
}
