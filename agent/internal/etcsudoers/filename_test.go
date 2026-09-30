package etcsudoers

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/writeguard"
)

func grantOf(module, id string) Grant {
	return Grant{ModuleName: module, Grant: manifest.ManifestSudoer{
		ID: id, User: "u", RunasUser: "root", Commands: []string{"/bin/true"},
	}}
}

// hostile components: each must be refused as the module name AND as the grant
// id, since both are concatenated into the drop-in's basename.
var hostileComponents = map[string]string{
	"parent traversal": "../x",
	"trailing dotdot":  "x/..",
	"slash":            "a/b",
	"leading slash":    "/../../evil",
	"backslash":        `a\b`,
	"dot":              "a.b",
	"tilde":            "a~",
	"empty":            "",
	"space":            "a b",
	"newline":          "a\nb",
	"trailing newline": "a\n",
	"nul":              "a\x00b",
	"unicode letter":   "café",
	"fullwidth digit":  "１",
	"rtl override":     "a‮b",
	"very long":        strings.Repeat("a", 300),
}

func TestGrantRefusesHostileFilenameComponents(t *testing.T) {
	for label, bad := range hostileComponents {
		for slot, g := range map[string]Grant{
			"module": grantOf(bad, "reload"),
			"id":     grantOf("mod", bad),
		} {
			if err := g.CheckFilename(); err == nil {
				t.Errorf("%s as %s: CheckFilename accepted %q", label, slot, bad)
			}
			if p, err := g.PathIn(t.TempDir()); err == nil {
				t.Errorf("%s as %s: PathIn accepted %q -> %q", label, slot, bad, p)
			}
		}
	}
}

func TestGrantAcceptsValidFilenameComponents(t *testing.T) {
	dir := t.TempDir()
	for _, g := range []Grant{
		grantOf("postgres-primary", "reload"),
		grantOf("powernode-postgres", "reload"),
		grantOf("Mod_9", "A-b_C"),
	} {
		if err := g.CheckFilename(); err != nil {
			t.Errorf("%s: %v", g.Filename(), err)
		}
		p, err := g.PathIn(dir)
		if err != nil {
			t.Errorf("%s: PathIn: %v", g.Filename(), err)
		}
		if p != filepath.Join(dir, g.Filename()) {
			t.Errorf("PathIn = %q, want %q", p, filepath.Join(dir, g.Filename()))
		}
	}
}

func TestGrantFilenameLengthBoundary(t *testing.T) {
	// "powernode-" (10) + module + "-" + id: the whole basename is capped.
	atCap := grantOf(strings.Repeat("m", 100), strings.Repeat("i", maxFilenameLen-10-100-1))
	if len(atCap.Filename()) != maxFilenameLen {
		t.Fatalf("fixture len = %d, want %d", len(atCap.Filename()), maxFilenameLen)
	}
	if err := atCap.CheckFilename(); err != nil {
		t.Errorf("basename at the cap was refused: %v", err)
	}
	over := grantOf(strings.Repeat("m", 100), strings.Repeat("i", maxFilenameLen-10-100))
	if err := over.CheckFilename(); err == nil {
		t.Errorf("basename over the cap (%d) was accepted", len(over.Filename()))
	}
}

// The break-glass drop-in is written by its own path and excluded from the
// sweep; a manifest grant that renders to the same basename would overwrite it.
func TestGrantRefusesTheBreakGlassBasename(t *testing.T) {
	g := grantOf("operator", "break-glass")
	if g.Filename() != OperatorBreakGlassFilename {
		t.Fatalf("fixture no longer collides: %q", g.Filename())
	}
	if err := g.CheckFilename(); err == nil {
		t.Error("a grant rendering to the break-glass basename was accepted")
	}
}

// The break-glass basename is itself built without a Grant; it must satisfy the
// same rule so the two writers cannot disagree about what a legal name is.
func TestBreakGlassBasenameSatisfiesTheRule(t *testing.T) {
	if !filenameComponentRE.MatchString(OperatorBreakGlassFilename) {
		t.Errorf("%q does not match %s", OperatorBreakGlassFilename, filenameComponentRE)
	}
}

func listDir(t *testing.T, dir string) []string {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, e := range entries {
		out = append(out, e.Name())
	}
	return out
}

// One hostile grant must not stop the others (matching apply.go's per-grant
// isolation), must be reported, and must leave nothing outside the directory.
func TestApplyAtRefusesHostileGrantsButAppliesTheRest(t *testing.T) {
	base := t.TempDir()
	dir := filepath.Join(base, "sudoers.d")
	grants := []Grant{
		grantOf("a", "../../evil"),
		grantOf("good", "one"),
		grantOf("a", "b/c"),
		grantOf("a", "d.e"),
		grantOf("a", "f~"),
		grantOf("", "x"),
		grantOf("good", "two"),
		grantOf("m", "a\x00b"),
	}
	var err error
	rec := writeguard.Capture(func() { err = ApplyAt(grants, dir, staticClock()) })
	if err == nil {
		t.Fatal("hostile grants were not reported")
	}
	if len(rec) != 0 {
		t.Errorf("validation must refuse before any write reaches the guard; recorded %v", rec)
	}
	got := listDir(t, dir)
	want := []string{"powernode-good-one", "powernode-good-two"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("dir = %v, want %v", got, want)
	}
	if top := listDir(t, base); len(top) != 1 || top[0] != "sudoers.d" {
		t.Errorf("something landed outside the sudoers dir: %v", top)
	}
}

// Two DISTINCT (module, id) pairs can join to the same basename because "-" is
// legal in both components. Which one would win used to depend on input order
// (which itself comes from Go map iteration in the reconciler), so EVERY grant
// in the collision group is refused, in either order, and nothing is written.
func TestApplyAtRefusesEveryGrantInACollisionGroupRegardlessOfOrder(t *testing.T) {
	a := grantOf("a-b", "c")
	b := grantOf("a", "b-c")
	if a.Filename() != b.Filename() {
		t.Fatal("fixture no longer collides")
	}
	for name, order := range map[string][]Grant{"a,b": {a, b}, "b,a": {b, a}} {
		dir := t.TempDir()
		err := ApplyAt(order, dir, staticClock())
		if err == nil {
			t.Errorf("%s: the collision was not reported", name)
			continue
		}
		if got := listDir(t, dir); len(got) != 0 {
			t.Errorf("%s: a colliding grant was written: %v", name, got)
		}
		for _, want := range []string{`module "a-b" grant "c"`, `module "a" grant "b-c"`} {
			if !strings.Contains(err.Error(), want) {
				t.Errorf("%s: %s not reported as refused: %v", name, want, err)
			}
		}
		if !RefusalsOnly(err) {
			t.Errorf("%s: a collision refusal must be a non-fatal refusal: %v", name, err)
		}
	}
}

// The reconciler and the upgrade path hand ApplyAt an old-union-new set, so the
// SAME (module, id) legitimately arrives twice. That is not a collision: no
// error, and the LAST occurrence (the new manifest, appended after the old)
// is the body on disk.
func TestApplyAtAcceptsTheSameGrantTwiceLastOneWins(t *testing.T) {
	dir := t.TempDir()
	oldG := grantOf("postgres-primary", "reload")
	oldG.Grant.Commands = []string{"/bin/old"}
	newG := grantOf("postgres-primary", "reload")
	newG.Grant.Commands = []string{"/bin/new"}
	if err := ApplyAt([]Grant{oldG, newG}, dir, staticClock()); err != nil {
		t.Fatalf("an old-union-new pair was refused: %v", err)
	}
	body, err := os.ReadFile(filepath.Join(dir, "powernode-postgres-primary-reload"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(body), "/bin/new") || strings.Contains(string(body), "/bin/old") {
		t.Errorf("the new body did not land:\n%s", body)
	}
}

// A refusal is reported (so it is logged and signalled) but is distinguishable
// from a real write/IO failure, which stays fatal.
func TestRefusalsOnlyDistinguishesRefusalsFromWriteFailures(t *testing.T) {
	err := ApplyAt([]Grant{grantOf("a", "b.c"), grantOf("good", "one")}, t.TempDir(), staticClock())
	if err == nil || !RefusalsOnly(err) {
		t.Fatalf("a refusal-only result must satisfy RefusalsOnly: %v", err)
	}
	if RefusalsOnly(nil) {
		t.Error("nil is not a refusal")
	}
	if RefusalsOnly(errors.New("write failed")) {
		t.Error("a plain error is not a refusal")
	}
	if RefusalsOnly(errors.Join(err, errors.New("write failed"))) {
		t.Error("a refusal joined with a real failure must not read as refusal-only")
	}
}

// A refusal must not hide a sweep failure: both are returned, and the result is
// then NOT refusal-only (the IO failure stays fatal).
func TestApplyAtKeepsTheSweepErrorWhenAGrantIsRefused(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("directory permissions do not bind root")
	}
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "powernode-stale-one"), []byte("# x\n"), 0o440); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(dir, 0o700) })

	err := ApplyAt([]Grant{grantOf("a", "b.c")}, dir, staticClock())
	if err == nil {
		t.Fatal("expected an error")
	}
	if !strings.Contains(err.Error(), "refusing sudoers grant") || !strings.Contains(err.Error(), "sweep ") {
		t.Errorf("both the refusal and the sweep failure must be reported: %v", err)
	}
	if RefusalsOnly(err) {
		t.Error("a sweep IO failure must stay fatal")
	}
}

// A manifest grant must not be able to replace the break-glass drop-in.
func TestApplyAtDoesNotLetAGrantOverwriteBreakGlass(t *testing.T) {
	dir := t.TempDir()
	if err := ApplyOperatorBreakGlassAt(true, dir); err != nil {
		t.Fatal(err)
	}
	if err := ApplyAt([]Grant{grantOf("operator", "break-glass")}, dir, staticClock()); err == nil {
		t.Error("colliding grant was not reported")
	}
	body, err := os.ReadFile(filepath.Join(dir, OperatorBreakGlassFilename))
	if err != nil {
		t.Fatal(err)
	}
	if string(body) != OperatorBreakGlassBody {
		t.Errorf("break-glass drop-in was replaced:\n%s", body)
	}
}

// The sweep: a present powernode-* entry whose name no longer validates (a
// stale drop-in from before the rule, or one sudo ignores anyway because of the
// dot/tilde) is removed like any other orphan; the sweep only ever unlinks
// direct children of the directory, never a symlink's target, and never a
// directory or a non-powernode file.
func TestSweepRemovesStaleInvalidlyNamedDropInsWithoutEscapingTheDir(t *testing.T) {
	base := t.TempDir()
	dir := filepath.Join(base, "sudoers.d")
	if err := os.MkdirAll(dir, 0o750); err != nil {
		t.Fatal(err)
	}
	outside := filepath.Join(base, "precious")
	if err := os.WriteFile(outside, []byte("keep\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	write := func(name string) {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("# x\n"), 0o440); err != nil {
			t.Fatal(err)
		}
	}
	write("powernode-mod-a.b")
	write("powernode-mod-a~")
	write("powernode-mod-unié")
	write("90-admins")
	if err := os.Symlink(outside, filepath.Join(dir, "powernode-link")); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(dir, "powernode-adir"), 0o750); err != nil {
		t.Fatal(err)
	}

	if err := ApplyAt(nil, dir, staticClock()); err != nil {
		t.Fatalf("ApplyAt: %v", err)
	}

	got := strings.Join(listDir(t, dir), ",")
	if want := "90-admins,powernode-adir"; got != want {
		t.Errorf("dir after sweep = %s, want %s", got, want)
	}
	if b, err := os.ReadFile(outside); err != nil || string(b) != "keep\n" {
		t.Errorf("file outside the sudoers dir was touched: %q, %v", b, err)
	}
}

func TestChildOfRefusesNamesThatAreNotDirectChildren(t *testing.T) {
	dir := t.TempDir()
	for _, name := range []string{"", ".", "..", "../x", "a/b", "/abs"} {
		if p, err := childOf(dir, name); err == nil {
			t.Errorf("childOf(%q) = %q, want refusal", name, p)
		}
	}
	if p, err := childOf(dir, "powernode-a-b"); err != nil || p != filepath.Join(dir, "powernode-a-b") {
		t.Errorf("childOf valid = %q, %v", p, err)
	}
}

// R2-2 / R3-1: when the same (module, id) arrives more than once (the upgrade's
// old-union-new set, or a revert's departing digest last), the occurrences are
// tried from LAST to FIRST and the first one visudo accepts is written. The
// error returned is the LAST occurrence's, so a failing new body stays fatal
// and visible; nothing is written only if no occurrence validates.
func TestApplyAtTriesOccurrencesLastToFirst(t *testing.T) {
	orig := validateBody
	t.Cleanup(func() { validateBody = orig })
	var validated []string
	validateBody = func(body []byte) error {
		validated = append(validated, string(body))
		for _, bad := range []string{"/bin/bad-old", "/bin/bad-new"} {
			if strings.Contains(string(body), bad) {
				return errors.New("visudo rejected " + bad)
			}
		}
		return nil
	}
	mk := func(cmd string) Grant {
		g := grantOf("postgres-primary", "reload")
		g.Grant.Commands = []string{cmd}
		return g
	}
	on := func(dir string) string {
		b, err := os.ReadFile(filepath.Join(dir, "powernode-postgres-primary-reload"))
		if err != nil {
			return ""
		}
		return string(b)
	}

	t.Run("invalid OLD then valid new: new lands, no error, the old body is never checked", func(t *testing.T) {
		validated = nil
		dir := t.TempDir()
		if err := ApplyAt([]Grant{mk("/bin/bad-old"), mk("/bin/new")}, dir, staticClock()); err != nil {
			t.Fatalf("an invalid OLD body blocked the apply: %v", err)
		}
		if len(validated) != 1 || !strings.Contains(validated[0], "/bin/new") {
			t.Errorf("validations = %q", validated)
		}
		if !strings.Contains(on(dir), "/bin/new") {
			t.Errorf("new body did not land:\n%s", on(dir))
		}
	})

	t.Run("valid stable then invalid new: the stable body stays on disk and the new error is returned", func(t *testing.T) {
		validated = nil
		dir := t.TempDir()
		err := ApplyAt([]Grant{mk("/bin/stable"), mk("/bin/bad-new")}, dir, staticClock())
		if err == nil || !strings.Contains(err.Error(), "/bin/bad-new") {
			t.Fatalf("the LAST occurrence's visudo error must be returned, got %v", err)
		}
		if RefusalsOnly(err) {
			t.Error("a visudo failure must stay fatal")
		}
		if !strings.Contains(on(dir), "/bin/stable") {
			t.Errorf("the stable grant was not kept:\n%s", on(dir))
		}
	})

	t.Run("a stable file already on disk survives an invalid new body across ticks", func(t *testing.T) {
		dir := t.TempDir()
		if err := ApplyAt([]Grant{mk("/bin/stable")}, dir, staticClock()); err != nil {
			t.Fatal(err)
		}
		for tick := 0; tick < 2; tick++ {
			if err := ApplyAt([]Grant{mk("/bin/stable"), mk("/bin/bad-new")}, dir, staticClock()); err == nil {
				t.Fatal("expected the invalid new body to be reported")
			}
			if !strings.Contains(on(dir), "/bin/stable") {
				t.Fatalf("tick %d: the stable grant was swept", tick)
			}
		}
	})

	t.Run("no occurrence validates: nothing written and the last error is returned", func(t *testing.T) {
		dir := t.TempDir()
		err := ApplyAt([]Grant{mk("/bin/bad-old"), mk("/bin/bad-new")}, dir, staticClock())
		if err == nil || !strings.Contains(err.Error(), "/bin/bad-new") {
			t.Fatalf("want the last occurrence's error, got %v", err)
		}
		if got := listDir(t, dir); len(got) != 0 {
			t.Errorf("an invalid body was written: %v", got)
		}
	})
}
