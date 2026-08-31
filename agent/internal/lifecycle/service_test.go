package lifecycle

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// Plan reference: P8.1 — service lifecycle test suite. Each test
// uses RecorderRunner to assert shell-out shape without invoking
// systemd, and POWERNODE_LIFECYCLE_UNIT_DIR to write to a per-test
// tmpdir so the host's real /etc/systemd/system stays untouched.

func setUnitDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", dir)
	return dir
}

func TestRenderUnit_FullDirective_Mapping(t *testing.T) {
	svc := manifest.Service{
		Name:             "postgres",
		StartCommand:     "/usr/bin/postgres -D /var/lib/postgresql",
		StopCommand:      "/usr/bin/pg_ctl stop -m fast",
		RestartPolicy:    "always",
		User:             "postgres",
		WorkingDirectory: "/var/lib/postgresql",
		Env:              map[string]string{"PGDATA": "/var/lib/postgresql", "LANG": "en_US.UTF-8"},
		Dependencies:     []string{"redis"},
	}
	got := RenderUnit(svc, "mod-123")

	wants := []string{
		"Description=Powernode service postgres (module mod-123)",
		"After=powernode-mod-123-redis.service",
		"Requires=powernode-mod-123-redis.service",
		"User=postgres",
		"WorkingDirectory=/var/lib/postgresql",
		"Environment=LANG=en_US.UTF-8", // sorted by key
		"Environment=PGDATA=/var/lib/postgresql",
		"ExecStart=/usr/bin/postgres -D /var/lib/postgresql",
		"ExecStop=/usr/bin/pg_ctl stop -m fast",
		"Restart=always",
		"WantedBy=multi-user.target",
	}
	for _, want := range wants {
		if !strings.Contains(got, want) {
			t.Errorf("expected %q in unit body:\n%s", want, got)
		}
	}
}

func TestRenderUnit_RestartPolicyMapping(t *testing.T) {
	cases := []struct {
		policy string
		want   string
	}{
		{"always", "Restart=always"},
		{"on-failure", "Restart=on-failure"},
		{"never", "Restart=no"},
		{"", "Restart=on-failure"}, // safe default
		{"garbage", "Restart=on-failure"},
	}
	for _, c := range cases {
		got := RenderUnit(manifest.Service{Name: "x", StartCommand: "/bin/true", RestartPolicy: c.policy}, "m")
		if !strings.Contains(got, c.want) {
			t.Errorf("policy=%q: missing %q in:\n%s", c.policy, c.want, got)
		}
	}
}

// TestRenderUnit_StateDirectoryForVarLibWorkingDir pins the fix for
// pivot-booted fleet nodes: mkfs.erofs --all-root drops /var entirely
// from the composed module union, so a plain WorkingDirectory= under
// /var/lib is never created and a non-root User= hits EACCES/200-CHDIR.
// StateDirectory= makes systemd itself create + chown the dir at start
// (ownership resolved by name against the live passwd, never baked
// numerically). Only fires when User= is set AND WorkingDirectory is
// under /var/lib — e.g. reverse-proxy-traefik's /etc/traefik working
// dir, or a service with no User=, must NOT get it.
func TestRenderUnit_StateDirectoryForVarLibWorkingDir(t *testing.T) {
	cases := []struct {
		name    string
		svc     manifest.Service
		wantDir string // "" means StateDirectory= must NOT appear
	}{
		{
			name: "user set, working dir under /var/lib",
			svc: manifest.Service{
				Name: "vector", StartCommand: "/usr/bin/vector",
				User: "vector", WorkingDirectory: "/var/lib/vector",
			},
			wantDir: "vector",
		},
		{
			name: "user set, working dir under /var/lib (prometheus)",
			svc: manifest.Service{
				Name: "node-exporter", StartCommand: "/usr/bin/prometheus-node-exporter",
				User: "prometheus", WorkingDirectory: "/var/lib/prometheus",
			},
			wantDir: "prometheus",
		},
		{
			name: "user set, working dir elsewhere (not /var/lib)",
			svc: manifest.Service{
				Name: "traefik", StartCommand: "/usr/bin/traefik",
				User: "traefik", WorkingDirectory: "/etc/traefik",
			},
			wantDir: "",
		},
		{
			name: "no user set — never emit StateDirectory even under /var/lib",
			svc: manifest.Service{
				Name: "anon", StartCommand: "/usr/bin/anon",
				WorkingDirectory: "/var/lib/anon",
			},
			wantDir: "",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := RenderUnit(tc.svc, "mod-x")
			if tc.wantDir == "" {
				if strings.Contains(got, "StateDirectory=") {
					t.Errorf("did not expect StateDirectory= in output:\n%s", got)
				}
				return
			}
			want := "StateDirectory=" + tc.wantDir
			if !strings.Contains(got, want) {
				t.Errorf("expected %q in unit body:\n%s", want, got)
			}
		})
	}
}

// TestRenderUnitMode_UnitBodyPassthrough confirms a unit_body service's
// body is emitted verbatim (option A2 — dev-cell/claude-tmux's shape),
// with no generated ExecStart=/Type=/Restart= directives, and no
// generated [Install] section (the body's own WantedBy= governs).
func TestRenderUnitMode_UnitBodyPassthrough(t *testing.T) {
	body := "[Unit]\nDescription=Claude tmux session\nAfter=network-online.target\n\n" +
		"[Service]\nType=oneshot\nRemainAfterExit=yes\nUser=pnadmin\nExecStart=/usr/local/bin/claude-tmux-start.sh\n\n" +
		"[Install]\nWantedBy=multi-user.target\n"
	svc := manifest.Service{Name: "claude", UnitBody: body, StartCommand: ""}
	got := RenderUnitMode(svc, "mod-123", RootModeNative)

	if !strings.Contains(got, "# Managed by powernode-agent") {
		t.Errorf("expected managed-by header, got:\n%s", got)
	}
	if !strings.Contains(got, body) {
		t.Errorf("expected verbatim unit_body content in output:\n%s", got)
	}
	for _, unwanted := range []string{"ExecStart=/bin/", "Type=simple\n", "Restart=always\n", "RestartSec=5s"} {
		if strings.Contains(got, unwanted) {
			t.Errorf("did not expect generated directive %q in unit_body output:\n%s", unwanted, got)
		}
	}
	// Only one [Install] section — the body's own, nothing appended.
	if strings.Count(got, "[Install]") != 1 {
		t.Errorf("expected exactly one [Install] section, got:\n%s", got)
	}
}

// TestRenderUnitMode_UnitBodyDependencies confirms Dependencies are
// still emitted as an appended [Unit] section naming the generated
// powernode-<id>-<name>.service units — identical resolution to the
// non-unit_body path — even though the body itself carries no sibling
// After=/Requires= lines.
func TestRenderUnitMode_UnitBodyDependencies(t *testing.T) {
	body := "[Unit]\nDescription=x\n\n[Service]\nType=oneshot\nExecStart=/bin/true\n\n[Install]\nWantedBy=multi-user.target\n"
	svc := manifest.Service{Name: "provision", UnitBody: body, Dependencies: []string{"bootstrap"}}
	got := RenderUnitMode(svc, "mod-abc", RootModeNative)

	wantAfter := "After=powernode-mod-abc-bootstrap.service"
	wantRequires := "Requires=powernode-mod-abc-bootstrap.service"
	if !strings.Contains(got, wantAfter) {
		t.Errorf("expected %q in:\n%s", wantAfter, got)
	}
	if !strings.Contains(got, wantRequires) {
		t.Errorf("expected %q in:\n%s", wantRequires, got)
	}
	// The appended section, not the verbatim body's own [Unit] header —
	// there should be two [Unit] occurrences: the body's and the appended one.
	if strings.Count(got, "[Unit]") != 2 {
		t.Errorf("expected the body's [Unit] section plus one appended dependency [Unit] section, got:\n%s", got)
	}
}

// TestRenderUnitMode_UnitBodyChrootAppendsServiceSection confirms
// RootModeChroot appends a [Service] section with the same chroot
// directives the generated path emits, so a unit_body service's
// ExecStart (inside the verbatim body) still resolves against /sysroot.
// RootModeNative must NOT get this appended section.
func TestRenderUnitMode_UnitBodyChrootAppendsServiceSection(t *testing.T) {
	body := "[Unit]\nDescription=x\n\n[Service]\nType=oneshot\nExecStart=/bin/true\n\n[Install]\nWantedBy=multi-user.target\n"
	svc := manifest.Service{Name: "provision", UnitBody: body}

	chroot := RenderUnitMode(svc, "mod-abc", RootModeChroot)
	for _, want := range []string{"RootDirectory=/sysroot", "MountAPIVFS=yes", "BindReadOnlyPaths=/etc/passwd /etc/group /etc/shadow /etc/gshadow"} {
		if !strings.Contains(chroot, want) {
			t.Errorf("chroot mode: expected %q in:\n%s", want, chroot)
		}
	}
	// Two [Service] sections: the body's own, plus the appended chroot one.
	if strings.Count(chroot, "[Service]") != 2 {
		t.Errorf("chroot mode: expected the body's [Service] section plus one appended chroot [Service] section, got:\n%s", chroot)
	}

	native := RenderUnitMode(svc, "mod-abc", RootModeNative)
	if strings.Contains(native, "RootDirectory=/sysroot") {
		t.Errorf("native mode: did not expect chroot directives, got:\n%s", native)
	}
	if strings.Count(native, "[Service]") != 1 {
		t.Errorf("native mode: expected only the body's own [Service] section, got:\n%s", native)
	}
}

// TestRenderUnit_NonUnitBodyPathUnchanged is a regression guard: this
// function renders EVERY module's units fleet-wide, so adding the
// UnitBody branch must not alter output for services that don't declare
// it. Same assertions as TestRenderUnit_FullDirective_Mapping, run
// again after the unit_body branch exists, to catch any accidental
// shared-state or early-return regression in the refactor.
func TestRenderUnit_NonUnitBodyPathUnchanged(t *testing.T) {
	svc := manifest.Service{
		Name:             "postgres",
		StartCommand:     "/usr/bin/postgres -D /var/lib/postgresql",
		StopCommand:      "/usr/bin/pg_ctl stop -m fast",
		RestartPolicy:    "always",
		User:             "postgres",
		WorkingDirectory: "/var/lib/postgresql",
		Env:              map[string]string{"PGDATA": "/var/lib/postgresql", "LANG": "en_US.UTF-8"},
		Dependencies:     []string{"redis"},
	}
	got := RenderUnit(svc, "mod-123")
	if strings.Contains(got, "Managed by powernode-agent") {
		t.Errorf("non-unit_body service should use the generated header, not the unit_body one:\n%s", got)
	}
	wants := []string{
		"# Auto-generated by powernode-agent for module mod-123 / service postgres.",
		"Description=Powernode service postgres (module mod-123)",
		"After=powernode-mod-123-redis.service",
		"Requires=powernode-mod-123-redis.service",
		"Type=simple",
		"ExecStart=/usr/bin/postgres -D /var/lib/postgresql",
		"Restart=always",
		"WantedBy=multi-user.target",
	}
	for _, want := range wants {
		if !strings.Contains(got, want) {
			t.Errorf("expected %q in unit body:\n%s", want, got)
		}
	}
}

func TestTopoSort_LinearChain(t *testing.T) {
	services := []manifest.Service{
		{Name: "c", StartCommand: "/bin/true", Dependencies: []string{"b"}},
		{Name: "a", StartCommand: "/bin/true"},
		{Name: "b", StartCommand: "/bin/true", Dependencies: []string{"a"}},
	}
	ordered, err := topoSort(services)
	if err != nil {
		t.Fatalf("topoSort: %v", err)
	}
	names := []string{ordered[0].Name, ordered[1].Name, ordered[2].Name}
	want := []string{"a", "b", "c"}
	for i := range want {
		if names[i] != want[i] {
			t.Fatalf("order[%d]: got %q, want %q (full: %v)", i, names[i], want[i], names)
		}
	}
}

func TestTopoSort_StableOnTies(t *testing.T) {
	// Two independent services — sort by name asc deterministically.
	services := []manifest.Service{
		{Name: "z", StartCommand: "/bin/true"},
		{Name: "a", StartCommand: "/bin/true"},
		{Name: "m", StartCommand: "/bin/true"},
	}
	ordered, err := topoSort(services)
	if err != nil {
		t.Fatalf("topoSort: %v", err)
	}
	got := []string{ordered[0].Name, ordered[1].Name, ordered[2].Name}
	if got[0] != "a" || got[1] != "m" || got[2] != "z" {
		t.Errorf("expected stable a,m,z; got %v", got)
	}
}

func TestTopoSort_CycleDetected(t *testing.T) {
	services := []manifest.Service{
		{Name: "a", StartCommand: "/bin/true", Dependencies: []string{"b"}},
		{Name: "b", StartCommand: "/bin/true", Dependencies: []string{"a"}},
	}
	_, err := topoSort(services)
	if err == nil {
		t.Fatal("expected cycle error, got nil")
	}
	if !strings.Contains(err.Error(), "cycle") {
		t.Errorf("expected error to mention cycle, got %v", err)
	}
}

func TestTopoSort_UnknownDependencyIgnored(t *testing.T) {
	// Reference to a service not in the set — treated as unmet but
	// doesn't fail the topo (operator sees the warning in logs).
	services := []manifest.Service{
		{Name: "x", StartCommand: "/bin/true", Dependencies: []string{"nope"}},
	}
	ordered, err := topoSort(services)
	if err != nil {
		t.Fatalf("topoSort: %v", err)
	}
	if len(ordered) != 1 || ordered[0].Name != "x" {
		t.Fatalf("expected single x, got %+v", ordered)
	}
}

func TestAttachServices_WritesUnits_RunsReloadAndStart(t *testing.T) {
	dir := setUnitDir(t)
	r := &mount.RecorderRunner{}
	services := []manifest.Service{
		{Name: "redis", StartCommand: "/usr/bin/redis-server", RestartPolicy: "always"},
		{Name: "postgres", StartCommand: "/usr/bin/postgres", RestartPolicy: "always", Dependencies: []string{"redis"}},
	}

	results, err := AttachServices(context.Background(), r, "mod-x", services)
	if err != nil {
		t.Fatalf("attach: %v", err)
	}
	if len(results) != 2 {
		t.Fatalf("expected 2 results, got %d", len(results))
	}

	// Unit files exist on disk
	for _, name := range []string{"redis", "postgres"} {
		path := filepath.Join(dir, "powernode-mod-x-"+name+".service")
		if _, err := os.Stat(path); err != nil {
			t.Errorf("expected unit file %s to exist: %v", path, err)
		}
	}

	// Order asserted: daemon-reload, then start redis, then start postgres
	var ops []string
	for _, inv := range r.Invocations {
		ops = append(ops, inv.Name+" "+strings.Join(inv.Args, " "))
	}

	// Find the indexes
	var reloadIdx, redisStartIdx, postgresStartIdx int = -1, -1, -1
	for i, op := range ops {
		switch {
		case op == "systemctl daemon-reload":
			if reloadIdx < 0 {
				reloadIdx = i
			}
		case op == "systemctl start powernode-mod-x-redis.service":
			redisStartIdx = i
		case op == "systemctl start powernode-mod-x-postgres.service":
			postgresStartIdx = i
		}
	}
	if reloadIdx < 0 {
		t.Errorf("expected daemon-reload; ops: %v", ops)
	}
	if !(reloadIdx < redisStartIdx && redisStartIdx < postgresStartIdx) {
		t.Errorf("expected reload<redis<postgres order; reload=%d redis=%d postgres=%d", reloadIdx, redisStartIdx, postgresStartIdx)
	}
}

// readUnit returns the on-disk body of a written unit file.
func readUnit(t *testing.T, dir, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		t.Fatalf("read unit %s: %v", name, err)
	}
	return string(b)
}

// TestPivotAwareRootMode_ByRootFSType pins the corrected boot-model signal:
// native iff the running root "/" is the composed overlay union; chroot in
// the pre-pivot initramfs (rootfs/ramfs) and under cloud_init (ext4/xfs).
// The prior /persist-distinctness heuristic could not tell the pre-pivot
// initramfs (where /persist is ALSO a distinct mount) from the post-pivot
// union, and wrongly returned native there. This injects the root
// filesystem type to lock the corrected contract.
func TestPivotAwareRootMode_ByRootFSType(t *testing.T) {
	orig := rootFSType
	t.Cleanup(func() { rootFSType = orig })

	cases := []struct {
		name  string
		ftype int64
		err   error
		want  RootMode
	}{
		{"overlay union (post-switch_root)", overlayfsMagic, nil, RootModeNative},
		{"ramfs initramfs (pre-pivot)", 0x858458f6, nil, RootModeChroot},
		{"tmpfs initramfs (pre-pivot)", 0x01021994, nil, RootModeChroot},
		{"ext4 cloud_init guest", 0xef53, nil, RootModeChroot},
		{"statfs error falls back to chroot", 0, os.ErrNotExist, RootModeChroot},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			rootFSType = func(string) (int64, error) { return tc.ftype, tc.err }
			if got := PivotAwareRootMode(); got != tc.want {
				t.Errorf("PivotAwareRootMode() [%s] = %v; want %v", tc.name, got, tc.want)
			}
		})
	}
}

// TestAttachServicesMode_NativeOmitsSysroot proves the fix: a native-mode
// attach (post-pivot) renders units WITHOUT RootDirectory=/sysroot (which
// switch_root already consumed), while chroot-mode keeps it. Before the
// fix the reconcile path always rendered chroot, so post-pivot units
// pointed at a nonexistent /sysroot and never started.
func TestAttachServicesMode_NativeOmitsSysroot(t *testing.T) {
	svc := []manifest.Service{{Name: "redis", StartCommand: "/usr/bin/redis-server", RestartPolicy: "always"}}
	unit := "powernode-mod-x-redis.service"

	dirN := setUnitDir(t)
	if _, err := AttachServicesMode(context.Background(), &mount.RecorderRunner{}, "mod-x", svc, RootModeNative); err != nil {
		t.Fatalf("native attach: %v", err)
	}
	if body := readUnit(t, dirN, unit); strings.Contains(body, "RootDirectory=/sysroot") {
		t.Errorf("native-mode unit must NOT set RootDirectory=/sysroot:\n%s", body)
	}

	dirC := setUnitDir(t)
	if _, err := AttachServicesMode(context.Background(), &mount.RecorderRunner{}, "mod-x", svc, RootModeChroot); err != nil {
		t.Fatalf("chroot attach: %v", err)
	}
	if body := readUnit(t, dirC, unit); !strings.Contains(body, "RootDirectory=/sysroot") {
		t.Errorf("chroot-mode unit must set RootDirectory=/sysroot:\n%s", body)
	}

	// The compat AttachServices wrapper (used by the cloud_init `init`
	// CLI) must still default to chroot.
	dirD := setUnitDir(t)
	if _, err := AttachServices(context.Background(), &mount.RecorderRunner{}, "mod-x", svc); err != nil {
		t.Fatalf("default attach: %v", err)
	}
	if body := readUnit(t, dirD, unit); !strings.Contains(body, "RootDirectory=/sysroot") {
		t.Errorf("AttachServices (compat) must default to chroot:\n%s", body)
	}
}

func TestAttachServices_Idempotent_NoReloadOnUnchangedContent(t *testing.T) {
	_ = setUnitDir(t)
	services := []manifest.Service{
		{Name: "redis", StartCommand: "/usr/bin/redis-server", RestartPolicy: "always"},
	}

	// First attach
	r1 := &mount.RecorderRunner{}
	if _, err := AttachServices(context.Background(), r1, "mod-x", services); err != nil {
		t.Fatalf("attach1: %v", err)
	}
	// Second attach — content unchanged, expect no daemon-reload
	r2 := &mount.RecorderRunner{}
	if _, err := AttachServices(context.Background(), r2, "mod-x", services); err != nil {
		t.Fatalf("attach2: %v", err)
	}
	for _, inv := range r2.Invocations {
		if inv.Name == "systemctl" && len(inv.Args) > 0 && inv.Args[0] == "daemon-reload" {
			t.Errorf("expected no daemon-reload on second attach (idempotent), got %+v", r2.Invocations)
		}
	}
}

func TestDetachServices_ReverseOrder_ReloadsAfter(t *testing.T) {
	dir := setUnitDir(t)
	// Pre-create the unit files so detach has something to remove
	for _, name := range []string{"redis", "postgres"} {
		path := filepath.Join(dir, "powernode-mod-x-"+name+".service")
		if err := os.WriteFile(path, []byte("dummy"), 0o644); err != nil {
			t.Fatalf("setup: %v", err)
		}
	}

	r := &mount.RecorderRunner{}
	services := []manifest.Service{
		{Name: "redis", StartCommand: "/usr/bin/redis-server"},
		{Name: "postgres", StartCommand: "/usr/bin/postgres", Dependencies: []string{"redis"}},
	}
	if _, err := DetachServices(context.Background(), r, "mod-x", services); err != nil {
		t.Fatalf("detach: %v", err)
	}

	// Order: stop postgres, stop redis, daemon-reload (reverse topo + cleanup)
	var stopPgIdx, stopRedisIdx, reloadIdx int = -1, -1, -1
	for i, inv := range r.Invocations {
		joined := inv.Name + " " + strings.Join(inv.Args, " ")
		switch joined {
		case "systemctl stop powernode-mod-x-postgres.service":
			stopPgIdx = i
		case "systemctl stop powernode-mod-x-redis.service":
			stopRedisIdx = i
		case "systemctl daemon-reload":
			reloadIdx = i
		}
	}
	if stopPgIdx < 0 || stopRedisIdx < 0 || reloadIdx < 0 {
		t.Fatalf("missing stop/reload ops; invocations: %+v", r.Invocations)
	}
	if !(stopPgIdx < stopRedisIdx && stopRedisIdx < reloadIdx) {
		t.Errorf("expected postgres-stop < redis-stop < reload; pg=%d redis=%d reload=%d", stopPgIdx, stopRedisIdx, reloadIdx)
	}

	// Unit files removed
	for _, name := range []string{"redis", "postgres"} {
		path := filepath.Join(dir, "powernode-mod-x-"+name+".service")
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Errorf("expected %s to be removed after detach", path)
		}
	}
}

func TestAttachServices_NilRunner_Error(t *testing.T) {
	_, err := AttachServices(context.Background(), nil, "x", []manifest.Service{{Name: "a", StartCommand: "/bin/true"}})
	if err == nil {
		t.Fatal("expected nil-runner error")
	}
}

func TestAttachServices_EmptyServices_NoOp(t *testing.T) {
	r := &mount.RecorderRunner{}
	results, err := AttachServices(context.Background(), r, "x", nil)
	if err != nil {
		t.Fatalf("expected nil err, got %v", err)
	}
	if results != nil {
		t.Errorf("expected nil results on empty input, got %+v", results)
	}
	if len(r.Invocations) != 0 {
		t.Errorf("expected no shell-outs on empty input, got %+v", r.Invocations)
	}
}

// TestWriteDependencyDirectives_PerKind pins the EXACT directive block each
// dependency kind renders, as an EQUALITY over the whole block rather than a
// per-kind "contains Requires=" existence check.
//
// That distinction is the point of the test. The defect it was written for is
// precisely that all three kinds rendered IDENTICALLY as a hard Requires=, so
// an existence check ("start_before emits Requires=") passes on the broken
// code and proves nothing about whether kind is read at all.
//
// Kind semantics are specified by System::ModuleServiceDependency
// (server/app/models/system/module_service_dependency.rb:8-12):
//
//	start_before     target running before source starts    -> After= + Requires=
//	requires_health  target healthy before source starts    -> After= + Requires=
//	softdep          target preferred, explicitly NOT required -> After= + Wants=
//
// start_before and requires_health coincide DELIBERATELY: systemd has no
// notion of the agent's own health checks, so "healthy first" is not
// expressible as a directive distinct from "started first", and the strict
// form is the conservative reading. They are pinned as separate rows anyway,
// so a future divergence has to be a deliberate edit to this table rather
// than a silent side effect of touching the renderer.
func TestWriteDependencyDirectives_PerKind(t *testing.T) {
	cases := []struct {
		kind string
		want string
	}{
		{manifest.DependencyKindStartBefore, "After=powernode-mod-1-dep.service\nRequires=powernode-mod-1-dep.service\n"},
		{manifest.DependencyKindRequiresHealth, "After=powernode-mod-1-dep.service\nRequires=powernode-mod-1-dep.service\n"},
		{manifest.DependencyKindSoftdep, "After=powernode-mod-1-dep.service\nWants=powernode-mod-1-dep.service\n"},
	}
	rendered := make(map[string]string, len(cases))
	for _, tc := range cases {
		var b strings.Builder
		writeDependencyDirectives(&b, "mod-1", []manifest.DependencyEdge{{Service: "dep", Kind: tc.kind}})
		if got := b.String(); got != tc.want {
			t.Errorf("kind %q rendered:\n%q\nwant:\n%q", tc.kind, got, tc.want)
		}
		rendered[tc.kind] = b.String()
	}
	// The defect in its own words: kind was ignored, so every kind produced
	// the same block. softdep MUST NOT render like a hard requirement.
	if rendered[manifest.DependencyKindSoftdep] == rendered[manifest.DependencyKindStartBefore] {
		t.Errorf("softdep and start_before render identically (%q) — dependency kind is being ignored",
			rendered[manifest.DependencyKindSoftdep])
	}
}

// TestWriteDependencyDirectives_MixedKinds pins that one service carrying
// edges of different kinds splits them across Requires= and Wants= rather
// than collapsing every edge onto whichever directive the first edge chose,
// and that each directive lists its units sorted (stable output keeps
// writeIfChanged from re-attaching on a no-op reorder).
func TestWriteDependencyDirectives_MixedKinds(t *testing.T) {
	var b strings.Builder
	writeDependencyDirectives(&b, "m", []manifest.DependencyEdge{
		{Service: "zeta", Kind: manifest.DependencyKindSoftdep},
		{Service: "bravo", Kind: manifest.DependencyKindStartBefore},
		{Service: "alpha", Kind: manifest.DependencyKindSoftdep},
		{Service: "charlie", Kind: manifest.DependencyKindRequiresHealth},
	})
	want := "After=powernode-m-alpha.service powernode-m-bravo.service powernode-m-charlie.service powernode-m-zeta.service\n" +
		"Requires=powernode-m-bravo.service powernode-m-charlie.service\n" +
		"Wants=powernode-m-alpha.service powernode-m-zeta.service\n"
	if got := b.String(); got != want {
		t.Errorf("mixed-kind render:\n%q\nwant:\n%q", got, want)
	}
}

// TestWriteDependencyDirectives_UnknownKindIsStrict pins that an
// unrecognised kind renders as a hard Requires=, never as Wants= and never
// dropped. A newer server teaching the fleet a kind this agent has not
// learned must not silently downgrade a necessity guarantee.
func TestWriteDependencyDirectives_UnknownKindIsStrict(t *testing.T) {
	var b strings.Builder
	writeDependencyDirectives(&b, "m", []manifest.DependencyEdge{{Service: "dep", Kind: "some_future_kind"}})
	want := "After=powernode-m-dep.service\nRequires=powernode-m-dep.service\n"
	if got := b.String(); got != want {
		t.Errorf("unknown kind rendered:\n%q\nwant strict:\n%q", got, want)
	}
}

// TestResolvedDependencyEdges_LegacyNamesOnly pins the backward-compatibility
// contract: a payload from a server that emits only the names-only
// `dependencies` field renders EXACTLY as it did before dependency_edges
// existed — a hard Requires=. Wire-compat in the other direction (an older
// agent ignoring the new field) is a property of encoding/json, not of code
// this repo can assert here.
func TestResolvedDependencyEdges_LegacyNamesOnly(t *testing.T) {
	svc := manifest.Service{Name: "proxy", StartCommand: "/bin/true", Dependencies: []string{"bootstrap"}}
	edges := svc.ResolvedDependencyEdges()
	if len(edges) != 1 || edges[0].Service != "bootstrap" || edges[0].Kind != manifest.DefaultDependencyKind {
		t.Fatalf("legacy names-only fallback produced %+v", edges)
	}
	got := RenderUnit(svc, "mod-123")
	for _, want := range []string{"After=powernode-mod-123-bootstrap.service", "Requires=powernode-mod-123-bootstrap.service"} {
		if !strings.Contains(got, want) {
			t.Errorf("expected %q in legacy-payload unit body:\n%s", want, got)
		}
	}
	if strings.Contains(got, "Wants=powernode-mod-123-bootstrap.service") {
		t.Errorf("legacy names-only payload must not downgrade to Wants=:\n%s", got)
	}
}

// TestResolvedDependencyEdges_EdgesAreAuthoritative pins that when the
// kind-bearing field is present it WINS over the names-only field rather
// than being merged with it — a name left behind in `dependencies` must not
// resurrect an edge the server dropped from `dependency_edges`.
func TestResolvedDependencyEdges_EdgesAreAuthoritative(t *testing.T) {
	svc := manifest.Service{
		Name:            "proxy",
		StartCommand:    "/bin/true",
		Dependencies:    []string{"bootstrap", "stale"},
		DependencyEdges: []manifest.DependencyEdge{{Service: "bootstrap", Kind: manifest.DependencyKindSoftdep}},
	}
	got := RenderUnit(svc, "m")
	if strings.Contains(got, "stale") {
		t.Errorf("dropped edge resurrected from the names-only field:\n%s", got)
	}
	if !strings.Contains(got, "Wants=powernode-m-bootstrap.service") {
		t.Errorf("kind from dependency_edges not honoured:\n%s", got)
	}
	if strings.Contains(got, "Requires=powernode-m-bootstrap.service") {
		t.Errorf("softdep edge still rendered as a hard requirement:\n%s", got)
	}
}

// TestResolvedDependencyEdges_EmptyKindDefaults pins the contract for an
// edge that arrives in dependency_edges with no kind at all — a
// hand-written manifest entry, or a server that emits the field with a
// blank kind. It must be normalised to DefaultDependencyKind (the strict
// form), never left empty and never treated as soft.
//
// Added because a mutation that removed the defaulting SURVIVED the rest
// of this file: the empty string already falls through to Requires= by
// accident of the softdep-only branch, so the rendering looked correct
// while the documented normalisation was dead code.
func TestResolvedDependencyEdges_EmptyKindDefaults(t *testing.T) {
	svc := manifest.Service{
		Name:            "proxy",
		StartCommand:    "/bin/true",
		DependencyEdges: []manifest.DependencyEdge{{Service: "bootstrap"}},
	}
	edges := svc.ResolvedDependencyEdges()
	if len(edges) != 1 {
		t.Fatalf("expected 1 edge, got %+v", edges)
	}
	if edges[0].Kind != manifest.DefaultDependencyKind {
		t.Errorf("empty kind normalised to %q, want %q", edges[0].Kind, manifest.DefaultDependencyKind)
	}
	got := RenderUnit(svc, "m")
	if !strings.Contains(got, "Requires=powernode-m-bootstrap.service") {
		t.Errorf("empty-kind edge must render strict:\n%s", got)
	}
	if strings.Contains(got, "Wants=powernode-m-bootstrap.service") {
		t.Errorf("empty-kind edge must not render as best-effort:\n%s", got)
	}
}

// TestDependencyKindConstants_MatchWireValues pins the kind constants to
// their LITERAL wire values — the strings System::ModuleServiceDependency
// ::KINDS puts on the wire (server/app/models/system/
// module_service_dependency.rb:12).
//
// Every other test in this file compares rendering against the constants,
// which makes those assertions self-referential: a mutation renaming
// DependencyKindSoftdep's VALUE to "soft_dep" left the whole suite green
// while, on the wire, every softdep edge would have stopped matching and
// fallen back to a hard Requires= — silently reinstating the defect this
// file exists to prevent. This test is the only thing standing between
// that mutation and a green run.
func TestDependencyKindConstants_MatchWireValues(t *testing.T) {
	cases := []struct{ got, want string }{
		{manifest.DependencyKindStartBefore, "start_before"},
		{manifest.DependencyKindRequiresHealth, "requires_health"},
		{manifest.DependencyKindSoftdep, "softdep"},
		// The server's own import default: ManifestImportService uses
		// `dep.fetch("kind", "requires_health")`, so a kindless edge must
		// resolve to the same thing on both sides of the wire.
		{manifest.DefaultDependencyKind, "requires_health"},
	}
	for _, tc := range cases {
		if tc.got != tc.want {
			t.Errorf("kind constant is %q, want the wire value %q", tc.got, tc.want)
		}
	}
}

// TestRenderUnitMode_UnitBodyMixedKinds pins kind-awareness on the
// unit_body render path specifically, as an equality over the appended
// [Unit] block.
//
// This path carries the MAJORITY of the fleet's dependency edges —
// dev-cell (bootstrap/provision/mcp-proxy/credential/executor) and
// claude-tmux are all unit_body services — yet a mutation that made
// renderUnitBodyMode strict-convert every edge (ignoring kinds on that
// branch alone) survived the rest of this file, because the only
// unit_body dependency test used the legacy names-only field.
func TestRenderUnitMode_UnitBodyMixedKinds(t *testing.T) {
	body := "[Unit]\nDescription=x\n\n[Service]\nType=oneshot\nExecStart=/bin/true\n\n[Install]\nWantedBy=multi-user.target\n"
	svc := manifest.Service{
		Name:     "executor",
		UnitBody: body,
		DependencyEdges: []manifest.DependencyEdge{
			{Service: "bootstrap", Kind: manifest.DependencyKindStartBefore},
			{Service: "telemetry", Kind: manifest.DependencyKindSoftdep},
		},
	}
	got := RenderUnitMode(svc, "mod-abc", RootModeNative)
	wantBlock := "\n[Unit]\n" +
		"After=powernode-mod-abc-bootstrap.service powernode-mod-abc-telemetry.service\n" +
		"Requires=powernode-mod-abc-bootstrap.service\n" +
		"Wants=powernode-mod-abc-telemetry.service\n"
	if !strings.Contains(got, wantBlock) {
		t.Errorf("unit_body path did not honour dependency kinds.\nwant appended block:\n%q\ngot unit:\n%s", wantBlock, got)
	}
}
