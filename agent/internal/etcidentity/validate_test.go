package etcidentity

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
)

// IMP-01a0f109: manifest identity fields reach /etc/passwd, /etc/group,
// /etc/shadow and /etc/gshadow verbatim. A newline or ':' in any of them
// (or a uid-0 / reserved-name entry) would add a root-equivalent account
// to every node carrying the module. These tests pin both gates: Collect
// refuses the entry, and the renderer re-checks a Set that bypassed Collect.

func goodUser(name string, uid int) manifest.ManifestUser {
	return manifest.ManifestUser{
		Name: name, UID: uid, PrimaryGID: uid, PrimaryGroup: name,
		Shell: "/usr/sbin/nologin", Home: "/var/lib/" + name, Gecos: "Svc account, ops (x)",
	}
}

func oneModule(users []manifest.ManifestUser, groups []manifest.ManifestGroup) []*manifest.Manifest {
	return []*manifest.Manifest{{ID: "mod-evil", Name: "evil", Users: users, Groups: groups}}
}

func hasUser(set *Set, name string) bool {
	for _, u := range set.Users {
		if u.Name == name {
			return true
		}
	}
	return false
}

func refusedNames(set *Set) map[string]bool {
	out := map[string]bool{}
	for _, r := range set.Refused {
		out[r.Name] = true
	}
	return out
}

// assertNoInjectedLines checks the rendered files carry exactly one line per
// entry and that root is the only uid-0 line.
func assertNoInjectedLines(t *testing.T, set *Set) {
	t.Helper()
	passwd := strings.TrimRight(string(RenderPasswd(set)), "\n")
	lines := strings.Split(passwd, "\n")
	if len(lines) != len(set.Users) {
		t.Errorf("passwd has %d lines for %d users:\n%s", len(lines), len(set.Users), passwd)
	}
	for _, l := range lines {
		f := strings.Split(l, ":")
		if len(f) != 7 {
			t.Errorf("passwd line %q has %d fields, want 7", l, len(f))
			continue
		}
		if f[2] == "0" && f[0] != "root" {
			t.Errorf("non-root uid-0 line rendered: %q", l)
		}
	}
	for name, body := range map[string][]byte{
		"group": RenderGroup(set), "shadow": RenderShadow(set), "gshadow": RenderGshadow(set),
	} {
		got := strings.Count(string(body), "\n")
		want := len(set.Groups)
		if name == "shadow" {
			want = len(set.Users)
		}
		if got != want {
			t.Errorf("%s has %d lines, want %d:\n%s", name, got, want, body)
		}
	}
}

func TestCollectRefusesFieldInjection(t *testing.T) {
	cases := map[string]func(u *manifest.ManifestUser){
		"gecos newline injects uid0": func(u *manifest.ManifestUser) { u.Gecos = "x\ntoor:x:0:0::/root:/bin/bash" },
		"gecos colon":                func(u *manifest.ManifestUser) { u.Gecos = "a:b" },
		"gecos carriage return":      func(u *manifest.ManifestUser) { u.Gecos = "a\rb" },
		"gecos NUL":                  func(u *manifest.ManifestUser) { u.Gecos = "a\x00b" },
		"gecos ESC":                  func(u *manifest.ManifestUser) { u.Gecos = "a\x1b[2Jb" },
		"gecos DEL":                  func(u *manifest.ManifestUser) { u.Gecos = "a\x7fb" },
		"gecos invalid utf8":         func(u *manifest.ManifestUser) { u.Gecos = "a\xffb" },
		"home newline":               func(u *manifest.ManifestUser) { u.Home = "/var/lib/x\ntoor:x:0:0::/:/bin/sh" },
		"home colon":                 func(u *manifest.ManifestUser) { u.Home = "/var/lib/x:y" },
		"home relative":              func(u *manifest.ManifestUser) { u.Home = "var/lib/x" },
		"home dotdot":                func(u *manifest.ManifestUser) { u.Home = "/home/../etc" },
		"shell newline":              func(u *manifest.ManifestUser) { u.Shell = "/bin/sh\ntoor:x:0:0::/:/bin/sh" },
		"shell colon":                func(u *manifest.ManifestUser) { u.Shell = "/bin/sh:x" },
		"shell tab":                  func(u *manifest.ManifestUser) { u.Shell = "/bin/sh\t" },
		"primary group colon":        func(u *manifest.ManifestUser) { u.PrimaryGroup = "a:b" },
		"supplementary newline":      func(u *manifest.ManifestUser) { u.SupplementaryGroups = []string{"ok", "x\ny"} },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			u := goodUser("svcbad", 70500)
			mutate(&u)
			set, _ := Collect(oneModule([]manifest.ManifestUser{u, goodUser("svcok", 70501)}, nil))
			if hasUser(set, "svcbad") {
				t.Fatalf("invalid user was kept: %+v", u)
			}
			if !refusedNames(set)["svcbad"] {
				t.Errorf("refusal not reported; Refused=%+v", set.Refused)
			}
			if !hasUser(set, "svcok") {
				t.Errorf("valid sibling entry was dropped")
			}
			assertNoInjectedLines(t, set)
		})
	}
}

func TestCollectRefusesInvalidNames(t *testing.T) {
	for _, name := range []string{"a:b", "evil\ntoor", "Evil", "1abc", "", "a b", "x\x00", strings.Repeat("a", 33), "a$"} {
		t.Run(name, func(t *testing.T) {
			set, _ := Collect(oneModule([]manifest.ManifestUser{goodUser(name, 70600)}, nil))
			if hasUser(set, name) {
				t.Fatalf("user %q kept", name)
			}
			if len(set.Refused) == 0 {
				t.Errorf("no refusal reported for %q", name)
			}
			assertNoInjectedLines(t, set)
		})
	}
	// The longest legal name (32 chars) and a hyphenated one still pass.
	set, _ := Collect(oneModule([]manifest.ManifestUser{
		goodUser("a"+strings.Repeat("b", 31), 70601), goodUser("systemd-network", 70602),
	}, nil))
	if len(set.Refused) != 0 {
		t.Errorf("legal names refused: %+v", set.Refused)
	}
}

func TestCollectRefusesPrivilegedOrReservedIDs(t *testing.T) {
	cases := map[string]manifest.ManifestUser{
		"uid 0":                 {Name: "toor", UID: 0, PrimaryGID: 70700, Shell: "/bin/bash", Home: "/var/lib/toor"},
		"primary gid 0":         {Name: "toor", UID: 70700, PrimaryGID: 0, Shell: "/bin/bash", Home: "/var/lib/toor"},
		"uid in system range":   {Name: "toor", UID: 27, PrimaryGID: 70700, Shell: "/bin/bash", Home: "/var/lib/toor"},
		"uid below managed":     {Name: "toor", UID: 1001, PrimaryGID: 70700, Shell: "/bin/bash", Home: "/var/lib/toor"},
		"uid above managed":     {Name: "toor", UID: 100000, PrimaryGID: 70700, Shell: "/bin/bash", Home: "/var/lib/toor"},
		"negative uid":          {Name: "toor", UID: -1, PrimaryGID: 70700, Shell: "/bin/bash", Home: "/var/lib/toor"},
		"nobody gid":            {Name: "toor", UID: 70700, PrimaryGID: 65534, Shell: "/bin/bash", Home: "/var/lib/toor"},
		"reserved name root":    {Name: "root", UID: 70700, PrimaryGID: 70700, Shell: "/bin/bash", Home: "/var/lib/r"},
		"reserved name pnadmin": {Name: "pnadmin", UID: 70700, PrimaryGID: 70700, Shell: "/bin/bash", Home: "/var/lib/p"},
		"reserved name sshd":    {Name: "sshd", UID: 70700, PrimaryGID: 70700, Shell: "/bin/bash", Home: "/var/lib/s"},
	}
	for name, u := range cases {
		t.Run(name, func(t *testing.T) {
			set, _ := Collect(oneModule([]manifest.ManifestUser{u}, nil))
			if len(set.Refused) != 1 {
				t.Fatalf("want 1 refusal, got %+v", set.Refused)
			}
			// The baseline entry for a reserved name is untouched.
			for _, b := range Baseline().Users {
				found := false
				for _, got := range set.Users {
					if reflect.DeepEqual(got, b) {
						found = true
					}
				}
				if !found {
					t.Errorf("baseline user %s changed or missing", b.Name)
				}
			}
			if len(set.Users) != len(Baseline().Users) {
				t.Errorf("set grew to %d users", len(set.Users))
			}
			assertNoInjectedLines(t, set)
		})
	}
}

func TestCollectRefusesDuplicateIDsAndHomes(t *testing.T) {
	a := goodUser("svca", 70800)
	e := goodUser("svce", 70803)
	e.Home = "/home/svce"
	first := &manifest.Manifest{ID: "mod-first", Users: []manifest.ManifestUser{a, e}}

	b := goodUser("svcb", 70800) // another module takes svca's uid
	c := goodUser("svcc", 70801)
	c.PrimaryGID = 70800 // sharing a primary GID is fine (a group, not an account)
	d := goodUser("svcd", 70802)
	d.Home = "/home/pnadmin" // would take pnadmin's home and authorized_keys
	f := goodUser("svcf", 70804)
	f.Home = "/home/svce/" // svce's managed home once cleaned
	second := &manifest.Manifest{ID: "mod-second", Users: []manifest.ManifestUser{b, c, d, f}}

	// The same module re-declaring a uid under a new name (old+new digest
	// union during a rename upgrade) is NOT a foreign claim.
	renamed := goodUser("svca2", 70800)
	again := &manifest.Manifest{ID: "mod-first", Users: []manifest.ManifestUser{renamed}}

	set, _ := Collect([]*manifest.Manifest{first, second, again})
	for _, want := range []string{"svca", "svcc", "svce", "svca2"} {
		if !hasUser(set, want) {
			t.Errorf("%s dropped (refused=%+v)", want, set.Refused)
		}
	}
	for _, bad := range []string{"svcb", "svcd", "svcf"} {
		if hasUser(set, bad) {
			t.Errorf("%s kept", bad)
		}
		if !refusedNames(set)[bad] {
			t.Errorf("%s refusal not reported", bad)
		}
	}
}

func TestCollectRefusesPrivilegedGroups(t *testing.T) {
	svc := goodUser("svcg", 70900)
	groups := []manifest.ManifestGroup{
		{Name: "sudo", GID: 70901, Members: []string{"svcg"}},
		{Name: "disk", GID: 70902, Members: []string{"svcg"}},
		{Name: "shadow", GID: 70903, Members: []string{"svcg"}},
		{Name: "root", GID: 70904, Members: []string{"svcg"}},
		{Name: "wheel", GID: 0, Members: []string{"svcg"}},
		{Name: "lowgid", GID: 10, Members: []string{"svcg"}},
		{Name: "bad:name", GID: 70905},
		{Name: "badmember", GID: 70906, Members: []string{"ok", "x\nroot"}},
		{Name: "svcg", GID: 70900},
		{Name: "video", GID: 70907, Members: []string{"svcg"}}, // device group: merge allowed
	}
	other := &manifest.Manifest{ID: "mod-other", Groups: []manifest.ManifestGroup{
		{Name: "dupgid", GID: 70900}, // another module puts a second NAME on svcg's gid
	}}
	set, _ := Collect(append(oneModule([]manifest.ManifestUser{svc}, groups), other))
	byName := map[string]Group{}
	for _, g := range set.Groups {
		byName[g.Name] = g
	}
	for _, priv := range []string{"sudo", "disk", "shadow", "root"} {
		if len(byName[priv].Members) != 0 {
			t.Errorf("%s gained members %v", priv, byName[priv].Members)
		}
	}
	for _, bad := range []string{"wheel", "lowgid", "bad:name", "badmember", "dupgid"} {
		if _, ok := byName[bad]; ok {
			t.Errorf("group %q kept", bad)
		}
	}
	// gid 70900 belongs to exactly one name.
	owners := 0
	for _, g := range set.Groups {
		if g.GID == 70900 {
			owners++
		}
	}
	if owners != 1 {
		t.Errorf("gid 70900 owned by %d groups", owners)
	}
	if got := byName["video"].Members; len(got) != 1 || got[0] != "svcg" {
		t.Errorf("device group merge lost: %v", got)
	}
	if byName["video"].GID != 44 {
		t.Errorf("video gid changed to %d", byName["video"].GID)
	}
	assertNoInjectedLines(t, set)
}

func TestCollectKeepsShippedManifestShapes(t *testing.T) {
	pg := manifest.ManifestUser{Name: "postgres", UID: 70110, PrimaryGID: 70110, PrimaryGroup: "postgres",
		Shell: "/bin/bash", Home: "/var/lib/postgresql", Gecos: "PostgreSQL administrator",
		SupplementaryGroups: []string{"ssl-cert"}}
	agent := manifest.ManifestUser{Name: "pnagent", UID: 71000, PrimaryGID: 71000, PrimaryGroup: "pnagent",
		Shell: "/usr/sbin/nologin", Home: "/home/pnagent",
		Gecos: "Dev-cell sandboxed agent worker (no secrets, no push authority)"}
	groups := []manifest.ManifestGroup{
		{Name: "postgres", GID: 70110, Members: []string{"postgres"}},
		{Name: "ssl-cert", GID: 71001, Members: []string{"postgres"}},
		{Name: "docker", GID: 71002, Members: []string{"pnadmin", "pnrunner"}},
	}
	set, conflicts := Collect(oneModule([]manifest.ManifestUser{pg, agent}, groups))
	if len(set.Refused) != 0 || len(conflicts) != 0 {
		t.Fatalf("shipped shapes refused: %+v %+v", set.Refused, conflicts)
	}
	if !strings.Contains(string(RenderPasswd(set)),
		"postgres:x:70110:70110:PostgreSQL administrator:/var/lib/postgresql:/bin/bash\n") {
		t.Errorf("postgres line missing:\n%s", RenderPasswd(set))
	}
}

// The renderer must not trust its input: a Set built without Collect (or a
// future caller that forgets to screen) still never writes an unsafe line.
func TestRenderReChecksEntries(t *testing.T) {
	set := Baseline()
	set.Users = append(set.Users,
		User{Name: "svcx", UID: 70950, PrimaryGID: 70950, Shell: "/bin/sh", Home: "/var/lib/svcx",
			Gecos: "x\ntoor:x:0:0::/root:/bin/bash"},
		User{Name: "ev:il", UID: 70951, PrimaryGID: 70951, Shell: "/bin/sh", Home: "/var/lib/e"},
		User{Name: "svcy", UID: 70952, PrimaryGID: 70952, Shell: "/bin/sh", Home: "/var/lib/svcy"},
	)
	set.Groups = append(set.Groups,
		Group{Name: "gx", GID: 70953, Members: []string{"svcy", "a\nroot"}},
		Group{Name: "g:y", GID: 70954},
	)
	passwd := string(RenderPasswd(set))
	if strings.Contains(passwd, "toor") || strings.Contains(passwd, "ev:il") {
		t.Errorf("renderer wrote unsafe user:\n%s", passwd)
	}
	if !strings.Contains(passwd, "svcy:x:70952:70952::/var/lib/svcy:/bin/sh\n") {
		t.Errorf("renderer dropped a valid user:\n%s", passwd)
	}
	for _, body := range [][]byte{RenderShadow(set), RenderGroup(set), RenderGshadow(set)} {
		s := string(body)
		if strings.Contains(s, "svcx:") || strings.Contains(s, "ev:il") ||
			strings.Contains(s, "\ngx:") || strings.Contains(s, "g:y") || strings.Contains(s, "\nroot\n") {
			t.Errorf("renderer wrote unsafe entry:\n%s", s)
		}
	}

	// ApplyAt writes the re-checked content and reports every skip.
	var logged []string
	prev := LogRefused
	LogRefused = func(r Refusal) { logged = append(logged, r.Name) }
	defer func() { LogRefused = prev }()
	dir := t.TempDir()
	paths := Paths{
		Lock: filepath.Join(dir, ".pwd.lock"), Passwd: filepath.Join(dir, "passwd"),
		Group: filepath.Join(dir, "group"), Shadow: filepath.Join(dir, "shadow"), Gshadow: filepath.Join(dir, "gshadow"),
	}
	if err := ApplyAt(set, paths); err != nil {
		t.Fatalf("ApplyAt: %v", err)
	}
	onDisk, _ := os.ReadFile(paths.Passwd)
	if strings.Contains(string(onDisk), "toor") {
		t.Errorf("unsafe line reached disk:\n%s", onDisk)
	}
	want := map[string]bool{"svcx": true, "ev:il": true, "gx": true, "g:y": true}
	got := map[string]bool{}
	for _, n := range logged {
		got[n] = true
	}
	for n := range want {
		if !got[n] {
			t.Errorf("skip of %q not logged (logged=%v)", n, logged)
		}
	}
}

func TestBaselinePassesRenderCheck(t *testing.T) {
	set := Baseline()
	if n := strings.Count(string(RenderPasswd(set)), "\n"); n != len(set.Users) {
		t.Errorf("baseline passwd lost entries: %d of %d", n, len(set.Users))
	}
	if n := strings.Count(string(RenderGroup(set)), "\n"); n != len(set.Groups) {
		t.Errorf("baseline group lost entries: %d of %d", n, len(set.Groups))
	}
}
