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
	for _, d := range []string{sb.fs, sb.proc, filepath.Join(root, "outside")} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
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
	rec.StubOutput["journalctl -u sshd.service -n 100 --no-pager -o short-iso"] = []byte("Sep 28 sshd[1]: Server listening\n")

	res := mustRunInspect(t, rec, inspectTask("journal", "unit", "sshd.service"))

	assertArgv(t, rec, loadedKey, "journalctl -u sshd.service -n 100 --no-pager -o short-iso")
	if !strings.Contains(resultText(t, res), "Server listening") {
		t.Fatalf("journal text missing: %+v", res)
	}
}

func TestNodeInspectJournalHonoursTheLineArgument(t *testing.T) {
	rec := loadedRunner("sshd.service", "loaded")
	res := mustRunInspect(t, rec, inspectTask("journal", "unit", "sshd.service", "lines", float64(5)))
	assertArgv(t, rec, loadedKey, "journalctl -u sshd.service -n 5 --no-pager -o short-iso")
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
	var b strings.Builder
	for i := 1; i <= 1000; i++ {
		fmt.Fprintf(&b, "line-%04d\n", i)
	}
	rec := loadedRunner("sshd.service", "loaded")
	rec.StubOutput["journalctl -u sshd.service -n 5 --no-pager -o short-iso"] = []byte(b.String())

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
	rec.StubOutput["journalctl -u app.service -n 100 --no-pager -o short-iso"] = []byte(
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
	var b strings.Builder
	for i := 1; b.Len() < 400_000; i++ {
		fmt.Fprintf(&b, "entry-%06d %s\n", i, strings.Repeat("y", 200))
	}
	last := strings.Split(strings.TrimSpace(b.String()), "\n")
	rec := loadedRunner("sshd.service", "loaded")
	rec.StubOutput["journalctl -u sshd.service -n 500 --no-pager -o short-iso"] = []byte(b.String())

	res := mustRunInspect(t, rec, inspectTask("journal", "unit", "sshd.service", "lines", float64(500)))

	out := sections(t, res)[0]["output"].(string)
	if len(out) > inspectMaxOutputBytes+256 {
		t.Fatalf("journal output must be bounded, got %d", len(out))
	}
	if !strings.Contains(out, last[len(last)-1]) {
		t.Fatalf("a journal keeps its NEWEST lines when bounded")
	}
	if strings.Contains(out, "entry-000001 ") {
		t.Fatalf("the oldest line should have been cut")
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
