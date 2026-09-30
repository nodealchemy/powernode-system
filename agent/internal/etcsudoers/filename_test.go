package etcsudoers

import (
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

// Two distinct (module, id) pairs can join to the same basename because "-" is
// legal in both components. The second must not silently overwrite the first.
func TestApplyAtRefusesAGrantCollidingWithAnEarlierOne(t *testing.T) {
	dir := t.TempDir()
	first := grantOf("a-b", "c")
	second := grantOf("a", "b-c")
	if first.Filename() != second.Filename() {
		t.Fatal("fixture no longer collides")
	}
	if err := ApplyAt([]Grant{first, second}, dir, staticClock()); err == nil {
		t.Error("the colliding grant was not reported")
	}
	body, err := os.ReadFile(filepath.Join(dir, first.Filename()))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(body), "module=a-b,") {
		t.Errorf("the first grant was overwritten:\n%s", body)
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
