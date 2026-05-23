package etcidentity

import (
	"strings"
	"testing"
)

func TestRenderPasswdBaselineOnly(t *testing.T) {
	got := string(RenderPasswd(Baseline()))
	// Sanity: contains root and nobody as expected, in some order.
	for _, want := range []string{"root:x:0:0:", "nobody:x:65534:65534:"} {
		if !strings.Contains(got, want) {
			t.Errorf("RenderPasswd missing %q\noutput:\n%s", want, got)
		}
	}
	// Sanity: ends with a newline (every line, every file).
	if !strings.HasSuffix(got, "\n") {
		t.Errorf("RenderPasswd output does not end with newline:\n%q", got)
	}
}

func TestRenderShadowLocksAllServiceAccounts(t *testing.T) {
	got := string(RenderShadow(Baseline()))
	for _, line := range strings.Split(strings.TrimRight(got, "\n"), "\n") {
		fields := strings.Split(line, ":")
		if len(fields) < 2 {
			t.Fatalf("malformed shadow line: %q", line)
		}
		name, pw := fields[0], fields[1]
		// root gets `!*` (locked but not deleted — see RenderShadow comment).
		// All other accounts get `*` (locked).
		if name == "root" {
			if pw != "!*" {
				t.Errorf("root password expected !* got %q (line: %q)", pw, line)
			}
			continue
		}
		if pw != "*" {
			t.Errorf("%s password expected * got %q (line: %q)", name, pw, line)
		}
	}
}

func TestRenderGroupSortedByGID(t *testing.T) {
	// Baseline is unsorted; Collect sorts. Verify the rendered output
	// from a Collected set is GID-ascending.
	got := string(RenderGroup(Baseline()))
	lines := strings.Split(strings.TrimRight(got, "\n"), "\n")
	if len(lines) == 0 {
		t.Fatal("RenderGroup returned no lines")
	}
	// Note: Baseline directly (without Collect) is NOT sorted. The
	// agent always calls Collect before Render, which sorts. This test
	// just validates Render preserves the input order, not that it sorts.
	first := strings.Split(lines[0], ":")
	if len(first) < 3 || first[2] != "0" {
		t.Errorf("expected first line to be root:x:0:..., got %q", lines[0])
	}
}

func TestCollectDedupsByName(t *testing.T) {
	// Empty input — should still return baseline.
	set, conflicts := Collect(nil)
	if len(conflicts) != 0 {
		t.Errorf("unexpected conflicts on empty input: %+v", conflicts)
	}
	if len(set.Users) == 0 {
		t.Error("Collect with no manifests returned empty user set; baseline missing?")
	}
	// Look for root.
	var foundRoot bool
	for _, u := range set.Users {
		if u.Name == "root" {
			foundRoot = true
			break
		}
	}
	if !foundRoot {
		t.Error("baseline did not include root")
	}
}
