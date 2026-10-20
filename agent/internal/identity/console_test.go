package identity

import (
	"bytes"
	"context"
	"errors"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

const (
	consoleKey = "not-a-real-enrol-key"
	consolePin = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
)

type fakeEvents struct {
	mu sync.Mutex
	ev []string
}

func (e *fakeEvents) add(s string) { e.mu.Lock(); e.ev = append(e.ev, s); e.mu.Unlock() }
func (e *fakeEvents) list() []string {
	e.mu.Lock()
	defer e.mu.Unlock()
	return append([]string(nil), e.ev...)
}

type fakeTTY struct {
	in     io.Reader
	closer func()
	out    bytes.Buffer
	ev     *fakeEvents
	once   sync.Once
	closed bool
}

func (f *fakeTTY) Read(p []byte) (int, error) {
	f.once.Do(func() { f.ev.add("read") })
	return f.in.Read(p)
}
func (f *fakeTTY) Write(p []byte) (int, error) { return f.out.Write(p) }
func (f *fakeTTY) Close() error {
	f.ev.add("close")
	f.closed = true
	if f.closer != nil {
		f.closer()
	}
	return nil
}
func (f *fakeTTY) Control(fn func(fd uintptr)) error { fn(7); return nil }

type fakeTerm struct {
	ev  *fakeEvents
	err error
}

func (t fakeTerm) DisableEcho(fd uintptr) (func(), error) {
	if t.err != nil {
		return nil, t.err
	}
	t.ev.add("noecho")
	return func() { t.ev.add("restore") }, nil
}

type consoleFixture struct {
	s     *ConsolePromptStrategy
	tty   *fakeTTY
	ev    *fakeEvents
	stage string
}

func newConsole(t *testing.T, input string, bootCfg string) *consoleFixture {
	t.Helper()
	dir := t.TempDir()
	ev := &fakeEvents{}
	tty := &fakeTTY{in: strings.NewReader(input), ev: ev}
	boot := ""
	if bootCfg != "" {
		boot = filepath.Join(dir, "identity.cfg")
		if err := os.WriteFile(boot, []byte(bootCfg), 0o600); err != nil {
			t.Fatal(err)
		}
	} else {
		boot = filepath.Join(dir, "absent.cfg")
	}
	stage := filepath.Join(dir, "run", "powernode", "identity.cfg")
	return &consoleFixture{
		tty: tty, ev: ev, stage: stage,
		s: &ConsolePromptStrategy{
			Open: func() (ConsoleTTY, error) { return tty, nil }, Term: fakeTerm{ev: ev},
			Timeout: 2 * time.Second, Skip: func() bool { return false },
			BootStrategy: &BootIdentityStrategy{Path: boot}, StagePath: stage,
			Now: func() time.Time { return time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC) },
		},
	}
}

const bootCfgPinned = "SERVER=https://platform.example.test\nCA_FINGERPRINT=" + consolePin + "\n"

func consoleDoc(extra string) string {
	return `{"version":1,"server":"https://platform.example.test","instance_id":"0190aaaa-bbbb-cccc-dddd-eeeeffff0001","key":"` + consoleKey +
		`","ca_fingerprint":"` + consolePin + `","issued_at":"2026-01-01T00:00:00Z","expires_at":"2026-01-02T00:00:00Z","purpose":"enroll"` + extra + "}"
}

func TestConsoleTimeoutFallsThrough(t *testing.T) {
	f := newConsole(t, "", bootCfgPinned)
	pr, pw := io.Pipe()
	f.tty.in = pr
	f.tty.closer = func() { pw.Close() }
	f.s.Timeout = 50 * time.Millisecond
	_, err := f.s.Discover(context.Background())
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("want ErrNotFound on timeout, got %v", err)
	}
	if !f.tty.closed {
		t.Error("tty not closed on timeout")
	}
	if ev := f.ev.list(); !contains(ev, "restore") {
		t.Errorf("terminal not restored: %v", ev)
	}
	if _, serr := os.Stat(f.stage); serr == nil {
		t.Error("nothing may be staged on timeout")
	}
}

func contains(l []string, s string) bool {
	for _, x := range l {
		if x == s {
			return true
		}
	}
	return false
}

func TestConsoleNoEchoBeforeReadAndRestored(t *testing.T) {
	f := newConsole(t, consoleKey+"\n", bootCfgPinned)
	if _, err := f.s.Discover(context.Background()); err != nil {
		t.Fatal(err)
	}
	ev := f.ev.list()
	if len(ev) < 3 || ev[0] != "noecho" || ev[1] != "read" {
		t.Fatalf("no-echo must precede the first read: %v", ev)
	}
	if !contains(ev, "restore") {
		t.Fatalf("terminal not restored: %v", ev)
	}
	if strings.Contains(f.tty.out.String(), consoleKey) {
		t.Fatal("input echoed to the console")
	}
}

func TestConsoleNeverReadsWhenEchoCannotBeDisabled(t *testing.T) {
	f := newConsole(t, consoleKey+"\n", bootCfgPinned)
	f.s.Term = fakeTerm{ev: f.ev, err: errors.New("no termios")}
	_, err := f.s.Discover(context.Background())
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("want ErrNotFound, got %v", err)
	}
	if contains(f.ev.list(), "read") {
		t.Fatal("must not read when echo cannot be disabled")
	}
}

func TestConsoleBareKeyWithoutPinRefused(t *testing.T) {
	for name, cfg := range map[string]string{
		"no pin": "SERVER=https://platform.example.test\n",
	} {
		t.Run(name, func(t *testing.T) {
			f := newConsole(t, consoleKey+"\n", cfg)
			_, err := f.s.Discover(context.Background())
			if !errors.Is(err, ErrProvisionRefused) {
				t.Fatalf("want terminal refusal, got %v", err)
			}
			if strings.Contains(err.Error(), consoleKey) {
				t.Fatal("error leaks the key")
			}
			if _, serr := os.Stat(f.stage); serr == nil {
				t.Fatal("refused key must not be staged")
			}
		})
	}
}

func TestConsoleBareKeyWithBootPinStaged(t *testing.T) {
	f := newConsole(t, consoleKey+"\r", bootCfgPinned)
	id, err := f.s.Discover(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if id.BootstrapToken != consoleKey || id.PlatformURL != "https://platform.example.test" || id.CAFingerprint != consolePin {
		t.Fatalf("unexpected identity %+v", id)
	}
	assertStaged0600(t, f.stage)
	// the staged file is read back by the existing local source
	back, err := (&LocalIdentityStrategy{Path: f.stage}).Discover(context.Background())
	if err != nil || back.BootstrapToken != consoleKey || back.CAFingerprint != consolePin {
		t.Fatalf("staged file not re-readable: %v %+v", err, back)
	}
}

func assertStaged0600(t *testing.T, p string) {
	t.Helper()
	st, err := os.Stat(p)
	if err != nil {
		t.Fatalf("not staged: %v", err)
	}
	if st.Mode().Perm() != 0o600 {
		t.Fatalf("staged mode %o, want 0600", st.Mode().Perm())
	}
}

func TestConsolePastedDocumentParsedAndStaged(t *testing.T) {
	doc := consoleDoc("")
	f := newConsole(t, doc+"\n", bootCfgPinned)
	id, err := f.s.Discover(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if id.InstanceUUID != "0190aaaa-bbbb-cccc-dddd-eeeeffff0001" || id.BootstrapToken != consoleKey || id.CloudProvider != "console-prompt" {
		t.Fatalf("unexpected identity %+v", id)
	}
	assertStaged0600(t, f.stage)
	got, _ := os.ReadFile(f.stage)
	if string(got) != doc {
		t.Fatal("staged bytes differ from the pasted document")
	}
}

func TestConsoleInvalidDocumentTerminal(t *testing.T) {
	for name, doc := range map[string]string{
		"unknown field": consoleDoc(`,"extra":"x"`),
		"no pin":        strings.Replace(consoleDoc(""), `"ca_fingerprint":"`+consolePin+`",`, "", 1),
		"bad json":      `{"version":1,`,
	} {
		t.Run(name, func(t *testing.T) {
			f := newConsole(t, doc+"\n", bootCfgPinned)
			_, err := f.s.Discover(context.Background())
			if !errors.Is(err, ErrProvisionRefused) {
				t.Fatalf("want ErrProvisionRefused, got %v", err)
			}
			if _, serr := os.Stat(f.stage); serr == nil {
				t.Fatal("refused document must not be staged")
			}
			// terminal at the Resolver: a later source must not rescue it
			r := &Resolver{Strategies: []Strategy{f.s, stubStrategy{id: &Identity{InstanceUUID: "u", BootstrapToken: "k"}}}}
			f2 := newConsole(t, doc+"\n", bootCfgPinned)
			r.Strategies[0] = f2.s
			if _, err := r.Resolve(context.Background()); !errors.Is(err, ErrProvisionRefused) {
				t.Fatalf("resolver must stop: %v", err)
			}
		})
	}
}

type stubStrategy struct{ id *Identity }

func (stubStrategy) Name() string                                  { return "stub" }
func (s stubStrategy) Discover(context.Context) (*Identity, error) { return s.id, nil }

func TestConsoleEmptyLineAndSkipFallThrough(t *testing.T) {
	f := newConsole(t, "\n", bootCfgPinned)
	if _, err := f.s.Discover(context.Background()); !errors.Is(err, ErrNotFound) {
		t.Fatalf("empty line: %v", err)
	}
	f = newConsole(t, consoleKey+"\n", bootCfgPinned)
	f.s.Skip = func() bool { return true }
	if _, err := f.s.Discover(context.Background()); !errors.Is(err, ErrNotFound) || len(f.ev.list()) != 0 {
		t.Fatalf("skipped strategy must not touch the tty: %v %v", err, f.ev.list())
	}
	f = newConsole(t, consoleKey+"\n", bootCfgPinned)
	f.s.Timeout = -1
	if _, err := f.s.Discover(context.Background()); !errors.Is(err, ErrNotFound) || len(f.ev.list()) != 0 {
		t.Fatal("negative timeout disables the prompt")
	}
}

func TestConsoleBackspaceHandled(t *testing.T) {
	f := newConsole(t, consoleKey+"zz\x7f\x7f\n", bootCfgPinned)
	id, err := f.s.Discover(context.Background())
	if err != nil || id.BootstrapToken != consoleKey {
		t.Fatalf("backspace: %v %+v", err, id)
	}
}

func TestConsoleNothingLogged(t *testing.T) {
	var logBuf bytes.Buffer
	log.SetOutput(&logBuf)
	defer log.SetOutput(os.Stderr)
	dir := t.TempDir()
	capture := func(name string) (*os.File, func() string) {
		fh, err := os.Create(filepath.Join(dir, name))
		if err != nil {
			t.Fatal(err)
		}
		return fh, func() string { b, _ := os.ReadFile(fh.Name()); return string(b) }
	}
	oe, oo := os.Stderr, os.Stdout
	ef, eRead := capture("stderr")
	of, oRead := capture("stdout")
	os.Stderr, os.Stdout = ef, of
	defer func() { os.Stderr, os.Stdout = oe, oo }()

	f := newConsole(t, consoleKey+"\n", bootCfgPinned)
	_, err1 := f.s.Discover(context.Background())
	f2 := newConsole(t, consoleDoc(`,"bogus":"`+consoleKey+`"`)+"\n", bootCfgPinned)
	_, err2 := f2.s.Discover(context.Background())
	f3 := newConsole(t, consoleKey+"\n", "SERVER=https://platform.example.test\n")
	_, err3 := f3.s.Discover(context.Background())
	os.Stderr, os.Stdout = oe, oo

	if err1 != nil {
		t.Fatal(err1)
	}
	for _, e := range []error{err2, err3} {
		if e == nil || strings.Contains(e.Error(), consoleKey) {
			t.Fatalf("error must exist and not leak: %v", e)
		}
	}
	for name, s := range map[string]string{"log": logBuf.String(), "stderr": eRead(), "stdout": oRead(),
		"tty1": f.tty.out.String(), "tty2": f2.tty.out.String(), "tty3": f3.tty.out.String()} {
		if strings.Contains(s, consoleKey) {
			t.Errorf("%s contains the input", name)
		}
	}
	if logBuf.Len() != 0 {
		t.Errorf("unexpected log output: %q", logBuf.String())
	}
}

func TestResolverDoesNotPromptAfterPinlessHit(t *testing.T) {
	prompted := false
	c := &ConsolePromptStrategy{Open: func() (ConsoleTTY, error) { prompted = true; return nil, errors.New("x") }, Skip: func() bool { return false }}
	r := &Resolver{Strategies: []Strategy{stubStrategy{id: &Identity{InstanceUUID: "u", BootstrapToken: "k"}}, c}}
	if _, err := r.Resolve(context.Background()); err != nil {
		t.Fatal(err)
	}
	if prompted {
		t.Fatal("console prompt must not run once an earlier source supplied a key")
	}
}

func TestDefaultResolverPromptsRightBeforeClaim(t *testing.T) {
	ss := DefaultResolver().Strategies
	for i, s := range ss {
		if _, ok := s.(*ClaimStrategy); ok {
			if _, ok := ss[i-1].(*ConsolePromptStrategy); !ok {
				t.Fatalf("console prompt must be immediately before the claim poll, got %T", ss[i-1])
			}
			return
		}
	}
	t.Fatal("no ClaimStrategy")
}

func TestConsoleTimeoutFromCmdline(t *testing.T) {
	p := filepath.Join(t.TempDir(), "cmdline")
	os.WriteFile(p, []byte("quiet powernode.console_prompt_timeout=15\n"), 0o600)
	if d := consolePromptTimeout(p); d != 15*time.Second {
		t.Fatalf("got %v", d)
	}
	os.WriteFile(p, []byte("powernode.console_prompt_timeout=0\n"), 0o600)
	if d := consolePromptTimeout(p); d >= 0 {
		t.Fatalf("0 disables: %v", d)
	}
	if d := consolePromptTimeout(filepath.Join(t.TempDir(), "none")); d != 0 {
		t.Fatalf("default is zero value (60s in the strategy): %v", d)
	}
}

func TestConsoleNotPromptedWithoutBootIdentity(t *testing.T) {
	f := newConsole(t, consoleKey+"\n", "")
	if _, err := f.s.Discover(context.Background()); !errors.Is(err, ErrNotFound) || len(f.ev.list()) != 0 {
		t.Fatalf("node without a boot identity.cfg must not be prompted: %v %v", err, f.ev.list())
	}
}
