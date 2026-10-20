package identity

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func withTempState(t *testing.T) (stage, refusals string) {
	t.Helper()
	dir := t.TempDir()
	oldS, oldR := stagedIdentityPath, consoleRefusalsPath
	stagedIdentityPath, consoleRefusalsPath = filepath.Join(dir, "identity.cfg"), filepath.Join(dir, "refusals")
	t.Cleanup(func() { stagedIdentityPath, consoleRefusalsPath = oldS, oldR })
	return stagedIdentityPath, consoleRefusalsPath
}

func fixtureWithState(t *testing.T, input, bootCfg string) *consoleFixture {
	f := newConsole(t, input, bootCfg)
	d := filepath.Dir(f.stage)
	f.s.LockPath = filepath.Join(d, "lock")
	f.s.RefusalsPath = filepath.Join(d, "refusals")
	f.s.Lock = func(string) (func(), error) { return func() {}, nil }
	return f
}

// H2
func TestConsoleSkippedWhenBootIdentityAlreadyHasKey(t *testing.T) {
	f := fixtureWithState(t, consoleKey+"\n", bootCfgPinned+"KEY=not-a-real-baked-key\nID=0190aaaa-bbbb-cccc-dddd-eeeeffff0009\n")
	if _, err := f.s.Discover(context.Background()); !errors.Is(err, ErrNotFound) || len(f.ev.list()) != 0 {
		t.Fatalf("a key baked on BOOT must suppress the prompt: %v %v", err, f.ev.list())
	}
}

// H3
func TestConsolePastedDocumentMustMatchBootServerAndPin(t *testing.T) {
	otherServer := strings.Replace(consoleDoc(""), "platform.example.test", "other.example.test", 1)
	otherPin := strings.Replace(consoleDoc(""), consolePin, "sha256:"+strings.Repeat("b", 64), 1)
	for name, doc := range map[string]string{"server": otherServer, "pin": otherPin} {
		t.Run(name, func(t *testing.T) {
			f := fixtureWithState(t, doc+"\n", bootCfgPinned)
			_, err := f.s.Discover(context.Background())
			if !errors.Is(err, ErrProvisionRefused) {
				t.Fatalf("want terminal refusal, got %v", err)
			}
			if _, serr := os.Stat(f.stage); serr == nil {
				t.Fatal("mismatching document must not be staged")
			}
		})
	}
	// SERVER-only boot config (no pin): the server must still match, any pin is fine
	f := fixtureWithState(t, consoleDoc("")+"\n", "SERVER=https://platform.example.test/\n")
	if _, err := f.s.Discover(context.Background()); err != nil {
		t.Fatalf("matching server (trailing slash tolerated) without boot pin: %v", err)
	}
	f = fixtureWithState(t, otherServer+"\n", "SERVER=https://platform.example.test\n")
	if _, err := f.s.Discover(context.Background()); !errors.Is(err, ErrProvisionRefused) {
		t.Fatalf("server mismatch without boot pin must be refused: %v", err)
	}
}

// DoS counter
func TestConsoleDisabledAfterThreeRefusals(t *testing.T) {
	f := fixtureWithState(t, "{bad\n", bootCfgPinned)
	for i := 0; i < MaxConsoleRefusals; i++ {
		f.tty.in = strings.NewReader("{bad\n")
		if _, err := f.s.Discover(context.Background()); !errors.Is(err, ErrProvisionRefused) {
			t.Fatalf("attempt %d: %v", i, err)
		}
	}
	f.ev.mu.Lock()
	f.ev.ev = nil
	f.ev.mu.Unlock()
	f.tty.in = strings.NewReader(consoleDoc("") + "\n")
	if _, err := f.s.Discover(context.Background()); !errors.Is(err, ErrNotFound) || len(f.ev.list()) != 0 {
		t.Fatalf("after %d refusals the prompt must be disabled for this boot: %v %v", MaxConsoleRefusals, err, f.ev.list())
	}
}

// M1 + staged cleanup
func TestConsoleStagedDocumentDeletedOnSuccessAndOnRefusal(t *testing.T) {
	stage, refusals := withTempState(t)
	for _, refused := range []bool{false, true} {
		os.RemoveAll(refusals)
		os.WriteFile(stage, []byte("x"), 0o600)
		id := &Identity{Purpose: ConsolePurpose}
		if refused {
			id.EnrolRefused()
		} else {
			id.EnrolSucceeded()
		}
		if _, err := os.Stat(stage); err == nil {
			t.Fatalf("staged file must be removed (refused=%v)", refused)
		}
		_, err := os.Stat(refusals)
		if refused && err != nil {
			t.Fatal("a 4xx refusal counts toward the console refusal limit")
		}
		if !refused && err == nil {
			t.Fatal("success resets the refusal counter")
		}
	}
	// documents from any other source are never touched
	os.WriteFile(stage, []byte("x"), 0o600)
	(&Identity{Purpose: "disk_image_enroll"}).EnrolSucceeded()
	(&Identity{}).EnrolRefused()
	if _, err := os.Stat(stage); err != nil {
		t.Fatal("only console-staged documents may be deleted")
	}
}

func TestParsedDocumentCarriesPurposeAndInstanceLabel(t *testing.T) {
	id, err := ParseProvisionDocument([]byte(consoleDoc("")))
	if err != nil || id.Purpose != "enroll" {
		t.Fatalf("%v %+v", err, id)
	}
	if got := (&Identity{InstanceUUID: PlaceholderInstanceID}).InstanceLabel(); strings.Contains(got, "0000") {
		t.Fatalf("placeholder must not be logged as an instance: %q", got)
	}
	if got := id.InstanceLabel(); got != id.InstanceUUID {
		t.Fatalf("%q", got)
	}
}

// M3
func TestConsoleNeverRunsTwoReaders(t *testing.T) {
	f := fixtureWithState(t, consoleKey+"\n", bootCfgPinned)
	f.s.Lock = func(string) (func(), error) { return nil, errors.New("held") }
	if _, err := f.s.Discover(context.Background()); !errors.Is(err, ErrNotFound) || len(f.ev.list()) != 0 {
		t.Fatalf("lock held elsewhere: must not touch the tty: %v %v", err, f.ev.list())
	}
}

func TestResolverPromptsOnlyWhenInteractive(t *testing.T) {
	for _, interactive := range []bool{false, true} {
		f := fixtureWithState(t, consoleKey+"\n", bootCfgPinned)
		r := &Resolver{Strategies: []Strategy{f.s}, Interactive: interactive}
		id, err := r.Resolve(context.Background())
		if interactive && (err != nil || id.BootstrapToken != consoleKey) {
			t.Fatalf("interactive: %v %+v", err, id)
		}
		if !interactive && (!errors.Is(err, ErrNotFound) || len(f.ev.list()) != 0) {
			t.Fatalf("non-interactive resolver must not prompt: %v %v", err, f.ev.list())
		}
	}
	if DefaultResolver().Interactive {
		t.Fatal("DefaultResolver (CLI, soft_recompose, prepare-root) must not prompt")
	}
	if !InteractiveResolver().Interactive {
		t.Fatal("boot/service paths use InteractiveResolver")
	}
}

// M4
func TestConsoleOnlyInInitramfs(t *testing.T) {
	old := initrdReleasePath
	initrdReleasePath = filepath.Join(t.TempDir(), "no-initrd-release")
	defer func() { initrdReleasePath = old }()
	f := fixtureWithState(t, consoleKey+"\n", bootCfgPinned)
	f.s.Skip = nil
	if _, err := f.s.Discover(context.Background()); !errors.Is(err, ErrNotFound) || len(f.ev.list()) != 0 {
		t.Fatalf("outside the initramfs the console belongs to getty: %v %v", err, f.ev.list())
	}
}

// M5: the prompt has its own timeout; the Resolver's budget does not cut it short.
func TestConsoleNotCutShortByResolverBudget(t *testing.T) {
	f := fixtureWithState(t, "", bootCfgPinned)
	pr, pw := io.Pipe()
	f.tty.in = pr
	f.tty.closer = func() { pw.Close() }
	f.s.Timeout = 3 * time.Second
	go func() { time.Sleep(300 * time.Millisecond); pw.Write([]byte(consoleKey + "\n")) }()
	r := &Resolver{Strategies: []Strategy{f.s}, Interactive: true, Timeout: 50 * time.Millisecond}
	id, err := r.Resolve(context.Background())
	if err != nil || id.BootstrapToken != consoleKey {
		t.Fatalf("resolver budget must not apply to the prompt: %v", err)
	}
}

// H1: context cancellation restores and returns
func TestConsoleHonoursContextCancel(t *testing.T) {
	f := fixtureWithState(t, "", bootCfgPinned)
	pr, pw := io.Pipe()
	f.tty.in = pr
	f.tty.closer = func() { pw.Close() }
	ctx, cancel := context.WithCancel(context.Background())
	go func() { time.Sleep(100 * time.Millisecond); cancel() }()
	start := time.Now()
	_, err := f.s.Discover(ctx)
	if !errors.Is(err, context.Canceled) || time.Since(start) > 2*time.Second {
		t.Fatalf("want prompt abandoned promptly on cancel, got %v after %v", err, time.Since(start))
	}
	ev := f.ev.list()
	if !contains(ev, "restore") {
		t.Fatalf("terminal not restored on cancel: %v", ev)
	}
	// restore must come BEFORE close
	if idx(ev, "restore") > idx(ev, "close") {
		t.Fatalf("restore must precede close: %v", ev)
	}
}

func idx(l []string, s string) int {
	for i, x := range l {
		if x == s {
			return i
		}
	}
	return -1
}

func TestConsoleRestoresTerminalOnPanic(t *testing.T) {
	f := fixtureWithState(t, consoleKey+"\n", bootCfgPinned)
	f.s.Now = func() time.Time { panic("boom") }
	func() {
		defer func() { _ = recover() }()
		_, _ = f.s.Discover(context.Background())
	}()
	if !contains(f.ev.list(), "restore") {
		t.Fatalf("terminal not restored after panic: %v", f.ev.list())
	}
}

// restore on the timeout path happens before the tty is closed
func TestConsoleRestoresBeforeCloseOnTimeout(t *testing.T) {
	f := fixtureWithState(t, "", bootCfgPinned)
	pr, pw := io.Pipe()
	f.tty.in = pr
	f.tty.closer = func() { pw.Close() }
	f.s.Timeout = 50 * time.Millisecond
	_, _ = f.s.Discover(context.Background())
	ev := f.ev.list()
	if idx(ev, "restore") < 0 || idx(ev, "restore") > idx(ev, "close") {
		t.Fatalf("restore must precede close: %v", ev)
	}
}

// multi-line paste
func TestConsoleMultiLinePastedDocument(t *testing.T) {
	doc := "{\n  \"version\": 1,\n  \"server\": \"https://platform.example.test\",\n  \"instance_id\": \"0190aaaa-bbbb-cccc-dddd-eeeeffff0001\",\n" +
		"  \"key\": \"" + consoleKey + "\",\n  \"ca_fingerprint\": \"" + consolePin + "\",\n  \"issued_at\": \"2026-01-01T00:00:00Z\",\n" +
		"  \"expires_at\": \"2026-01-02T00:00:00Z\",\n  \"purpose\": \"enroll\"\n}\n"
	f := fixtureWithState(t, doc, bootCfgPinned)
	id, err := f.s.Discover(context.Background())
	if err != nil || id.BootstrapToken != consoleKey {
		t.Fatalf("multi-line document: %v %+v", err, id)
	}
	// braces inside strings and escaped quotes do not end the document early
	tricky := strings.Replace(consoleDoc(""), `"purpose":"enroll"`, `"purpose":"enroll","ca_pem":"} \" {"`, 1)
	f = fixtureWithState(t, tricky+"\n", bootCfgPinned)
	if _, err := f.s.Discover(context.Background()); !errors.Is(err, ErrProvisionRefused) {
		t.Fatalf("whole tricky document must be read and judged (ca_pem mismatch): %v", err)
	}
}

func TestReadMaskedStopsWhenBracesBalance(t *testing.T) {
	r := strings.NewReader("{\"a\":\"}\"}\nSHOULD-NOT-BE-READ")
	got, err := readMasked(r, 1024)
	if err != nil || string(got) != "{\"a\":\"}\"}" {
		t.Fatalf("%q %v", got, err)
	}
	rest, _ := io.ReadAll(r)
	if !strings.Contains(string(rest), "SHOULD") {
		t.Fatal("read past the end of the document")
	}
}
