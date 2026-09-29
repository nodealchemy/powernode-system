package handlers

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/runtime/tasks"
	"github.com/nodealchemy/powernode-system/agent/internal/taskguard"
)

// probe.node_inspect is a READ-ONLY, auto_approve verb that runs as root on the
// node. Every test here runs against an injected mount.RecorderRunner and a
// sandbox directory standing in for / and /proc: none of them executes wg, ip,
// nft, journalctl or systemctl, and none reads the real /etc, /proc or /persist.

// fakeKey is a 32-byte value in wg's own key encoding (44 base64 characters).
// It is not a real key, and no test here ever handles a real one.
func fakeKey(fill byte) string {
	b := make([]byte, 32)
	for i := range b {
		b[i] = fill
	}
	return base64.StdEncoding.EncodeToString(b)
}

// inspectSandbox is a fake host: fs stands in for "/", proc for "/proc".
type inspectSandbox struct {
	fs, proc string
}

func newInspectSandbox(t *testing.T) inspectSandbox {
	t.Helper()
	root := t.TempDir()
	// Resolve the tmp root itself: on some hosts $TMPDIR sits behind a symlink,
	// and the handler compares resolved paths against the resolved root.
	if real, err := filepath.EvalSymlinks(root); err == nil {
		root = real
	}
	sb := inspectSandbox{fs: filepath.Join(root, "fs"), proc: filepath.Join(root, "proc")}
	for _, d := range []string{sb.fs, filepath.Join(sb.proc, "self"), filepath.Join(root, "outside")} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	// The fake node has no mounts of its own until a test writes some.
	if err := os.WriteFile(filepath.Join(sb.proc, "self", "mountinfo"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	restore := SetInspectRootsForTest(sb.fs, sb.proc)
	t.Cleanup(restore)
	return sb
}

func (sb inspectSandbox) write(t *testing.T, logical, body string) string {
	t.Helper()
	p := filepath.Join(sb.fs, logical)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func (sb inspectSandbox) outside() string { return filepath.Join(filepath.Dir(sb.fs), "outside") }

func inspectTask(collector string, kv ...any) *tasks.Task {
	opts := map[string]any{"collector": collector}
	for i := 0; i+1 < len(kv); i += 2 {
		opts[kv[i].(string)] = kv[i+1]
	}
	return &tasks.Task{Command: "probe.node_inspect", Options: opts}
}

func runInspect(t *testing.T, rec *mount.RecorderRunner, task *tasks.Task) (map[string]any, error) {
	t.Helper()
	h := &ProbeNodeInspectHandler{deps: tasks.Dependencies{MountRunner: rec}}
	res, err := h.Execute(context.Background(), task)
	if err != nil {
		return nil, err
	}
	raw, mErr := json.Marshal(res)
	if mErr != nil {
		t.Fatalf("result is not JSON-encodable: %v", mErr)
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatal(err)
	}
	return out, nil
}

func mustRunInspect(t *testing.T, rec *mount.RecorderRunner, task *tasks.Task) map[string]any {
	t.Helper()
	out, err := runInspect(t, rec, task)
	if err != nil {
		t.Fatalf("expected a result, got error: %v", err)
	}
	return out
}

func resultText(t *testing.T, res map[string]any) string {
	t.Helper()
	raw, err := json.Marshal(res)
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

func sections(t *testing.T, res map[string]any) []map[string]any {
	t.Helper()
	raw, ok := res["sections"].([]any)
	if !ok {
		t.Fatalf("result has no sections array: %+v", res)
	}
	out := make([]map[string]any, 0, len(raw))
	for _, s := range raw {
		out = append(out, s.(map[string]any))
	}
	return out
}

func argvOf(rec *mount.RecorderRunner) []string {
	out := make([]string, 0, len(rec.Invocations))
	for _, inv := range rec.Invocations {
		out = append(out, strings.Join(append([]string{inv.Name}, inv.Args...), " "))
	}
	return out
}

func assertArgv(t *testing.T, rec *mount.RecorderRunner, want ...string) {
	t.Helper()
	got := argvOf(rec)
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("argv mismatch\n got: %q\nwant: %q", got, want)
	}
}

func assertRefused(t *testing.T, err error) {
	t.Helper()
	if !errors.Is(err, taskguard.ErrRefused) {
		t.Fatalf("expected a taskguard refusal, got %v", err)
	}
}

func assertNothingRan(t *testing.T, rec *mount.RecorderRunner) {
	t.Helper()
	if len(rec.Invocations) != 0 {
		t.Fatalf("a refused task must run nothing, ran %q", argvOf(rec))
	}
}

func assertNoWgDumpOrAll(t *testing.T, rec *mount.RecorderRunner) {
	t.Helper()
	for _, inv := range rec.Invocations {
		if inv.Name != "wg" {
			continue
		}
		for _, a := range inv.Args {
			if a == "dump" || a == "all" || a == "interfaces" || a == "showconf" || strings.HasSuffix(a, "-key") {
				t.Fatalf("wg must run only `wg show <interface>`, ran %q", argvOf(rec))
			}
		}
	}
}

// === wg_status ===

func wgOutput(priv, psk string) []byte {
	return []byte(strings.Join([]string{
		"interface: wg0",
		"  public key: " + fakeKey('P'),
		"  private key: " + priv,
		"  listening port: 51820",
		"",
		"peer: " + fakeKey('Q'),
		"  preshared key: " + psk,
		"  endpoint: 192.0.2.10:51820",
		"  allowed ips: 10.0.0.2/32",
		"  latest handshake: 12 seconds ago",
		"  transfer: 1.20 KiB received, 3.40 KiB sent",
		"",
	}, "\n"))
}

func TestNodeInspectWgStatusRunsOnlyWgShowInterface(t *testing.T) {
	rec := &mount.RecorderRunner{StubOutput: map[string][]byte{"wg show wg0": wgOutput("(hidden)", "(hidden)")}}
	res := mustRunInspect(t, rec, inspectTask("wg_status", "interface", "wg0"))

	assertArgv(t, rec, "wg show wg0")
	assertNoWgDumpOrAll(t, rec)
	text := resultText(t, res)
	for _, want := range []string{"listening port: 51820", "latest handshake: 12 seconds ago", "allowed ips: 10.0.0.2/32"} {
		if !strings.Contains(text, want) {
			t.Fatalf("wg_status lost %q: %s", want, text)
		}
	}
	if res["collector"] != "wg_status" || res["ok"] != true {
		t.Fatalf("unexpected envelope: %+v", res)
	}
}

// The planted private and preshared keys are the oracle: they are put in the
// command output the way `wg show <if> private-key` or a `dump` would print
// them, and neither may appear anywhere in the result. Public keys stay.
func TestNodeInspectWgStatusStripsPlantedKeyMaterial(t *testing.T) {
	priv, psk := fakeKey('X'), fakeKey('Y')
	out := string(wgOutput(priv, psk)) + "  debug: handshake with " + priv + " failed\n"
	rec := &mount.RecorderRunner{StubOutput: map[string][]byte{"wg show wg0": []byte(out)}}

	res := mustRunInspect(t, rec, inspectTask("wg_status", "interface", "wg0"))

	text := resultText(t, res)
	for name, secret := range map[string]string{"private key": priv, "preshared key": psk} {
		if strings.Contains(text, secret) {
			t.Fatalf("the planted %s survived into the result: %s", name, text)
		}
	}
	for _, kept := range []string{fakeKey('P'), fakeKey('Q')} {
		if !strings.Contains(text, kept) {
			t.Fatalf("a public key was stripped along with the secrets: %s", text)
		}
	}
	if strings.Contains(strings.ToLower(text), "private key:") || strings.Contains(strings.ToLower(text), "preshared key:") {
		t.Fatalf("a key line survived: %s", text)
	}
}

func TestNodeInspectWgStatusRefusesBadInterface(t *testing.T) {
	for name, v := range map[string]any{
		"all":         "all",
		"interfaces":  "interfaces",
		"option":      "--help",
		"dump form":   "wg0 dump",
		"path":        "../wg0",
		"empty":       "",
		"non string":  5,
		"too long":    strings.Repeat("a", 16),
		"missing key": nil,
	} {
		rec := &mount.RecorderRunner{}
		task := inspectTask("wg_status", "interface", v)
		if v == nil {
			task = inspectTask("wg_status")
		}
		_, err := runInspect(t, rec, task)
		if err == nil {
			t.Fatalf("%s: expected a refusal", name)
		}
		assertRefused(t, err)
		assertNothingRan(t, rec)
	}
}

// === routes ===

func TestNodeInspectRoutesIncludesVRFs(t *testing.T) {
	rec := &mount.RecorderRunner{StubOutput: map[string][]byte{
		"ip vrf show":                []byte("Name              Table\nvrf-mgmt          10\n"),
		"ip -4 route show table all": []byte("default via 10.0.0.1 dev eth0\n10.9.0.0/24 dev vrf-mgmt table 10\n"),
		"ip -6 route show table all": []byte("fe80::/64 dev eth0 proto kernel\n"),
		"ip -4 rule show":            []byte("0:\tfrom all lookup local\n"),
		"ip -6 rule show":            []byte("0:\tfrom all lookup local\n"),
	}}
	res := mustRunInspect(t, rec, inspectTask("routes"))

	assertArgv(t, rec, "ip vrf show", "ip -4 route show table all", "ip -6 route show table all",
		"ip -4 rule show", "ip -6 rule show")
	text := resultText(t, res)
	for _, want := range []string{"vrf-mgmt", "table 10", "default via 10.0.0.1"} {
		if !strings.Contains(text, want) {
			t.Fatalf("routes lost %q: %s", want, text)
		}
	}
	if len(sections(t, res)) != 5 {
		t.Fatalf("expected one section per command, got %d", len(sections(t, res)))
	}
}

func TestNodeInspectRoutesTakesNoArguments(t *testing.T) {
	rec := &mount.RecorderRunner{}
	_, err := runInspect(t, rec, inspectTask("routes", "vrf", "vrf-mgmt"))
	assertRefused(t, err)
	assertNothingRan(t, rec)
}

// === nft ===

func TestNodeInspectNftDefaultsToRuleset(t *testing.T) {
	rec := &mount.RecorderRunner{StubOutput: map[string][]byte{
		"nft list ruleset": []byte("table inet filter {\n\tchain input {\n\t\tpolicy drop\n\t}\n}\n"),
	}}
	res := mustRunInspect(t, rec, inspectTask("nft"))
	assertArgv(t, rec, "nft list ruleset")
	if !strings.Contains(resultText(t, res), "chain input") {
		t.Fatalf("ruleset missing: %+v", res)
	}
}

func TestNodeInspectNftChainsScope(t *testing.T) {
	rec := &mount.RecorderRunner{StubOutput: map[string][]byte{"nft list chains": []byte("table inet filter { chain input {} }\n")}}
	mustRunInspect(t, rec, inspectTask("nft", "scope", "chains"))
	assertArgv(t, rec, "nft list chains")
}

func TestNodeInspectNftRefusesOtherScopes(t *testing.T) {
	for _, v := range []any{"flush ruleset", "table inet filter", "", 3, "RULESET "} {
		rec := &mount.RecorderRunner{}
		_, err := runInspect(t, rec, inspectTask("nft", "scope", v))
		assertRefused(t, err)
		assertNothingRan(t, rec)
	}
}

// === journal ===

const loadedKey = "systemctl show -p LoadState --value sshd.service"

func loadedRunner(unit, state string) *mount.RecorderRunner {
	return &mount.RecorderRunner{StubOutput: map[string][]byte{
		"systemctl show -p LoadState --value " + unit: []byte(state + "\n"),
	}}
}

func TestNodeInspectJournalRunsCappedJournalctl(t *testing.T) {
	rec := loadedRunner("sshd.service", "loaded")
	rec.StubOutput["journalctl -u sshd.service -n 100 -r --no-pager -o short-iso"] = []byte("Sep 28 sshd[1]: Server listening\n")

	res := mustRunInspect(t, rec, inspectTask("journal", "unit", "sshd.service"))

	assertArgv(t, rec, loadedKey, "journalctl -u sshd.service -n 100 -r --no-pager -o short-iso")
	if !strings.Contains(resultText(t, res), "Server listening") {
		t.Fatalf("journal text missing: %+v", res)
	}
}

func TestNodeInspectJournalHonoursTheLineArgument(t *testing.T) {
	rec := loadedRunner("sshd.service", "loaded")
	res := mustRunInspect(t, rec, inspectTask("journal", "unit", "sshd.service", "lines", float64(5)))
	assertArgv(t, rec, loadedKey, "journalctl -u sshd.service -n 5 -r --no-pager -o short-iso")
	_ = res
}

func TestNodeInspectJournalRefusesBadLineCounts(t *testing.T) {
	for name, v := range map[string]any{
		"zero": float64(0), "negative": float64(-1), "over the cap": float64(501), "huge": float64(1e9),
		"fraction": 1.5, "string": "abc", "numeric string": "50", "bool": true,
	} {
		rec := loadedRunner("sshd.service", "loaded")
		_, err := runInspect(t, rec, inspectTask("journal", "unit", "sshd.service", "lines", v))
		if err == nil {
			t.Fatalf("%s: expected a refusal", name)
		}
		assertRefused(t, err)
		assertNothingRan(t, rec)
	}
	// The boundary itself is legal.
	rec := loadedRunner("sshd.service", "loaded")
	mustRunInspect(t, rec, inspectTask("journal", "unit", "sshd.service", "lines", float64(500)))
}

// The cap is enforced on what comes back, not only on what was asked for, so a
// journalctl that ignored -n cannot widen the result.
func TestNodeInspectJournalCapsTheLinesReturned(t *testing.T) {
	// journalctl -r prints the NEWEST line first.
	var b strings.Builder
	for i := 1000; i >= 1; i-- {
		fmt.Fprintf(&b, "line-%04d\n", i)
	}
	rec := loadedRunner("sshd.service", "loaded")
	rec.StubOutput["journalctl -u sshd.service -n 5 -r --no-pager -o short-iso"] = []byte(b.String())

	res := mustRunInspect(t, rec, inspectTask("journal", "unit", "sshd.service", "lines", float64(5)))

	text := resultText(t, res)
	if !strings.Contains(text, "line-1000") || !strings.Contains(text, "line-0996") {
		t.Fatalf("the newest 5 lines must be kept: %s", text)
	}
	if strings.Contains(text, "line-0995") || strings.Contains(text, "line-0001") {
		t.Fatalf("lines past the cap leaked: %s", text)
	}
}

func TestNodeInspectRefusesBadOrMissingUnits(t *testing.T) {
	for _, collector := range []string{"journal", "unit", "caps"} {
		for name, v := range map[string]any{
			"no suffix": "sshd", "option": "--all.service", "glob": "ssh*.service",
			"traversal": "../x.service", "space": "a b.service", "empty": "", "non string": 4,
		} {
			rec := &mount.RecorderRunner{}
			_, err := runInspect(t, rec, inspectTask(collector, "unit", v))
			if err == nil {
				t.Fatalf("%s/%s: expected a refusal", collector, name)
			}
			assertRefused(t, err)
			assertNothingRan(t, rec)
		}
		rec := &mount.RecorderRunner{}
		_, err := runInspect(t, rec, inspectTask(collector))
		if err == nil {
			t.Fatalf("%s without a unit: expected a refusal", collector)
		}
		assertRefused(t, err)
		assertNothingRan(t, rec)
	}
}

// A well-formed name that is not a unit on this node is refused after ONE
// existence probe, and the collector proper never runs.
func TestNodeInspectRefusesAUnitThatDoesNotExist(t *testing.T) {
	for _, collector := range []string{"journal", "unit", "caps"} {
		for _, state := range []string{"not-found", ""} {
			rec := loadedRunner("ghost.service", state)
			_, err := runInspect(t, rec, inspectTask(collector, "unit", "ghost.service"))
			assertRefused(t, err)
			assertArgv(t, rec, "systemctl show -p LoadState --value ghost.service")
		}
	}
}

// === unit ===

func TestNodeInspectUnitShowsFileAndDropIns(t *testing.T) {
	rec := loadedRunner("sshd.service", "loaded")
	rec.StubOutput["systemctl --no-pager cat sshd.service"] = []byte(
		"# /usr/lib/systemd/system/sshd.service\n[Service]\nExecStart=/usr/sbin/sshd -D\n" +
			"\n# /etc/systemd/system/sshd.service.d/override.conf\n[Service]\nRestart=always\n")

	res := mustRunInspect(t, rec, inspectTask("unit", "unit", "sshd.service"))

	assertArgv(t, rec, loadedKey, "systemctl --no-pager cat sshd.service")
	text := resultText(t, res)
	for _, want := range []string{"ExecStart=/usr/sbin/sshd -D", "override.conf", "Restart=always"} {
		if !strings.Contains(text, want) {
			t.Fatalf("unit lost %q: %s", want, text)
		}
	}
}

// Unit files carry secrets in Environment= lines; every collector's output goes
// through scrubSecrets before it leaves the node.
func TestNodeInspectScrubsSecretsFromUnitAndJournalText(t *testing.T) {
	pem := "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7\n-----END PRIVATE KEY-----"
	rec := loadedRunner("app.service", "loaded")
	rec.StubOutput["systemctl --no-pager cat app.service"] = []byte(
		"[Service]\nEnvironment=\"DB_PASSWORD=hunter2hunter2\"\nEnvironment=API_TOKEN=tok-abcdef123456\nExecStart=/usr/bin/app\n" + pem + "\n")
	rec.StubOutput["journalctl -u app.service -n 100 -r --no-pager -o short-iso"] = []byte(
		"Sep 28 app[1]: connecting with password=hunter2hunter2\nSep 28 app[1]: client_secret: s3cr3t-value-9\nSep 28 app[1]: ready\n")

	unit := mustRunInspect(t, rec, inspectTask("unit", "unit", "app.service"))
	journal := mustRunInspect(t, rec, inspectTask("journal", "unit", "app.service"))

	joined := resultText(t, unit) + resultText(t, journal)
	for _, secret := range []string{"hunter2hunter2", "tok-abcdef123456", "s3cr3t-value-9", "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcw"} {
		if strings.Contains(joined, secret) {
			t.Fatalf("secret %q survived scrubbing: %s", secret, joined)
		}
	}
	for _, kept := range []string{"ExecStart=/usr/bin/app", "ready"} {
		if !strings.Contains(joined, kept) {
			t.Fatalf("scrubbing over-redacted %q: %s", kept, joined)
		}
	}
}

// === caps ===

func writeProcStatus(t *testing.T, sb inspectSandbox, pid, body string) {
	t.Helper()
	dir := filepath.Join(sb.proc, pid)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "status"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestNodeInspectCapsReadsTheMainPidStatusOnly(t *testing.T) {
	sb := newInspectSandbox(t)
	writeProcStatus(t, sb, "4242", strings.Join([]string{
		"Name:\tsshd", "Uid:\t0\t0\t0\t0", "CapInh:\t0000000000000000", "CapPrm:\t0000000000003000",
		"CapEff:\t0000000000003000", "CapBnd:\t000001ffffffffff", "CapAmb:\t0000000000000000", "NoNewPrivs:\t1", "",
	}, "\n"))
	// The environ file is present in the fake /proc; it must never be read.
	if err := os.WriteFile(filepath.Join(sb.proc, "4242", "environ"), []byte("LEAKED_ENV=1"), 0o644); err != nil {
		t.Fatal(err)
	}
	rec := loadedRunner("sshd.service", "loaded")
	rec.StubOutput["systemctl show -p MainPID --value sshd.service"] = []byte("4242\n")

	res := mustRunInspect(t, rec, inspectTask("caps", "unit", "sshd.service"))

	assertArgv(t, rec, loadedKey, "systemctl show -p MainPID --value sshd.service")
	if res["main_pid"] != float64(4242) || res["cap_eff"] != "0000000000003000" || res["cap_bnd"] != "000001ffffffffff" {
		t.Fatalf("unexpected caps: %+v", res)
	}
	text := resultText(t, res)
	if !strings.Contains(text, "CAP_NET_ADMIN") || !strings.Contains(text, "CAP_NET_RAW") {
		t.Fatalf("effective set should be decoded to names (bits 12 and 13): %s", text)
	}
	if strings.Contains(text, "LEAKED_ENV") || strings.Contains(text, "Uid") || strings.Contains(text, "Name:") {
		t.Fatalf("only the capability lines may leave the status file: %s", text)
	}
}

func TestNodeInspectCapsForAStoppedUnit(t *testing.T) {
	sb := newInspectSandbox(t)
	_ = sb
	rec := loadedRunner("sshd.service", "loaded")
	rec.StubOutput["systemctl show -p MainPID --value sshd.service"] = []byte("0\n")

	res := mustRunInspect(t, rec, inspectTask("caps", "unit", "sshd.service"))
	if res["ok"] != false || !strings.Contains(resultText(t, res), "no main PID") {
		t.Fatalf("a unit with no main PID is an honest ok:false result: %+v", res)
	}
}

// The PID comes from systemctl, but it is spliced into a path: only digits.
func TestNodeInspectCapsRefusesAMalformedPid(t *testing.T) {
	newInspectSandbox(t)
	for _, pid := range []string{"../../etc", "12/../1", "-1", "12 13", "abc", "99999999999999999999"} {
		rec := loadedRunner("sshd.service", "loaded")
		rec.StubOutput["systemctl show -p MainPID --value sshd.service"] = []byte(pid + "\n")
		res := mustRunInspect(t, rec, inspectTask("caps", "unit", "sshd.service"))
		if res["ok"] != false || !strings.Contains(fmt.Sprint(res["error"]), "unusable MainPID") {
			t.Fatalf("pid %q: expected an unusable-MainPID result, got %+v", pid, res)
		}
		if _, has := res["main_pid"]; has {
			t.Fatalf("pid %q must not be reported or used: %+v", pid, res)
		}
	}
}

// === file_stat ===

func TestNodeInspectFileStatReturnsStatShaAndMtimeNeverContents(t *testing.T) {
	sb := newInspectSandbox(t)
	body := "TOP-SECRET-FILE-CONTENTS-DO-NOT-RETURN\n"
	p := sb.write(t, "etc/hostname", body)
	mtime := time.Date(2026, 9, 1, 12, 30, 0, 0, time.UTC)
	if err := os.Chtimes(p, mtime, mtime); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte(body))

	rec := &mount.RecorderRunner{}
	res := mustRunInspect(t, rec, inspectTask("file_stat", "path", "/etc/hostname"))

	assertNothingRan(t, rec) // a file read, never a command
	if res["type"] != "file" || res["size"] != float64(len(body)) {
		t.Fatalf("unexpected stat: %+v", res)
	}
	if res["sha256"] != hex.EncodeToString(sum[:]) {
		t.Fatalf("sha256 mismatch: %+v", res)
	}
	if res["mtime"] != "2026-09-01T12:30:00Z" || res["mtime_unix"] != float64(mtime.Unix()) {
		t.Fatalf("mtime mismatch: %+v", res)
	}
	if res["mode"] != "0644" {
		t.Fatalf("mode mismatch: %+v", res)
	}
	if strings.Contains(resultText(t, res), "TOP-SECRET-FILE-CONTENTS") {
		t.Fatalf("file_stat leaked file contents: %+v", res)
	}
}

func TestNodeInspectFileStatOfADirectoryHasNoHash(t *testing.T) {
	sb := newInspectSandbox(t)
	sb.write(t, "etc/systemd/system/a.service", "x")
	res := mustRunInspect(t, &mount.RecorderRunner{}, inspectTask("file_stat", "path", "/etc/systemd/system"))
	if res["type"] != "dir" {
		t.Fatalf("expected dir: %+v", res)
	}
	if _, has := res["sha256"]; has {
		t.Fatalf("a directory has no sha256: %+v", res)
	}
}

func TestNodeInspectFileStatOfAMissingPathIsAHonestResult(t *testing.T) {
	newInspectSandbox(t)
	res := mustRunInspect(t, &mount.RecorderRunner{}, inspectTask("file_stat", "path", "/etc/absent.conf"))
	if res["exists"] != false || res["ok"] != true {
		t.Fatalf("a missing file is exists:false, not an error: %+v", res)
	}
}

func TestNodeInspectFileStatSkipsTheHashOfAnOversizedFile(t *testing.T) {
	sb := newInspectSandbox(t)
	sb.write(t, "etc/big.bin", strings.Repeat("a", 2048))
	restore := SetInspectHashMaxBytesForTest(1024)
	defer restore()

	res := mustRunInspect(t, &mount.RecorderRunner{}, inspectTask("file_stat", "path", "/etc/big.bin"))
	if _, has := res["sha256"]; has || res["sha256_skipped"] == nil || res["size"] != float64(2048) {
		t.Fatalf("an oversized file is stat'ed but not hashed: %+v", res)
	}
}

// A FIFO opened for reading blocks forever; the handler must classify it before
// reading, and must not hang the agent's task loop.
func TestNodeInspectFileStatDoesNotBlockOnAFifo(t *testing.T) {
	sb := newInspectSandbox(t)
	fifo := filepath.Join(sb.fs, "etc", "pipe")
	if err := os.MkdirAll(filepath.Dir(fifo), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := syscall.Mkfifo(fifo, 0o644); err != nil {
		t.Skipf("cannot create a fifo here: %v", err)
	}
	done := make(chan map[string]any, 1)
	go func() {
		res, _ := runInspect(t, &mount.RecorderRunner{}, inspectTask("file_stat", "path", "/etc/pipe"))
		done <- res
	}()
	select {
	case res := <-done:
		if _, has := res["sha256"]; has || res["type"] != "other" {
			t.Fatalf("a fifo is neither read nor hashed: %+v", res)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("file_stat blocked on a fifo")
	}
}

func TestNodeInspectFileStatRefusesEscapesAndSecrets(t *testing.T) {
	sb := newInspectSandbox(t)
	sb.write(t, "etc/shadow", "root:$6$abc:19000:0:99999:7:::\n")
	sb.write(t, "etc/hostname", "node\n")
	sb.write(t, "proc/1/environ", "SECRET_ENV=1")
	if err := os.WriteFile(filepath.Join(sb.outside(), "secret.txt"), []byte("outside-secret"), 0o644); err != nil {
		t.Fatal(err)
	}

	for name, p := range map[string]string{
		"dotdot":            "/etc/../etc/hostname",
		"dotdot out":        "/etc/../../outside/secret.txt",
		"relative":          "etc/hostname",
		"empty":             "",
		"shadow":            "/etc/shadow",
		"proc environ":      "/proc/1/environ",
		"proc self environ": "/proc/self/environ",
		"pki":               "/persist/var/lib/powernode/pki/node.key",
		"ssh host key":      "/etc/ssh/ssh_host_ed25519_key",
		"credential file":   "/etc/powernode/credentials.json",
		"root home":         "/root/.bash_history",
		"newline injection": "/etc/hostname\n/etc/shadow",
	} {
		rec := &mount.RecorderRunner{}
		res, err := runInspect(t, rec, inspectTask("file_stat", "path", p))
		if err == nil {
			t.Fatalf("%s: expected a refusal, got %+v", name, res)
		}
		assertRefused(t, err)
		assertNothingRan(t, rec)
	}
}

func TestNodeInspectFileStatDoesNotFollowSymlinksOutOfTheAllowedSet(t *testing.T) {
	sb := newInspectSandbox(t)
	outsideFile := filepath.Join(sb.outside(), "secret.txt")
	if err := os.WriteFile(outsideFile, []byte("outside-secret"), 0o644); err != nil {
		t.Fatal(err)
	}
	sb.write(t, "etc/shadow", "root:$6$abc:19000:0:99999:7:::\n")
	sb.write(t, "etc/real.conf", "fine\n")
	sb.write(t, "proc/1/environ", "SECRET_ENV=1")
	etc := filepath.Join(sb.fs, "etc")

	// Link NAMES are neutral on purpose: a name containing "shadow" would be
	// refused by the textual rule before the link was ever resolved, and the
	// resolved-path rule under test would never run.
	escapes := []struct{ name, target, wantInError string }{
		{"lk-rel-escape", "../../outside/secret.txt", "outside the node root"},
		{"lk-abs-escape", outsideFile, "outside the node root"},
		{"lk-dir-escape", "../../outside", "outside the node root"},
		{"lk-to-secret", "shadow", "secret location"},
		{"lk-to-proc", "../proc/1/environ", "not under a path"},
	}
	for _, l := range escapes {
		if err := os.Symlink(l.target, filepath.Join(etc, l.name)); err != nil {
			t.Fatal(err)
		}
		res, err := runInspect(t, &mount.RecorderRunner{}, inspectTask("file_stat", "path", "/etc/"+l.name))
		if err == nil {
			t.Fatalf("%s: a symlink out of the allowed set must be refused, got %+v", l.name, res)
		}
		assertRefused(t, err)
		if !strings.Contains(err.Error(), l.wantInError) {
			t.Fatalf("%s: refused for the wrong reason (want %q): %v", l.name, l.wantInError, err)
		}
	}
	// Through a directory link, too.
	if err := os.Symlink("../../outside", filepath.Join(etc, "lk-dir")); err != nil {
		t.Fatal(err)
	}
	_, err := runInspect(t, &mount.RecorderRunner{}, inspectTask("file_stat", "path", "/etc/lk-dir/secret.txt"))
	assertRefused(t, err)

	// A dangling link is an honest "no such file"; a loop is refused. Neither hashes anything.
	if err := os.Symlink("nowhere", filepath.Join(etc, "lk-dangling")); err != nil {
		t.Fatal(err)
	}
	res := mustRunInspect(t, &mount.RecorderRunner{}, inspectTask("file_stat", "path", "/etc/lk-dangling"))
	if res["exists"] != false {
		t.Fatalf("a dangling link does not exist: %+v", res)
	}
	if err := os.Symlink("lk-loop-b", filepath.Join(etc, "lk-loop-a")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("lk-loop-a", filepath.Join(etc, "lk-loop-b")); err != nil {
		t.Fatal(err)
	}
	_, err = runInspect(t, &mount.RecorderRunner{}, inspectTask("file_stat", "path", "/etc/lk-loop-a"))
	assertRefused(t, err)

	// A link that stays inside the allowed set is followed, and reports where it went.
	if err := os.Symlink("real.conf", filepath.Join(etc, "alias.conf")); err != nil {
		t.Fatal(err)
	}
	res = mustRunInspect(t, &mount.RecorderRunner{}, inspectTask("file_stat", "path", "/etc/alias.conf"))
	if res["resolved_path"] != "/etc/real.conf" || res["type"] != "file" || res["sha256"] == nil {
		t.Fatalf("an in-set symlink resolves to its target: %+v", res)
	}
}

// === envelope, bounds, failure shapes ===

func TestNodeInspectRefusesUnknownOrMissingCollector(t *testing.T) {
	for name, task := range map[string]*tasks.Task{
		"unknown":    inspectTask("ssh"),
		"shell":      inspectTask("sh", "command", "id"),
		"empty":      inspectTask(""),
		"cased":      inspectTask("WG_STATUS", "interface", "wg0"),
		"dump":       inspectTask("wg_dump", "interface", "wg0"),
		"no options": {Command: "probe.node_inspect"},
		"non string": {Command: "probe.node_inspect", Options: map[string]any{"collector": 7}},
	} {
		rec := &mount.RecorderRunner{}
		_, err := runInspect(t, rec, task)
		if err == nil {
			t.Fatalf("%s: expected a refusal", name)
		}
		assertRefused(t, err)
		assertNothingRan(t, rec)
	}
}

// No collector takes a free-form command, path or flag: a key it does not
// declare is refused rather than ignored.
func TestNodeInspectRefusesOptionsTheCollectorDoesNotDeclare(t *testing.T) {
	newInspectSandbox(t)
	for name, task := range map[string]*tasks.Task{
		"command on wg":     inspectTask("wg_status", "interface", "wg0", "command", "wg show all dump"),
		"argv on nft":       inspectTask("nft", "args", []any{"-f", "x"}),
		"path on journal":   inspectTask("journal", "unit", "a.service", "path", "/etc/shadow"),
		"lines on caps":     inspectTask("caps", "unit", "a.service", "lines", float64(3)),
		"interface on file": inspectTask("file_stat", "path", "/etc/hostname", "interface", "wg0"),
		"sudo":              inspectTask("routes", "sudo", true),
	} {
		rec := &mount.RecorderRunner{}
		_, err := runInspect(t, rec, task)
		if err == nil {
			t.Fatalf("%s: expected a refusal", name)
		}
		assertRefused(t, err)
		assertNothingRan(t, rec)
	}
}

func TestNodeInspectBoundsEachCollectorsOutput(t *testing.T) {
	huge := strings.Repeat("x", 100)
	var b strings.Builder
	for i := 0; b.Len() < 1<<20; i++ {
		fmt.Fprintf(&b, "%06d %s\n", i, huge)
	}
	rec := &mount.RecorderRunner{StubOutput: map[string][]byte{"nft list ruleset": []byte(b.String())}}

	res := mustRunInspect(t, rec, inspectTask("nft"))

	sec := sections(t, res)[0]
	out := sec["output"].(string)
	if len(out) > inspectMaxOutputBytes+256 {
		t.Fatalf("output must be bounded near %d bytes, got %d", inspectMaxOutputBytes, len(out))
	}
	if sec["truncated"] != true {
		t.Fatalf("a bounded section must say so: %+v", sec)
	}
	if !strings.HasPrefix(out, "000000 ") {
		t.Fatalf("a static dump keeps its head")
	}
}

func TestNodeInspectBoundsTheJournalFromTheEnd(t *testing.T) {
	// journalctl -r prints the NEWEST entry first; entry-000001 is the newest.
	var b strings.Builder
	for i := 1; b.Len() < 400_000; i++ {
		fmt.Fprintf(&b, "entry-%06d %s\n", i, strings.Repeat("y", 200))
	}
	rec := loadedRunner("sshd.service", "loaded")
	rec.StubOutput["journalctl -u sshd.service -n 500 -r --no-pager -o short-iso"] = []byte(b.String())

	res := mustRunInspect(t, rec, inspectTask("journal", "unit", "sshd.service", "lines", float64(500)))

	out := sections(t, res)[0]["output"].(string)
	if len(out) > inspectMaxOutputBytes+256 {
		t.Fatalf("journal output must be bounded, got %d", len(out))
	}
	if !strings.Contains(out, "entry-000001 ") {
		t.Fatalf("a journal keeps its NEWEST lines when bounded")
	}
	if strings.Contains(out, "entry-000450 ") {
		t.Fatalf("the oldest lines should have been cut")
	}
	if strings.Index(out, "entry-000005 ") > strings.Index(out, "entry-000001 ") {
		t.Fatalf("lines must be returned oldest-first (chronological), got newest-first")
	}
}

// A collector whose tool fails (nft not installed, wg module absent) is an
// honest ok:false result carrying the error, not a task failure.
func TestNodeInspectATooling_FailureIsAnHonestResult(t *testing.T) {
	rec := &mount.RecorderRunner{StubErr: map[string]error{
		"nft list ruleset": errors.New("nft [list ruleset]: exit status 127 (stderr: nft: command not found; token=abcd1234efgh)"),
	}}
	res := mustRunInspect(t, rec, inspectTask("nft"))

	if res["ok"] != false {
		t.Fatalf("expected ok:false: %+v", res)
	}
	text := resultText(t, res)
	if !strings.Contains(text, "command not found") {
		t.Fatalf("the failure reason should be reported: %s", text)
	}
	if strings.Contains(text, "abcd1234efgh") {
		t.Fatalf("error text must be scrubbed too: %s", text)
	}
}

func TestNodeInspectNeedsARunner(t *testing.T) {
	h := &ProbeNodeInspectHandler{deps: tasks.Dependencies{}}
	if _, err := h.Execute(context.Background(), inspectTask("routes")); err == nil {
		t.Fatal("expected an error without a mount runner")
	}
}

func TestNodeInspectIsRegisteredAsAProbe(t *testing.T) {
	r := tasks.NewRegistry()
	RegisterProbeNodeInspect(r, tasks.Dependencies{})
	if _, ok := r.Lookup("probe.node_inspect"); !ok {
		t.Fatal("probe.node_inspect is not registered")
	}
}

// The collectors are a fixed allow-list: this pins the set so that adding a
// fifth verb is a deliberate edit of the mirrored server list, not a drive-by.
func TestNodeInspectCollectorSetIsFixed(t *testing.T) {
	want := []string{"caps", "file_stat", "journal", "nft", "routes", "unit", "wg_status"}
	got := nodeInspectCollectorNames()
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("collector set changed: got %v want %v", got, want)
	}
}

// === IMP-52762a704a3d review round: scrub shapes, bounded reads, wedge-proof file_stat ===

// The token-shaped fixtures below are ASSEMBLED AT RUNTIME, so no complete
// token-shaped literal exists in this file: a literal would trip the repo's
// gitleaks gate and, once mirrored, GitHub push protection and secret scanning.
// Every one is fake (each carries a FAKE marker where the shape allows) and the
// scrubber patterns see exactly the same text as before.
var (
	fixtureJWT      = "ey" + "J" + "FAKEheader0123" + "." + "ey" + "J" + "FAKEpayload012" + "." + "FAKEsignature0123"
	fixtureGHPat    = "gh" + "p_" + "FAKE" + strings.Repeat("A", 32)
	fixtureGHFine   = "github_" + "pat_" + strings.Repeat("A1b2C3d4E5", 8) + "AB"
	fixtureAWSKeyID = "AK" + "IA" + "FAKE" + strings.Repeat("A", 12)
	fixtureAWSSec   = strings.Repeat("A", 36) + "FAKE"
	fixtureSK       = "sk" + "-ant-" + "FAKE" + strings.Repeat("a", 28)
	fixtureHVS      = "hv" + "s." + "FAKE" + strings.Repeat("a", 20)
	fixtureCurlUser = "curl " + "-u deploy:"
)

// secretShapes are the credential shapes ShellOutputSanitizer (the server-side
// redactor) recognises. The agent scrubs BEFORE sending because the raw result
// is stored in the task's completed event; a shape only the server catches is a
// shape stored in the clear. Every case names the text that must SURVIVE too,
// so an over-eager scrub cannot pass by deleting the line.
var secretShapes = []struct{ name, line, secret, keep string }{
	{"env RAILS_MASTER_KEY", "Environment=RAILS_MASTER_KEY=0123456789abcdef0123456789abcdef", "0123456789abcdef0123456789abcdef", "RAILS_MASTER_KEY"},
	{"env JWT_SIGNING_KEY", "JWT_SIGNING_KEY=s1gn1ng-k3y-value-xyz", "s1gn1ng-k3y-value-xyz", "JWT_SIGNING_KEY"},
	{"env ENCRYPTION_KEY colon", "ENCRYPTION_KEY: enc-k3y-abcdef-1234", "enc-k3y-abcdef-1234", "ENCRYPTION_KEY"},
	{"env SECRET_KEY_BASE", "SECRET_KEY_BASE=sekret-base-abcdef123456", "sekret-base-abcdef123456", "SECRET_KEY_BASE"},
	{"env lowercase _key", "export signing_key=lower-signing-k3y-99", "lower-signing-k3y-99", "signing_key"},
	{"url userinfo", "fatal: unable to access https://ci-user:gh-pass-abc123xyz@git.example.com/org/repo.git", "gh-pass-abc123xyz", "git.example.com/org/repo.git"},
	{"authorization bearer", "Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345", "abcdefghijklmnopqrstuvwxyz012345", "Authorization"},
	{"authorization basic", "Authorization: Basic dXNlcjpzdXBlcnNlY3JldHBhc3M=", "dXNlcjpzdXBlcnNlY3JldHBhc3M=", "Authorization"},
	{"long flag --password", "ExecStart=/usr/bin/tool --password hunter2-flag-secret run", "hunter2-flag-secret", "ExecStart=/usr/bin/tool"},
	{"long flag --token", "app --token tok-flag-abcdef123456 --verbose", "tok-flag-abcdef123456", "--verbose"},
	{"long flag --api-key=", "app --api-key=ak-flag-abcdef123456 --verbose", "ak-flag-abcdef123456", "--verbose"},
	{"login -p", "docker login registry.example.com -u ci -p s3cret-login-pass", "s3cret-login-pass", "registry.example.com"},
	{"curl -u user:pass", fixtureCurlUser + "curl-pass-12345 https://example.com/x", "curl-pass-12345", "https://example.com/x"},
	{"bare jwt", "session " + fixtureJWT + " ok", fixtureJWT, "session"},
	{"github pat", "remote: " + fixtureGHPat + " denied", fixtureGHPat, "denied"},
	{"aws access key id", "key id " + fixtureAWSKeyID + " in use", fixtureAWSKeyID, "in use"},
	{"anthropic-style sk key", "using " + fixtureSK + " now", fixtureSK, "now"},
	{"vault token", "vault issued " + fixtureHVS + " to app", fixtureHVS, "to app"},
	{"x-vault-token header", "x-vault-token: vault-hdr-value-12345", "vault-hdr-value-12345", "x-vault-token"},
	{"aws secret access key", "aws_secret_" + "access_key = " + fixtureAWSSec, fixtureAWSSec, "aws_secret_"},
	{"github fine-grained pat", "auth failed " + fixtureGHFine + " done", fixtureGHFine, "done"},
	{"env KEY mid-name", "SIGNING_KEY_MATERIAL=km-abcdefgh12345", "km-abcdefgh12345", "SIGNING_KEY_MATERIAL"},
	{"netrc line", "machine git.example.com login ci password netrc-pass-12345", "netrc-pass-12345", "machine git.example.com"},
	{"json auth", `{"auth": "am9objpqb2huc3NlY3JldDEyMw==", "server": "reg.example.com"}`, "am9objpqb2huc3NlY3JldDEyMw==", "reg.example.com"},
}

func TestNodeInspectScrubsEverySecretShapeInUnitAndJournalText(t *testing.T) {
	for _, shape := range secretShapes {
		rec := loadedRunner("app.service", "loaded")
		rec.StubOutput["systemctl --no-pager cat app.service"] = []byte("[Service]\n" + shape.line + "\nRestart=always\n")
		rec.StubOutput["journalctl -u app.service -n 100 -r --no-pager -o short-iso"] = []byte("Sep 28 app[1]: " + shape.line + "\nSep 28 app[1]: started\n")

		unit := resultText(t, mustRunInspect(t, rec, inspectTask("unit", "unit", "app.service")))
		journal := resultText(t, mustRunInspect(t, rec, inspectTask("journal", "unit", "app.service")))

		for where, text := range map[string]string{"unit": unit, "journal": journal} {
			if strings.Contains(text, shape.secret) {
				t.Errorf("%s: secret shape %q survived in the %s result: %s", shape.name, shape.secret, where, text)
			}
			if !strings.Contains(text, shape.keep) {
				t.Errorf("%s: scrubbing removed %q from the %s result (over-redaction): %s", shape.name, shape.keep, where, text)
			}
		}
	}
}

// The scrub must not eat ordinary diagnostics: a redactor that guts prose teaches
// operators to distrust it.
func TestNodeInspectLeavesOrdinaryDiagnosticsAlone(t *testing.T) {
	lines := []string{
		"Started Session 3 of User root.",
		"mkdir -p /run/powernode/x",
		"sort -u /etc/hosts.list",
		"password authentication failed for user app",
		"sshd[123]: Accepted publickey for root from 192.0.2.1",
		"Failed to connect to https://example.com/health: connection refused",
		"Authorization required for this endpoint",
	}
	rec := loadedRunner("app.service", "loaded")
	rec.StubOutput["journalctl -u app.service -n 100 -r --no-pager -o short-iso"] = []byte(strings.Join(lines, "\n") + "\n")

	text := resultText(t, mustRunInspect(t, rec, inspectTask("journal", "unit", "app.service")))

	for _, l := range lines {
		if !strings.Contains(text, l) {
			t.Errorf("an ordinary line was altered: %q in %s", l, text)
		}
	}
}

func TestNodeInspectScrubsTheUnitExistenceErrorToo(t *testing.T) {
	rec := &mount.RecorderRunner{StubErr: map[string]error{
		"systemctl show -p LoadState --value app.service": errors.New("systemctl [show]: exit status 1 (stderr: Failed to connect; token=leaky-token-abc123)"),
	}}
	_, err := runInspect(t, rec, inspectTask("journal", "unit", "app.service"))
	if err == nil {
		t.Fatal("expected an error")
	}
	if strings.Contains(err.Error(), "leaky-token-abc123") {
		t.Fatalf("the unit-existence error echoed a secret: %v", err)
	}
}

// === bounded reads ===

func TestNodeInspectReadsEveryCommandThroughTheBoundedRunner(t *testing.T) {
	sb := newInspectSandbox(t)
	writeProcStatus(t, sb, "7", "CapEff:\t0000000000000000\n")
	for name, task := range map[string]*tasks.Task{
		"wg":      inspectTask("wg_status", "interface", "wg0"),
		"routes":  inspectTask("routes"),
		"nft":     inspectTask("nft"),
		"journal": inspectTask("journal", "unit", "a.service"),
		"unit":    inspectTask("unit", "unit", "a.service"),
	} {
		rec := loadedRunner("a.service", "loaded")
		mustRunInspect(t, rec, task)
		if len(rec.Invocations) == 0 {
			t.Fatalf("%s: nothing ran", name)
		}
		for _, inv := range rec.Invocations {
			if inv.Op != "OutputBounded" {
				t.Errorf("%s: %s ran unbounded (Op %s): a collector must read through the bounded runner", name, inv.Name, inv.Op)
			}
			if inv.Max <= 0 || inv.Max > inspectReadCapBytes {
				t.Errorf("%s: %s read cap %d is outside 1..%d", name, inv.Name, inv.Max, inspectReadCapBytes)
			}
		}
	}
}

// A runner that does not implement BoundedRunner still works; the bound then
// applies after the read, as before.
func TestNodeInspectFallsBackToOutputWhenTheRunnerIsNotBounded(t *testing.T) {
	inner := &mount.RecorderRunner{StubOutput: map[string][]byte{"nft list ruleset": []byte(strings.Repeat("r\n", 100_000))}}
	h := &ProbeNodeInspectHandler{deps: tasks.Dependencies{MountRunner: struct{ mount.Runner }{inner}}}

	res, err := h.Execute(context.Background(), inspectTask("nft"))
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(res)
	var m map[string]any
	_ = json.Unmarshal(raw, &m)
	sec := sections(t, m)[0]
	if sec["truncated"] != true || len(sec["output"].(string)) > inspectMaxOutputBytes+256 {
		t.Fatalf("the fallback must still bound the result: %+v", sec["truncated"])
	}
	if inner.Invocations[0].Op != "Output" {
		t.Fatalf("expected the unbounded fallback path, got %s", inner.Invocations[0].Op)
	}
}

func TestNodeInspectMarksATruncatedReadAndDropsItsPartialLine(t *testing.T) {
	var b strings.Builder
	for i := 0; b.Len() < 2*inspectReadCapBytes; i++ {
		fmt.Fprintf(&b, "%06d %s\n", i, strings.Repeat("z", 100))
	}
	rec := &mount.RecorderRunner{StubOutput: map[string][]byte{"nft list ruleset": []byte(b.String())}}

	res := mustRunInspect(t, rec, inspectTask("nft"))

	sec := sections(t, res)[0]
	if sec["truncated"] != true {
		t.Fatalf("a read that hit the cap must be marked truncated: %+v", sec)
	}
	out := sec["output"].(string)
	body := strings.TrimSuffix(out, "\n[truncated]")
	for _, line := range strings.Split(strings.TrimRight(body, "\n"), "\n") {
		if len(line) != 6+1+100 {
			t.Fatalf("a partial line survived the cut: %q", line)
		}
	}
	if rec.Invocations[0].Max > inspectReadCapBytes {
		t.Fatalf("read cap %d exceeds %d", rec.Invocations[0].Max, inspectReadCapBytes)
	}
}

// journalctl -r prints the newest line first, so a read cut at the cap loses the
// OLDEST lines, and the result is turned back into chronological order.
func TestNodeInspectJournalReadsNewestFirstAndReturnsChronologically(t *testing.T) {
	var b strings.Builder
	for i := 1; i <= 8; i++ {
		fmt.Fprintf(&b, "entry-%02d\n", 9-i) // entry-08 first (newest) ... entry-01 last
	}
	rec := loadedRunner("sshd.service", "loaded")
	rec.StubOutput["journalctl -u sshd.service -n 8 -r --no-pager -o short-iso"] = []byte(b.String())

	res := mustRunInspect(t, rec, inspectTask("journal", "unit", "sshd.service", "lines", float64(8)))

	out := sections(t, res)[0]["output"].(string)
	if out != "entry-01\nentry-02\nentry-03\nentry-04\nentry-05\nentry-06\nentry-07\nentry-08\n" {
		t.Fatalf("expected chronological order, got %q", out)
	}
}

func TestNodeInspectJournalMarksOlderOutputOmittedWhenTheReadIsCut(t *testing.T) {
	var b strings.Builder
	for i := 1; b.Len() < 2*inspectReadCapBytes; i++ {
		fmt.Fprintf(&b, "entry-%07d %s\n", i, strings.Repeat("q", 100))
	}
	rec := loadedRunner("sshd.service", "loaded")
	rec.StubOutput["journalctl -u sshd.service -n 500 -r --no-pager -o short-iso"] = []byte(b.String())

	res := mustRunInspect(t, rec, inspectTask("journal", "unit", "sshd.service", "lines", float64(500)))

	sec := sections(t, res)[0]
	out := sec["output"].(string)
	head := out
	if len(head) > 40 {
		head = head[:40]
	}
	if sec["truncated"] != true || !strings.HasPrefix(out, "[truncated: older output omitted]\n") {
		t.Fatalf("a cut journal says its OLDER lines were omitted: truncated=%v head=%q", sec["truncated"], head)
	}
	if !strings.Contains(out, "entry-0000001 ") {
		t.Fatalf("the newest line must survive")
	}
}

// === file_stat cannot wedge the agent's task slot ===

func writeMountInfo(t *testing.T, sb inspectSandbox, lines ...string) {
	t.Helper()
	body := strings.Join(lines, "\n") + "\n"
	if err := os.WriteFile(filepath.Join(sb.proc, "self", "mountinfo"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func mountLine(mountpoint, fstype string) string {
	return fmt.Sprintf("36 25 0:32 / %s rw,relatime shared:1 - %s src rw", mountpoint, fstype)
}

func TestNodeInspectRefusesFilesOnNetworkAndFuseMounts(t *testing.T) {
	for _, fstype := range []string{"nfs", "nfs4", "cifs", "smb3", "smbfs", "fuse", "fuse.sshfs", "fuse.glusterfs", "fuseblk", "9p", "ceph", "glusterfs", "sshfs"} {
		sb := newInspectSandbox(t)
		sb.write(t, "var/lib/powernode/storage/vol/data.bin", "payload")
		writeMountInfo(t, sb, mountLine("/", "ext4"), mountLine("/var/lib/powernode/storage/vol", fstype))

		res, err := runInspect(t, &mount.RecorderRunner{}, inspectTask("file_stat", "path", "/var/lib/powernode/storage/vol/data.bin"))
		if err == nil {
			t.Fatalf("%s: a file on a %s mount must be refused, got %+v", fstype, fstype, res)
		}
		assertRefused(t, err)
		if !strings.Contains(err.Error(), fstype) {
			t.Fatalf("%s: the refusal should name the filesystem type: %v", fstype, err)
		}
	}
}

func TestNodeInspectStillStatsFilesOnLocalMounts(t *testing.T) {
	for _, fstype := range []string{"ext4", "xfs", "btrfs", "overlay", "tmpfs", "erofs", "vfat", "squashfs"} {
		sb := newInspectSandbox(t)
		sb.write(t, "etc/hostname", "node\n")
		writeMountInfo(t, sb, mountLine("/", fstype), mountLine("/etc", fstype))

		res := mustRunInspect(t, &mount.RecorderRunner{}, inspectTask("file_stat", "path", "/etc/hostname"))
		if res["exists"] != true || res["sha256"] == nil {
			t.Fatalf("%s: a local mount must stay inspectable: %+v", fstype, res)
		}
	}
}

// The DEEPEST mount holding the path decides, in both directions.
func TestNodeInspectJudgesTheDeepestMountAndTheLastOvermount(t *testing.T) {
	sb := newInspectSandbox(t)
	sb.write(t, "var/lib/powernode/local.json", "{}")
	sb.write(t, "var/lib/powernode/storage/vol/f", "x")
	sb.write(t, "var/lib/powernode/storage/vol/deep/f", "x")
	writeMountInfo(t, sb,
		mountLine("/", "ext4"),
		mountLine("/var/lib/powernode/storage/vol", "nfs4"),
		mountLine("/var/lib/powernode/storage/vol/deep", "ext4"), // a local mount inside the nfs one
	)

	// A sibling of the nfs mount is on the local root.
	if res := mustRunInspect(t, &mount.RecorderRunner{}, inspectTask("file_stat", "path", "/var/lib/powernode/local.json")); res["exists"] != true {
		t.Fatalf("a path beside a network mount is local: %+v", res)
	}
	// The mountpoint itself is on the network filesystem.
	_, err := runInspect(t, &mount.RecorderRunner{}, inspectTask("file_stat", "path", "/var/lib/powernode/storage/vol"))
	assertRefused(t, err)
	// Under it, refused; under a deeper LOCAL mount, allowed.
	_, err = runInspect(t, &mount.RecorderRunner{}, inspectTask("file_stat", "path", "/var/lib/powernode/storage/vol/f"))
	assertRefused(t, err)
	if res := mustRunInspect(t, &mount.RecorderRunner{}, inspectTask("file_stat", "path", "/var/lib/powernode/storage/vol/deep/f")); res["exists"] != true {
		t.Fatalf("the deepest mount decides: %+v", res)
	}
	// An overmount: the LAST line for a mountpoint is what is visible.
	writeMountInfo(t, sb, mountLine("/", "ext4"), mountLine("/etc", "ext4"), mountLine("/etc", "nfs"))
	sb.write(t, "etc/hostname", "n")
	_, err = runInspect(t, &mount.RecorderRunner{}, inspectTask("file_stat", "path", "/etc/hostname"))
	assertRefused(t, err)
	// A prefix that is not a path boundary does not match.
	writeMountInfo(t, sb, mountLine("/", "ext4"), mountLine("/etc/ho", "nfs"))
	if res := mustRunInspect(t, &mount.RecorderRunner{}, inspectTask("file_stat", "path", "/etc/hostname")); res["exists"] != true {
		t.Fatalf("/etc/ho is not an ancestor of /etc/hostname: %+v", res)
	}
}

func TestNodeInspectDecodesEscapedMountpoints(t *testing.T) {
	sb := newInspectSandbox(t)
	sb.write(t, "var/lib/powernode/my_share/f", "x")
	writeMountInfo(t, sb, mountLine("/", "ext4"), mountLine(`/var/lib/powernode/my\137share`, "nfs4"))
	_, err := runInspect(t, &mount.RecorderRunner{}, inspectTask("file_stat", "path", "/var/lib/powernode/my_share/f"))
	assertRefused(t, err)
}

// A symlink into a network mount is refused on its RESOLVED path.
func TestNodeInspectRefusesASymlinkIntoANetworkMount(t *testing.T) {
	sb := newInspectSandbox(t)
	sb.write(t, "var/lib/powernode/storage/vol/f", "x")
	if err := os.Symlink("../var/lib/powernode/storage/vol/f", filepath.Join(sb.fs, "etc", "lk")); err != nil {
		_ = os.MkdirAll(filepath.Join(sb.fs, "etc"), 0o755)
		if err := os.Symlink("../var/lib/powernode/storage/vol/f", filepath.Join(sb.fs, "etc", "lk")); err != nil {
			t.Fatal(err)
		}
	}
	writeMountInfo(t, sb, mountLine("/", "ext4"), mountLine("/var/lib/powernode/storage/vol", "nfs4"))
	_, err := runInspect(t, &mount.RecorderRunner{}, inspectTask("file_stat", "path", "/etc/lk"))
	assertRefused(t, err)
}

// If the mount table cannot be read, the answer to "is this on a network mount"
// is unknown, and unknown is a refusal.
func TestNodeInspectFailsClosedWhenTheMountTableIsUnreadable(t *testing.T) {
	sb := newInspectSandbox(t)
	sb.write(t, "etc/hostname", "n")
	if err := os.Remove(filepath.Join(sb.proc, "self", "mountinfo")); err != nil {
		t.Fatal(err)
	}
	_, err := runInspect(t, &mount.RecorderRunner{}, inspectTask("file_stat", "path", "/etc/hostname"))
	assertRefused(t, err)
}

// The mount check runs BEFORE any filesystem access to the path, so resolving a
// component of a hung export is never attempted. The path does not exist in the
// sandbox at all: had it been resolved first the answer would be exists:false,
// not a refusal.
func TestNodeInspectChecksMountsBeforeTouchingThePath(t *testing.T) {
	sb := newInspectSandbox(t)
	writeMountInfo(t, sb, mountLine("/", "ext4"), mountLine("/var/lib/powernode/storage/gone", "nfs4"))

	res, err := runInspect(t, &mount.RecorderRunner{}, inspectTask("file_stat", "path", "/var/lib/powernode/storage/gone/x"))

	if err == nil {
		t.Fatalf("expected a refusal without the path being resolved, got %+v", res)
	}
	assertRefused(t, err)
}

// blockedFileStat installs a file_stat that never returns until released.
func blockedFileStat(t *testing.T) (calls *int32, release func()) {
	t.Helper()
	gate := make(chan struct{})
	var n int32
	restore := SetInspectFileStatForTest(func(string) (tasks.Result, error) {
		atomic.AddInt32(&n, 1)
		<-gate
		return tasks.Result{"collector": "file_stat", "ok": true}, nil
	})
	var once sync.Once
	release = func() { once.Do(func() { close(gate) }) }
	t.Cleanup(func() { release(); restore() })
	return &n, release
}

func TestNodeInspectFileStatHasADeadline(t *testing.T) {
	newInspectSandbox(t)
	blockedFileStat(t)
	restore := SetInspectDeadlineForTest(150 * time.Millisecond)
	defer restore()

	start := time.Now()
	done := make(chan error, 1)
	go func() {
		_, err := runInspect(t, &mount.RecorderRunner{}, inspectTask("file_stat", "path", "/etc/hostname"))
		done <- err
	}()
	select {
	case err := <-done:
		assertRefused(t, err)
		if !strings.Contains(err.Error(), "did not answer") {
			t.Fatalf("the refusal should say the path did not answer: %v", err)
		}
		if time.Since(start) > 3*time.Second {
			t.Fatalf("the deadline did not bound the call: %s", time.Since(start))
		}
	case <-time.After(10 * time.Second):
		t.Fatal("file_stat blocked past its deadline: one wedged path would hold the agent's only task slot")
	}
}

// The wedged goroutine leaks by design (a D-state read cannot be interrupted),
// so the number of leaked ones is capped: past it new file_stat calls are
// refused at once, without spawning another.
func TestNodeInspectRefusesFileStatWhenTooManyAreStillWedged(t *testing.T) {
	newInspectSandbox(t)
	calls, release := blockedFileStat(t)
	restore := SetInspectDeadlineForTest(30 * time.Millisecond)
	defer restore()

	for i := 0; i < inspectMaxWedged; i++ {
		_, err := runInspect(t, &mount.RecorderRunner{}, inspectTask("file_stat", "path", "/etc/hostname"))
		assertRefused(t, err)
	}
	if got := atomic.LoadInt32(calls); got != int32(inspectMaxWedged) {
		t.Fatalf("expected %d wedged calls so far, got %d", inspectMaxWedged, got)
	}

	_, err := runInspect(t, &mount.RecorderRunner{}, inspectTask("file_stat", "path", "/etc/hostname"))
	assertRefused(t, err)
	if !strings.Contains(err.Error(), "still blocked") {
		t.Fatalf("expected the wedged-cap refusal: %v", err)
	}
	if got := atomic.LoadInt32(calls); got != int32(inspectMaxWedged) {
		t.Fatalf("a refused call must not spawn another goroutine (calls=%d)", got)
	}

	// Once the blocked reads return, the slot count drains and file_stat works again.
	release()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) && inspectWedgedCount() > 0 {
		time.Sleep(10 * time.Millisecond)
	}
	if inspectWedgedCount() != 0 {
		t.Fatalf("wedged count did not drain: %d", inspectWedgedCount())
	}
}

// === the open cannot be steered by a swap after the check (openat2) ===

func TestNodeInspectRefusesAnIntermediateDirectorySwappedForASymlinkAfterTheCheck(t *testing.T) {
	sb := newInspectSandbox(t)
	sb.write(t, "etc/sub/app.conf", "legit\n")
	outside := filepath.Join(sb.outside(), "dir2")
	if err := os.MkdirAll(outside, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(outside, "app.conf"), []byte("outside-secret"), 0o644); err != nil {
		t.Fatal(err)
	}
	// Between the path being resolved and judged and the open, a component is
	// replaced with a symlink out of the tree. O_NOFOLLOW guards only the last
	// component, so this is what openat2 RESOLVE_BENEATH|NO_SYMLINKS is for.
	restore := SetInspectBeforeOpenHookForTest(func() {
		sub := filepath.Join(sb.fs, "etc", "sub")
		_ = os.RemoveAll(sub)
		_ = os.Symlink(outside, sub)
	})
	defer restore()

	res, err := runInspect(t, &mount.RecorderRunner{}, inspectTask("file_stat", "path", "/etc/sub/app.conf"))

	if err == nil {
		t.Fatalf("a component swapped for a symlink after the check must be refused, got %+v", res)
	}
	assertRefused(t, err)
	if strings.Contains(fmt.Sprint(res), "sha256") {
		t.Fatalf("the outside file was hashed: %+v", res)
	}
}

func TestNodeInspectRefusesTheFinalComponentSwappedForASymlinkAfterTheCheck(t *testing.T) {
	sb := newInspectSandbox(t)
	sb.write(t, "etc/app.conf", "legit\n")
	outsideFile := filepath.Join(sb.outside(), "secret")
	if err := os.WriteFile(outsideFile, []byte("outside-secret"), 0o644); err != nil {
		t.Fatal(err)
	}
	restore := SetInspectBeforeOpenHookForTest(func() {
		f := filepath.Join(sb.fs, "etc", "app.conf")
		_ = os.Remove(f)
		_ = os.Symlink(outsideFile, f)
	})
	defer restore()

	_, err := runInspect(t, &mount.RecorderRunner{}, inspectTask("file_stat", "path", "/etc/app.conf"))
	assertRefused(t, err)
}

func TestNodeInspectHookIsInertWhenNothingIsSwapped(t *testing.T) {
	sb := newInspectSandbox(t)
	sb.write(t, "etc/sub/app.conf", "legit\n")
	restore := SetInspectBeforeOpenHookForTest(func() {})
	defer restore()
	res := mustRunInspect(t, &mount.RecorderRunner{}, inspectTask("file_stat", "path", "/etc/sub/app.conf"))
	if res["sha256"] == nil {
		t.Fatalf("an unswapped path is hashed: %+v", res)
	}
}
