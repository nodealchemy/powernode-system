//go:build linux

package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/runtime/tasks"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
	"github.com/nodealchemy/powernode-system/agent/internal/taskguard"
)

// unit.dropin writes ONE runtime drop-in as root. Every test here runs against
// a sandbox directory standing in for /run/systemd/system, a sandbox lifecycle
// unit directory, a sandbox /etc/systemd/system for the capabilities.conf the
// agent renders, and an injected mount.RecorderRunner: none of them reads or
// writes the real /run or /etc, or runs systemctl.

const dropinTestUnit = "powernode-019f7cb5-3858-7caa-aa9f-51629dc8e573-sidekiq.service"

type dropinSandbox struct {
	root   string // stands in for /run/systemd/system
	units  string // lifecycle.UnitDir()
	etc    string // stands in for /etc/systemd/system (capabilities.conf)
	runner *mount.RecorderRunner
	h      *UnitDropinHandler
}

func newDropinSandbox(t *testing.T) *dropinSandbox {
	t.Helper()
	base := t.TempDir()
	if real, err := filepath.EvalSymlinks(base); err == nil {
		base = real
	}
	sb := &dropinSandbox{
		root:   filepath.Join(base, "run-systemd-system"),
		units:  filepath.Join(base, "units"),
		etc:    filepath.Join(base, "etc-systemd-system"),
		runner: &mount.RecorderRunner{},
	}
	for _, d := range []string{sb.root, sb.units, sb.etc, filepath.Join(base, "outside")} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", sb.units)
	writeUnitFile(t, sb.units, dropinTestUnit)
	t.Cleanup(SetDropinRootForTest(sb.root))
	t.Cleanup(security.SetSystemdDropInRootForTest(sb.etc))
	sb.h = &UnitDropinHandler{deps: tasks.Dependencies{MountRunner: sb.runner}}
	return sb
}

func (sb *dropinSandbox) outside() string { return filepath.Join(filepath.Dir(sb.root), "outside") }

func (sb *dropinSandbox) dir() string { return filepath.Join(sb.root, dropinTestUnit+".d") }

// renderCaps writes the capabilities.conf the agent's own attach path renders
// for the unit, through the same renderer.
func (sb *dropinSandbox) renderCaps(t *testing.T, allow ...string) {
	t.Helper()
	body, err := security.RenderCapabilityDropInBody(allow)
	if err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(sb.etc, dropinTestUnit+".d")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "capabilities.conf"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func (sb *dropinSandbox) run(options map[string]any) (tasks.Result, error) {
	return sb.h.Execute(context.Background(), &tasks.Task{ID: "t1", Command: "unit.dropin", Options: options})
}

func (sb *dropinSandbox) reloads() int {
	n := 0
	for _, inv := range sb.runner.Invocations {
		if inv.Name == "systemctl" && strings.Join(inv.Args, " ") == "daemon-reload" {
			n++
		}
	}
	return n
}

func (sb *dropinSandbox) listDir(t *testing.T) []string {
	t.Helper()
	entries, err := os.ReadDir(sb.dir())
	if err != nil {
		t.Fatal(err)
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		names = append(names, e.Name())
	}
	sort.Strings(names)
	return names
}

func applyOptions(name string, directives ...map[string]any) map[string]any {
	list := make([]any, 0, len(directives))
	for _, d := range directives {
		list = append(list, d)
	}
	return map[string]any{"unit": dropinTestUnit, "name": name, "revert": false, "directives": list}
}

func directive(key, value string) map[string]any { return map[string]any{"key": key, "value": value} }

// === the shared table (server parity) ===

// unit_dropin_cases.json is read by the Ruby System::UnitDropinService spec as
// well: one table, two allow-lists, two renderers.
type dropinCases struct {
	NameOK           []string `json:"name_ok"`
	NameRefused      []string `json:"name_refused"`
	Accepted         [][]any  `json:"accepted"`
	CapabilitySubset []struct {
		Why        string    `json:"why"`
		Resolved   *[]string `json:"resolved"`
		Directives []any     `json:"directives"`
		OK         bool      `json:"ok"`
	} `json:"capability_subset"`
	Refused []struct {
		Why        string `json:"why"`
		Directives []any  `json:"directives"`
	} `json:"refused"`
	Render []struct {
		Name       string `json:"name"`
		Directives []any  `json:"directives"`
		Content    string `json:"content"`
	} `json:"render"`
}

// expandDropinFixture replaces every {prefix, repeat, times, suffix} object
// with the string it builds, so a token-shaped value is made at run time.
func expandDropinFixture(v any) any {
	switch x := v.(type) {
	case map[string]any:
		if rep, ok := x["repeat"].(string); ok {
			prefix, _ := x["prefix"].(string)
			suffix, _ := x["suffix"].(string)
			times, _ := x["times"].(float64)
			return prefix + strings.Repeat(rep, int(times)) + suffix
		}
		out := map[string]any{}
		for k, val := range x {
			out[k] = expandDropinFixture(val)
		}
		return out
	case []any:
		out := make([]any, len(x))
		for i, val := range x {
			out[i] = expandDropinFixture(val)
		}
		return out
	default:
		return v
	}
}

func loadDropinCases(t *testing.T) dropinCases {
	t.Helper()
	raw, err := os.ReadFile("testdata/unit_dropin_cases.json")
	if err != nil {
		t.Fatal(err)
	}
	var generic any
	if err := json.Unmarshal(raw, &generic); err != nil {
		t.Fatal(err)
	}
	expanded, err := json.Marshal(expandDropinFixture(generic))
	if err != nil {
		t.Fatal(err)
	}
	var c dropinCases
	if err := json.Unmarshal(expanded, &c); err != nil {
		t.Fatal(err)
	}
	if len(c.NameOK) == 0 || len(c.NameRefused) == 0 || len(c.Accepted) == 0 || len(c.Refused) == 0 || len(c.Render) == 0 || len(c.CapabilitySubset) == 0 {
		t.Fatal("a section of unit_dropin_cases.json is empty")
	}
	return c
}

// The JSON decoder hands numbers to the directive parser as float64, exactly as
// a task's options arrive, so re-decode each list the way a task is decoded.
func asTaskValue(t *testing.T, v any) any {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	var out any
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatal(err)
	}
	return out
}

func TestUnitDropinSharedCases(t *testing.T) {
	c := loadDropinCases(t)
	for _, name := range c.NameOK {
		if err := dropinNameRefusal(name); err != nil {
			t.Errorf("name %q refused: %v", name, err)
		}
	}
	for _, name := range c.NameRefused {
		if err := dropinNameRefusal(name); !errors.Is(err, taskguard.ErrRefused) {
			t.Errorf("name %q accepted (err=%v)", name, err)
		}
	}
	for _, list := range c.Accepted {
		if _, err := normalizeDropinDirectives(asTaskValue(t, list)); err != nil {
			t.Errorf("accepted fixture %v refused: %v", list, err)
		}
	}
	for _, entry := range c.Refused {
		if _, err := normalizeDropinDirectives(asTaskValue(t, entry.Directives)); !errors.Is(err, taskguard.ErrRefused) {
			t.Errorf("refused fixture %q accepted (err=%v)", entry.Why, err)
		}
	}
	for _, entry := range c.CapabilitySubset {
		pairs, err := normalizeDropinDirectives(asTaskValue(t, entry.Directives))
		if err != nil {
			t.Fatalf("capability_subset fixture %q: %v", entry.Why, err)
		}
		var resolved []string
		if entry.Resolved != nil {
			resolved = *entry.Resolved
		}
		err = dropinCapabilitySubsetRefusal(pairs, resolved, entry.Resolved != nil)
		if entry.OK && err != nil {
			t.Errorf("capability_subset %q refused: %v", entry.Why, err)
		}
		if !entry.OK && !errors.Is(err, taskguard.ErrRefused) {
			t.Errorf("capability_subset %q accepted (err=%v)", entry.Why, err)
		}
	}
	for _, entry := range c.Render {
		pairs, err := normalizeDropinDirectives(asTaskValue(t, entry.Directives))
		if err != nil {
			t.Fatalf("render fixture %s: %v", entry.Name, err)
		}
		if got := renderDropin(entry.Name, pairs); got != entry.Content {
			t.Errorf("render %s:\n got %q\nwant %q", entry.Name, got, entry.Content)
		}
	}
}

func TestUnitDropinRefusesTooManyDirectives(t *testing.T) {
	list := make([]any, 0, dropinMaxDirectives+1)
	for i := 0; i <= dropinMaxDirectives; i++ {
		list = append(list, map[string]any{"key": "MemoryMax", "value": "1G"})
	}
	if _, err := normalizeDropinDirectives(list); !errors.Is(err, taskguard.ErrRefused) || !strings.Contains(err.Error(), "at most") {
		t.Fatalf("%d directives accepted (err=%v)", len(list), err)
	}
}

// === the write ===

func TestUnitDropinWritesAtomicallyAndReloads(t *testing.T) {
	sb := newDropinSandbox(t)

	res, err := sb.run(applyOptions("zero-caps", directive("CapabilityBoundingSet", ""), directive("AmbientCapabilities", "")))
	if err != nil {
		t.Fatal(err)
	}

	target := filepath.Join(sb.dir(), "zz-operator-zero-caps.conf")
	got, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	want := "# Managed by Powernode: operator drop-in \"zero-caps\" (system_apply_unit_dropin).\n" +
		"# Runtime only: /run is tmpfs, so a reboot removes this file.\n" +
		"[Service]\nCapabilityBoundingSet=\nAmbientCapabilities=\n"
	if string(got) != want {
		t.Fatalf("content:\n%q\nwant\n%q", got, want)
	}
	info, err := os.Lstat(target)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0o644 {
		t.Fatalf("target mode %v err %v, want a regular 0644 file", info.Mode(), err)
	}
	if names := sb.listDir(t); len(names) != 1 {
		t.Fatalf("drop-in dir holds %v, want only the drop-in (no temp file left)", names)
	}
	if sb.reloads() != 1 {
		t.Fatalf("daemon-reload invoked %d times, want 1: %+v", sb.reloads(), sb.runner.Invocations)
	}
	if res["action"] != "applied" || res["path"] != filepath.Join("/run/systemd/system", dropinTestUnit+".d", "zz-operator-zero-caps.conf") {
		t.Fatalf("result %v", res)
	}
	if res["replaced"] != false {
		t.Fatalf("result says replaced on a first write: %v", res)
	}

	// Re-running is idempotent and reports the replacement.
	res, err = sb.run(applyOptions("zero-caps", directive("CapabilityBoundingSet", ""), directive("AmbientCapabilities", "")))
	if err != nil || res["replaced"] != true {
		t.Fatalf("second apply: %v %v", res, err)
	}
}

func TestUnitDropinInjectedErrorLeavesNoPartialFile(t *testing.T) {
	for _, stage := range []string{"write", "fsync", "rename"} {
		t.Run(stage, func(t *testing.T) {
			sb := newDropinSandbox(t)
			if err := os.MkdirAll(sb.dir(), 0o755); err != nil {
				t.Fatal(err)
			}
			target := filepath.Join(sb.dir(), "zz-operator-trial.conf")
			if err := os.WriteFile(target, []byte("[Service]\nMemoryMax=1G\n"), 0o644); err != nil {
				t.Fatal(err)
			}
			injected := errors.New("injected " + stage + " failure")
			restore := SetDropinFaultForTest(func(s string) error {
				if s == stage {
					return injected
				}
				return nil
			})
			defer restore()

			_, err := sb.run(applyOptions("trial", directive("MemoryMax", "2G")))
			if !errors.Is(err, injected) {
				t.Fatalf("err = %v, want the injected failure", err)
			}
			got, _ := os.ReadFile(target)
			if string(got) != "[Service]\nMemoryMax=1G\n" {
				t.Fatalf("the previous drop-in was altered: %q", got)
			}
			if names := sb.listDir(t); len(names) != 1 || names[0] != "zz-operator-trial.conf" {
				t.Fatalf("drop-in dir holds %v after a failed write, want only the previous file", names)
			}
			if sb.reloads() != 0 {
				t.Fatal("daemon-reload ran after a failed write")
			}
		})
	}
}

func TestUnitDropinFailedFirstWriteLeavesNoFile(t *testing.T) {
	sb := newDropinSandbox(t)
	restore := SetDropinFaultForTest(func(s string) error {
		if s == "fsync" {
			return errors.New("injected")
		}
		return nil
	})
	defer restore()

	if _, err := sb.run(applyOptions("trial", directive("MemoryMax", "2G"))); err == nil {
		t.Fatal("want an error")
	}
	if names := sb.listDir(t); len(names) != 0 {
		t.Fatalf("drop-in dir holds %v after a failed first write, want nothing", names)
	}
}

func TestUnitDropinReportsAFailedReload(t *testing.T) {
	sb := newDropinSandbox(t)
	sb.runner.StubErr = map[string]error{"systemctl daemon-reload": errors.New("reload failed")}

	if _, err := sb.run(applyOptions("trial", directive("MemoryMax", "2G"))); err == nil || !strings.Contains(err.Error(), "daemon-reload") {
		t.Fatalf("err = %v, want the daemon-reload failure", err)
	}
}

// === revert ===

func TestUnitDropinRevertRemovesOnlyTheOperatorFile(t *testing.T) {
	sb := newDropinSandbox(t)
	if err := os.MkdirAll(sb.dir(), 0o755); err != nil {
		t.Fatal(err)
	}
	keep := []string{"10-module.conf", "zz-operator-other.conf", "zz-operator-trial.conf.bak", "zz-operator-trial"}
	for _, name := range append(keep, "zz-operator-trial.conf") {
		if err := os.WriteFile(filepath.Join(sb.dir(), name), []byte("[Service]\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	res, err := sb.run(map[string]any{"unit": dropinTestUnit, "name": "trial", "revert": true, "directives": []any{}})
	if err != nil {
		t.Fatal(err)
	}
	sort.Strings(keep)
	if got := sb.listDir(t); strings.Join(got, ",") != strings.Join(keep, ",") {
		t.Fatalf("after revert the dir holds %v, want exactly %v", got, keep)
	}
	if res["action"] != "reverted" || sb.reloads() != 1 {
		t.Fatalf("result %v, reloads %d", res, sb.reloads())
	}

	// Reverting again is idempotent: nothing to remove, still reloads, nothing else touched.
	res, err = sb.run(map[string]any{"unit": dropinTestUnit, "name": "trial", "revert": true})
	if err != nil || res["action"] != "absent" {
		t.Fatalf("second revert: %v %v", res, err)
	}
	if got := sb.listDir(t); strings.Join(got, ",") != strings.Join(keep, ",") {
		t.Fatalf("second revert touched %v", got)
	}
}

func TestUnitDropinRevertWithNoDirectoryIsAbsent(t *testing.T) {
	sb := newDropinSandbox(t)
	res, err := sb.run(map[string]any{"unit": dropinTestUnit, "name": "trial", "revert": true})
	if err != nil || res["action"] != "absent" {
		t.Fatalf("%v %v", res, err)
	}
	if _, err := os.Lstat(sb.dir()); !os.IsNotExist(err) {
		t.Fatal("a revert created the drop-in directory")
	}
}

// === symlinks ===

func TestUnitDropinRefusesASymlinkedDropinDirectory(t *testing.T) {
	sb := newDropinSandbox(t)
	if err := os.Symlink(sb.outside(), sb.dir()); err != nil {
		t.Fatal(err)
	}

	_, err := sb.run(applyOptions("trial", directive("MemoryMax", "2G")))
	if err == nil {
		t.Fatal("wrote through a symlinked drop-in directory")
	}
	if entries, _ := os.ReadDir(sb.outside()); len(entries) != 0 {
		t.Fatalf("the symlink target received %d entries", len(entries))
	}

	// A revert through the same link must not unlink anything in the target.
	victim := filepath.Join(sb.outside(), "zz-operator-trial.conf")
	if err := os.WriteFile(victim, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := sb.run(map[string]any{"unit": dropinTestUnit, "name": "trial", "revert": true}); err == nil {
		t.Fatal("reverted through a symlinked drop-in directory")
	}
	if _, err := os.Stat(victim); err != nil {
		t.Fatal("the revert removed a file in the symlink target")
	}
	if sb.reloads() != 0 {
		t.Fatal("daemon-reload ran after a refusal")
	}
}

func TestUnitDropinRefusesASymlinkAtTheTarget(t *testing.T) {
	sb := newDropinSandbox(t)
	if err := os.MkdirAll(sb.dir(), 0o755); err != nil {
		t.Fatal(err)
	}
	victim := filepath.Join(sb.outside(), "victim.conf")
	if err := os.WriteFile(victim, []byte("untouched"), 0o644); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(sb.dir(), "zz-operator-trial.conf")
	if err := os.Symlink(victim, link); err != nil {
		t.Fatal(err)
	}

	if _, err := sb.run(applyOptions("trial", directive("MemoryMax", "2G"))); err == nil {
		t.Fatal("wrote over a symlink at the target")
	}
	if got, _ := os.ReadFile(victim); string(got) != "untouched" {
		t.Fatalf("the symlink target was written: %q", got)
	}
	if info, err := os.Lstat(link); err != nil || info.Mode()&os.ModeSymlink == 0 {
		t.Fatal("the planted link was replaced rather than refused")
	}
}

// === option and unit refusals ===

func TestUnitDropinRefusesAUnitThisNodeDidNotGenerate(t *testing.T) {
	sb := newDropinSandbox(t)
	for _, unit := range []string{
		"powernode-agent.service",
		"sshd.service",
		"powernode-019f7cb5-3858-7caa-aa9f-51629dc8e573-absent.service",
		"../" + dropinTestUnit,
		"powernode-x.mount",
	} {
		opts := applyOptions("trial", directive("MemoryMax", "2G"))
		opts["unit"] = unit
		if _, err := sb.run(opts); !errors.Is(err, taskguard.ErrRefused) {
			t.Errorf("unit %q not refused (err=%v)", unit, err)
		}
	}
	if entries, _ := os.ReadDir(sb.root); len(entries) != 0 {
		t.Fatalf("refused units created %d entries", len(entries))
	}
	if len(sb.runner.Invocations) != 0 {
		t.Fatalf("a refusal ran commands: %+v", sb.runner.Invocations)
	}
}

func TestUnitDropinRefusesTheAgentUnitEvenWhenInstalled(t *testing.T) {
	sb := newDropinSandbox(t)
	writeUnitFile(t, sb.units, "powernode-agent-helper.service")
	opts := applyOptions("trial", directive("MemoryMax", "2G"))
	opts["unit"] = "powernode-agent-helper.service"
	if _, err := sb.run(opts); !errors.Is(err, taskguard.ErrRefused) {
		t.Fatalf("agent unit not refused (err=%v)", err)
	}
}

func TestUnitDropinRefusesMalformedOptions(t *testing.T) {
	sb := newDropinSandbox(t)
	good := func() map[string]any { return applyOptions("trial", directive("MemoryMax", "2G")) }
	cases := map[string]func(map[string]any){
		"unknown option":            func(o map[string]any) { o["command"] = "id" },
		"revert with directives":    func(o map[string]any) { o["revert"] = true },
		"revert not a bool":         func(o map[string]any) { o["revert"] = "yes" },
		"name missing":              func(o map[string]any) { delete(o, "name") },
		"name traversal":            func(o map[string]any) { o["name"] = "../../etc/x" },
		"directives missing":        func(o map[string]any) { delete(o, "directives") },
		"directives not a list":     func(o map[string]any) { o["directives"] = "MemoryMax=1G" },
		"injected newline in value": func(o map[string]any) { o["directives"] = []any{directive("MemoryMax", "1G\nExecStart=/bin/sh")} },
		"ExecStart":                 func(o map[string]any) { o["directives"] = []any{directive("ExecStart", "/bin/sh")} },
	}
	for name, mutate := range cases {
		opts := good()
		mutate(opts)
		if _, err := sb.run(opts); !errors.Is(err, taskguard.ErrRefused) {
			t.Errorf("%s: not refused (err=%v)", name, err)
		}
	}
	if entries, _ := os.ReadDir(sb.root); len(entries) != 0 {
		t.Fatalf("refused options created %d entries", len(entries))
	}
}

// F1: Environment= is off the allow-list, benign or not.
func TestUnitDropinRefusesEnvironment(t *testing.T) {
	for _, value := range []string{"LOG_LEVEL=debug", "LD_PRELOAD=/persist/x/evil.so", "NODE_OPTIONS=--inspect"} {
		_, err := normalizeDropinDirectives([]any{map[string]any{"key": "Environment", "value": value}})
		if !errors.Is(err, taskguard.ErrRefused) || !strings.Contains(err.Error(), "Environment= is not settable through this verb; env tuning needs manifest-declared tunables") {
			t.Errorf("Environment %q: err = %v", value, err)
		}
	}
}

// F2: a capability directive may only narrow the set the agent rendered into
// the unit's capabilities.conf; with no such file only the empty list passes.
func TestUnitDropinCapabilitiesMustNarrowTheRenderedSet(t *testing.T) {
	sb := newDropinSandbox(t)

	caps := func(key, value string) map[string]any { return applyOptions("caps", directive(key, value)) }

	// No capabilities.conf: the set cannot be resolved.
	if _, err := sb.run(caps("AmbientCapabilities", "CAP_CHOWN")); !errors.Is(err, taskguard.ErrRefused) {
		t.Fatalf("non-empty caps accepted with no rendered set (err=%v)", err)
	}
	if _, err := sb.run(caps("AmbientCapabilities", "")); err != nil {
		t.Fatalf("empty caps refused with no rendered set: %v", err)
	}

	sb.renderCaps(t, "CAP_NET_BIND_SERVICE", "CAP_CHOWN")
	if _, err := sb.run(caps("AmbientCapabilities", "CAP_SYS_ADMIN")); !errors.Is(err, taskguard.ErrRefused) {
		t.Fatalf("CAP_SYS_ADMIN accepted on a unit rendered without it (err=%v)", err)
	}
	if _, err := sb.run(caps("CapabilityBoundingSet", "CAP_NET_BIND_SERVICE CAP_NET_RAW")); !errors.Is(err, taskguard.ErrRefused) {
		t.Fatalf("a wider bounding set was accepted (err=%v)", err)
	}
	if _, err := sb.run(caps("CapabilityBoundingSet", "CAP_NET_BIND_SERVICE")); err != nil {
		t.Fatalf("a strict subset was refused: %v", err)
	}
	if _, err := sb.run(caps("CapabilityBoundingSet", "")); err != nil {
		t.Fatalf("the empty list was refused: %v", err)
	}

	sb.renderCaps(t) // a zero-capability unit
	if _, err := sb.run(caps("AmbientCapabilities", "CAP_CHOWN")); !errors.Is(err, taskguard.ErrRefused) {
		t.Fatalf("a capability was accepted on a zero-capability unit (err=%v)", err)
	}
}

func TestUnitDropinIsRegistered(t *testing.T) {
	r := tasks.NewRegistry()
	RegisterDefaults(r, tasks.Dependencies{MountRunner: &mount.RecorderRunner{}})
	if _, ok := r.Lookup("unit.dropin"); !ok {
		t.Fatal("unit.dropin is not registered by RegisterDefaults")
	}
}

// Item 10: a ReadWritePaths entry is judged where it RESOLVES on the node, not
// only as a string: a symlink under /persist into the agent's trust material,
// or out of /persist, is refused. A path that does not exist yet passes (the
// rendered '-' lets the unit start without it); an absent leaf under an
// existing symlinked parent is judged by where that parent resolves.
func TestUnitDropinRefusesAReadWritePathThatResolvesIntoTrustMaterial(t *testing.T) {
	sb := newDropinSandbox(t)
	fsRoot := filepath.Join(filepath.Dir(sb.root), "fsroot")
	for _, d := range []string{"persist/var/lib/powernode/pki", "persist/var/lib/app", "etc"} {
		if err := os.MkdirAll(filepath.Join(fsRoot, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Cleanup(SetDropinFSRootForTest(fsRoot))
	link := func(name, target string) {
		t.Helper()
		if err := os.Symlink(target, filepath.Join(fsRoot, "persist", name)); err != nil {
			t.Fatal(err)
		}
	}
	link("innocent", filepath.Join(fsRoot, "persist/var/lib/powernode/pki")) // absolute, into trust
	link("relative", "var/lib/powernode")                                    // relative, into trust
	link("escape", filepath.Join(fsRoot, "etc"))                             // out of /persist
	link("fine", filepath.Join(fsRoot, "persist/var/lib/app"))               // stays in bounds

	paths := func(value string) map[string]any { return applyOptions("rw", directive("ReadWritePaths", value)) }

	for _, value := range []string{"/persist/innocent", "/persist/relative", "/persist/escape", "/persist/relative/pki/new-dir", "/persist/var/lib/app /persist/innocent"} {
		if _, err := sb.run(paths(value)); !errors.Is(err, taskguard.ErrRefused) {
			t.Errorf("ReadWritePaths=%s accepted (err=%v)", value, err)
		}
	}
	for _, value := range []string{"/persist/fine", "/persist/var/lib/app", "/persist/not-yet/created"} {
		if _, err := sb.run(paths(value)); err != nil {
			t.Errorf("ReadWritePaths=%s refused: %v", value, err)
		}
	}
}
