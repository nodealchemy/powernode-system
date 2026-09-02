package runtime

import (
	"bufio"
	"math"
	"os"
	"strconv"
	"strings"
)

// procStatPath is the kernel's aggregate CPU accounting file. Named once so
// the sampler, its default and its test can't drift apart.
const procStatPath = "/proc/stat"

// cpuStatColumns is how many columns of the aggregate `cpu` line enter the
// total: user, nice, system, idle, iowait, irq, softirq, steal. The two that
// follow (guest, guest_nice) are ALREADY counted inside user and nice, so
// summing them again inflates the denominator and understates utilization.
const cpuStatColumns = 8

// cpuStatMinColumns is the smallest line this can read: the name plus
// user/nice/system/idle/iowait. Anything shorter has no idle+iowait pair to
// subtract and is not a reading.
const cpuStatMinColumns = 6

// cpuTimes is one reading of the aggregate `cpu` line, in jiffies.
// `idle` is idle + iowait: a CPU parked waiting on I/O is NOT busy, and
// counting it as busy is exactly the conflation that makes load average
// unusable as a percentage.
type cpuTimes struct {
	total uint64
	idle  uint64
}

// cpuSampler turns two readings of /proc/stat into percent-busy across the
// interval BETWEEN them (APO-2a).
//
// WHY THE NODE MEASURES THIS AT ALL. The server deliberately does not derive
// cpu_pct from the load_average string this agent also ships
// (IMP-938ee27f4921): load average folds in I/O-wait run-queue length and
// converting it to a percentage needs a per-instance core count the platform
// does not reliably have for physical/pivot nodes. The busy/idle split exists
// only in the node's own /proc/stat, and the AGGREGATE `cpu` line is already
// summed across cores — so the ratio taken here needs no core count at all,
// which is exactly the number the platform lacks. The node computes the
// percentage and the platform ingests a measurement rather than an inference.
//
// ABSENCE IS NOT A MEASUREMENT — every failure path returns ok=false so
// buildHeartbeat leaves cpu_pct nil rather than shipping a fabricated 0.0,
// which is the single most misleading value here (an idle node). Unmeasurable
// cases: the first sample of the process (no interval behind it), an
// unreadable or malformed /proc/stat, a counter that did not advance (two
// reads inside one jiffy — dividing by that delta is a NaN on the wire), and
// a counter that went BACKWARDS (a reset; differencing against the stale
// baseline fabricates an enormous number).
//
// A reset re-baselines rather than latching: the reading is dropped, the new
// counters are kept, and the NEXT interval is measurable again.
type cpuSampler struct {
	path string
	prev *cpuTimes
}

// Sample reads /proc/stat and reports percent-busy since the previous call,
// or ok=false when that interval cannot be measured. It is called once per
// heartbeat from the heartbeat goroutine, so the sampler needs no locking.
func (c *cpuSampler) Sample() (float64, bool) {
	path := c.path
	if path == "" {
		path = procStatPath
	}

	now, ok := readCPUTimes(path)
	if !ok {
		// Leave the baseline alone: a single unreadable tick must not cost the
		// next interval its reference point.
		return 0, false
	}

	prev := c.prev
	c.prev = &now
	if prev == nil {
		return 0, false
	}
	// <=, not <: an unadvanced total is a zero-length interval, not a 0% one.
	if now.total <= prev.total || now.idle < prev.idle {
		return 0, false
	}

	totalDelta := now.total - prev.total
	idleDelta := now.idle - prev.idle
	if idleDelta > totalDelta {
		return 0, false
	}

	busy := (1 - float64(idleDelta)/float64(totalDelta)) * 100
	// The subtraction above already bounds this to 0..100; the clamp is a
	// float-rounding guard only.
	if busy < 0 {
		busy = 0
	}
	if busy > 100 {
		busy = 100
	}
	return math.Round(busy*100) / 100, true
}

// readCPUTimes parses the AGGREGATE `cpu` line (not the per-core `cpu0`
// lines) of a /proc/stat-formatted file. Returns ok=false for an unreadable
// file, a file with no aggregate line, a line with too few columns, or a
// column that does not parse — never a partial reading.
func readCPUTimes(path string) (cpuTimes, bool) {
	f, err := os.Open(path)
	if err != nil {
		return cpuTimes{}, false
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		// Exact match on the name: "cpu0" is one core, "cpu" is the whole node.
		if len(fields) == 0 || fields[0] != "cpu" {
			continue
		}
		if len(fields) < cpuStatMinColumns {
			return cpuTimes{}, false
		}

		var t cpuTimes
		limit := len(fields)
		if limit > cpuStatColumns+1 {
			limit = cpuStatColumns + 1
		}
		for i := 1; i < limit; i++ {
			v, err := strconv.ParseUint(fields[i], 10, 64)
			if err != nil {
				return cpuTimes{}, false
			}
			t.total += v
			if i == 4 || i == 5 { // idle, iowait
				t.idle += v
			}
		}
		return t, true
	}
	return cpuTimes{}, false
}
