package identity

// ConsolePromptStrategy is the LAST interactive resort before the claim poll:
// when no earlier source supplied a key, ask the operator on /dev/console for
// either a bare one-time enrolment key (combined with SERVER + CA pin from the
// image's boot identity.cfg) or a pasted powernode-provision v1 document.
//
// Rules (D8):
//   - input is MASKED: the terminal is put in no-echo mode through the Termios
//     seam BEFORE the first read and restored after; if no-echo cannot be
//     established the prompt is NOT shown (a key is never read unmasked);
//   - the input is never logged and never appears in an error; buffers are
//     zeroed after use;
//   - it times out (default 60s) and falls through to the claim poll, so a
//     headless boot is unaffected;
//   - anything the operator typed that is refused (v1 document invalid, bare
//     key without a pin, malformed key) is TERMINAL (ErrProvisionRefused),
//     like every other v1 refusal: no fall-through to a weaker source. The
//     agent unit restarts and prompts again.
//
// The accepted identity is STAGED at /run/powernode/identity.cfg (0600, tmpfs)
// as a v1 document, and the identity is the re-parse of the staged bytes.
// Staging (rather than returning the identity in memory only) is deliberate:
// DefaultResolver is invoked from several places (boot, runtime service,
// CLI), and the staged file is found by LocalIdentityStrategy ahead of this
// strategy, so the operator is never prompted twice.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	// DefaultConsolePromptTimeout bounds the wait for the operator.
	DefaultConsolePromptTimeout = 60 * time.Second
	// DefaultStagePath is where the accepted identity is staged.
	DefaultStagePath = "/run/powernode/identity.cfg"
	// consolePlaceholderInstance is the instance_id of a staged bare key: the
	// server derives the instance from the token, the agent only needs a
	// well-formed subject. It is the nil UUID.
	consolePlaceholderInstance = "00000000-0000-0000-0000-000000000000"
	// ConsolePurpose marks a document staged by the console prompt.
	ConsolePurpose = "console-prompt"
	// DefaultLockPath serialises console readers; DefaultRefusalsPath counts
	// consecutive refusals (both on tmpfs, so they reset every boot).
	DefaultLockPath     = "/run/powernode/console-prompt.lock"
	DefaultRefusalsPath = "/run/powernode/console-refusals"
	// MaxConsoleRefusals consecutive refusals disable the prompt for this boot
	// so a wedged or hostile console cannot block the claim poll forever.
	MaxConsoleRefusals = 3
)

// PlaceholderInstanceID is the nil UUID a bare console key is staged with.
const PlaceholderInstanceID = consolePlaceholderInstance

// initrdReleasePath exists only in the initramfs (systemd convention).
var initrdReleasePath = "/etc/initrd-release"

// ConsoleTTY is the injectable terminal. Control runs f with the raw file
// descriptor (os.File.SyscallConn().Control) without altering blocking mode.
type ConsoleTTY interface {
	io.ReadWriteCloser
	Control(f func(fd uintptr)) error
}

// Termios is the injectable terminal-mode seam.
type Termios interface {
	// DisableEcho turns echo (and line buffering) off for fd, flushes pending
	// input, and returns a restore func.
	DisableEcho(fd uintptr) (restore func(), err error)
}

// ConsolePromptStrategy: see the file comment. Zero value is production-ready.
type ConsolePromptStrategy struct {
	Open         func() (ConsoleTTY, error)        // default: /dev/console
	Term         Termios                           // default: the platform termios
	Timeout      time.Duration                     // 0 = 60s; <0 = prompt disabled
	Skip         func() bool                       // true = do not prompt (default: node already enrolled)
	BootStrategy Strategy                          // default: BootIdentityStrategy (/boot/identity.cfg)
	StagePath    string                            // default: /run/powernode/identity.cfg
	LockPath     string                            // default: /run/powernode/console-prompt.lock
	RefusalsPath string                            // default: /run/powernode/console-refusals
	Lock         func(path string) (func(), error) // default: flock (Linux)
	Now          func() time.Time
}

func (s *ConsolePromptStrategy) Name() string { return "console-prompt" }

func wipe(b []byte) {
	for i := range b {
		b[i] = 0
	}
}

type lineResult struct {
	buf []byte
	err error
}

// jsonScan tracks brace depth, string and escape state of pasted JSON.
type jsonScan struct {
	depth      int
	inStr, esc bool
	started    bool
}

func (j *jsonScan) feed(c byte) {
	switch {
	case j.inStr && j.esc:
		j.esc = false
	case j.inStr && c == '\\':
		j.esc = true
	case j.inStr && c == '"':
		j.inStr = false
	case j.inStr:
	case c == '"':
		j.inStr = true
	case c == '{':
		j.depth++
		j.started = true
	case c == '}':
		j.depth--
	}
}

func (j *jsonScan) done() bool { return j.started && j.depth <= 0 && !j.inStr }

func rescan(buf []byte) jsonScan {
	var j jsonScan
	for _, c := range buf {
		j.feed(c)
	}
	return j
}

// readMasked reads the operator's input byte-wise (the terminal is in
// non-canonical mode, so it is not bound by the 4 KiB canonical line limit).
// A bare key ends at the first Enter. When the first non-space byte is '{' the
// input is a pasted JSON document: it is read across newlines until the braces
// balance (string- and escape-aware), so a pretty-printed paste works. Both are
// capped at max bytes.
func readMasked(r io.Reader, max int) ([]byte, error) {
	buf := make([]byte, 0, 256)
	one := make([]byte, 1)
	var js jsonScan
	isDoc := false
	defer wipe(one)
	for {
		n, err := r.Read(one)
		if n == 1 {
			switch c := one[0]; {
			case c == '\n' || c == '\r':
				if !isDoc {
					return buf, nil
				}
				buf = append(buf, '\n') // whitespace inside a document
			case c == 0x7f || c == 0x08:
				if len(buf) > 0 {
					buf[len(buf)-1] = 0
					buf = buf[:len(buf)-1]
					if isDoc {
						js = rescan(buf)
					}
				}
			case c == 0x15: // ^U: kill input
				wipe(buf)
				buf, isDoc, js = buf[:0], false, jsonScan{}
			case c < 0x20 && c != '\t':
				// ignore other control characters
			default:
				if len(buf) >= max {
					wipe(buf)
					return nil, refuse("input too large")
				}
				buf = append(buf, c)
				if !isDoc && c == '{' && len(strings.TrimSpace(string(buf[:len(buf)-1]))) == 0 {
					isDoc = true
				}
				if isDoc {
					js.feed(c)
					if js.done() {
						return buf, nil
					}
				}
			}
		}
		if err != nil {
			if len(buf) > 0 && errors.Is(err, io.EOF) {
				return buf, nil
			}
			wipe(buf)
			return nil, err
		}
	}
}

func (s *ConsolePromptStrategy) skipped() bool {
	if s.Timeout < 0 {
		return true
	}
	if s.Skip != nil {
		return s.Skip()
	}
	// Initramfs only: after the pivot the console belongs to getty units, and
	// an unenrolled node never gets past the initramfs anyway.
	if _, err := os.Stat(initrdReleasePath); err != nil {
		return true
	}
	return alreadyEnrolled()
}

// alreadyEnrolled reports whether PKI material exists, so an enrolled node is
// never prompted on a later resolve.
func alreadyEnrolled() bool {
	for _, d := range []string{"/persist/var/lib/powernode/pki", "/var/lib/powernode/pki"} {
		if st, err := os.Stat(filepath.Join(d, "node.crt")); err == nil && st.Size() > 0 {
			return true
		}
	}
	return false
}

func (s *ConsolePromptStrategy) refusalsPath() string {
	if s.RefusalsPath != "" {
		return s.RefusalsPath
	}
	return consoleRefusalsPath
}

func (s *ConsolePromptStrategy) refuseTerminal(err error) error {
	bumpRefusals(s.refusalsPath())
	return err
}

func (s *ConsolePromptStrategy) Discover(ctx context.Context) (*Identity, error) {
	if s.skipped() || refusalCount(s.refusalsPath()) >= MaxConsoleRefusals {
		return nil, ErrNotFound
	}
	// Same activation as the claim poll: only a generic-image node (boot
	// identity.cfg with SERVER) is prompted. A cloud VM or any node without a
	// boot config is never blocked here; its cloud sources come next. A key
	// already baked on BOOT (KEY=) is an earlier source: no prompt.
	bootStrat := s.BootStrategy
	if bootStrat == nil {
		bootStrat = &BootIdentityStrategy{}
	}
	boot, berr := bootStrat.Discover(ctx)
	if berr != nil {
		if errors.Is(berr, ErrProvisionRefused) {
			return nil, berr
		}
		return nil, ErrNotFound
	}
	if boot == nil || boot.PlatformURL == "" || boot.BootstrapToken != "" {
		return nil, ErrNotFound
	}

	// One reader at a time: never share the tty.
	lock := s.Lock
	if lock == nil {
		lock = lockConsole
	}
	lockPath := s.LockPath
	if lockPath == "" {
		lockPath = DefaultLockPath
	}
	unlock, lerr := lock(lockPath)
	if lerr != nil {
		return nil, ErrNotFound
	}
	defer unlock()

	open := s.Open
	if open == nil {
		open = openConsole
	}
	tty, err := open()
	if err != nil || tty == nil {
		return nil, ErrNotFound // headless: no console to prompt on
	}
	term := s.Term
	if term == nil {
		term = platformTermios{}
	}

	// Mask FIRST. If echo cannot be disabled, never read.
	var restoreFn func()
	var derr error
	if cerr := tty.Control(func(fd uintptr) { restoreFn, derr = term.DisableEcho(fd) }); cerr != nil || derr != nil || restoreFn == nil {
		_ = tty.Close()
		return nil, ErrNotFound
	}
	// Restore exactly once, and always BEFORE the tty is closed (the fd must
	// still be valid for the ioctl), including on panic.
	var restored sync.Once
	restore := func() { restored.Do(restoreFn) }
	defer func() { restore(); _ = tty.Close() }()

	// SIGTERM/SIGINT while prompting: restore the terminal, then die the way
	// the signal intended.
	sctx, stopSig := signalContext(ctx)
	defer stopSig()

	timeout := s.Timeout
	if timeout == 0 {
		timeout = DefaultConsolePromptTimeout
	}
	fmt.Fprintf(tty, "\r\npowernode: no enrolment key found. Paste a one-time key or a provisioning document and press Enter (input is hidden; %ds timeout, Enter alone skips): ", int(timeout.Seconds()))

	ch := make(chan lineResult, 1)
	go func() {
		b, e := readMasked(tty, provisionMaxDocBytes)
		ch <- lineResult{b, e}
	}()
	var res lineResult
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case res = <-ch:
	case <-timer.C:
		restore()
		_ = tty.Close() // unblocks the reader
		go func() { wipe((<-ch).buf) }()
		return nil, ErrNotFound
	case <-sctx.Done():
		restore()
		_ = tty.Close()
		go func() { wipe((<-ch).buf) }()
		if ctx.Err() == nil { // a signal, not the caller
			reraiseSignal()
		}
		return nil, sctx.Err()
	}
	restore()
	fmt.Fprint(tty, "\r\n")
	defer wipe(res.buf)

	if res.err != nil {
		if errors.Is(res.err, ErrProvisionRefused) {
			return nil, s.refuseTerminal(res.err)
		}
		return nil, ErrNotFound
	}
	input := strings.TrimSpace(string(res.buf))
	if input == "" {
		return nil, ErrNotFound
	}

	doc := []byte(input)
	defer wipe(doc)
	if !strings.HasPrefix(input, "{") {
		built, err := s.bareKeyDocument(boot, input)
		if err != nil {
			return nil, s.refuseTerminal(err)
		}
		defer wipe(built)
		doc = built
	}
	id, err := ParseProvisionDocument(doc)
	if err != nil {
		return nil, s.refuseTerminal(err) // terminal: wraps ErrProvisionRefused
	}
	// A pasted document may only enrol against the platform this image was
	// built for: same server, and the same pin when the image carries one.
	if strings.TrimSuffix(id.PlatformURL, "/") != strings.TrimSuffix(boot.PlatformURL, "/") {
		return nil, s.refuseTerminal(refuse("document server does not match the image's SERVER"))
	}
	if boot.CAFingerprint != "" && id.CAFingerprint != boot.CAFingerprint {
		return nil, s.refuseTerminal(refuse("document ca_fingerprint does not match the image's pin"))
	}
	if err := s.stage(doc); err != nil {
		return nil, fmt.Errorf("console-prompt: staging identity: %w", err)
	}
	id.CloudProvider = "console-prompt"
	return id, nil
}

// bareKeyDocument combines (b is the boot identity, SERVER already checked) a bare key with SERVER + pin (+ CA) from the boot
// identity.cfg into a v1 document. A bare key without a pin is refused.
func (s *ConsolePromptStrategy) bareKeyDocument(b *Identity, key string) ([]byte, error) {
	if len(key) > provisionMaxKey || !printable(key, false) || strings.ContainsAny(key, " \t") {
		return nil, refuse("key malformed")
	}
	if b.CAFingerprint == "" {
		return nil, refuse("a bare key needs SERVER and a CA pin from the boot identity.cfg; no pin available (paste a provisioning document instead)")
	}
	now := time.Now
	if s.Now != nil {
		now = s.Now
	}
	t := now().UTC()
	m := map[string]any{
		"version": 1, "server": b.PlatformURL, "instance_id": consolePlaceholderInstance,
		"key": key, "ca_fingerprint": b.CAFingerprint,
		"issued_at": t.Format(time.RFC3339), "expires_at": t.Add(24 * time.Hour).Format(time.RFC3339),
		"purpose": ConsolePurpose,
	}
	if b.CABundlePEM != "" {
		m["ca_pem"] = b.CABundlePEM
	}
	out, err := json.Marshal(m)
	if err != nil {
		return nil, refuse("could not build the document")
	}
	return out, nil
}

// stage writes doc to the staged identity path atomically with mode 0600.
func (s *ConsolePromptStrategy) stage(doc []byte) error {
	path := s.StagePath
	if path == "" {
		path = DefaultStagePath
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	tmp, err := os.OpenFile(filepath.Join(dir, ".identity.cfg.tmp"), os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	_, werr := tmp.Write(doc)
	cerr := tmp.Close()
	if werr != nil || cerr != nil {
		_ = os.Remove(tmp.Name())
		return errors.Join(werr, cerr)
	}
	if err := os.Chmod(tmp.Name(), 0o600); err != nil {
		_ = os.Remove(tmp.Name())
		return err
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		_ = os.Remove(tmp.Name())
		return err
	}
	return nil
}

// consolePromptTimeout reads powernode.console_prompt_timeout=<seconds> from
// the kernel cmdline: absent = 0 (the strategy's 60s default), 0 = disable the
// prompt (negative), N = N seconds.
func consolePromptTimeout(cmdlinePath string) time.Duration {
	raw, err := os.ReadFile(cmdlinePath)
	if err != nil {
		return 0
	}
	v, ok := parseCmdline(string(raw))["powernode.console_prompt_timeout"]
	if !ok || v == "" {
		return 0
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < 0 {
		return 0
	}
	if n == 0 {
		return -1
	}
	return time.Duration(n) * time.Second
}

// Package-level state paths (tests override them).
var (
	stagedIdentityPath  = DefaultStagePath
	consoleRefusalsPath = DefaultRefusalsPath
)

func refusalCount(path string) int {
	raw, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	n, _ := strconv.Atoi(strings.TrimSpace(string(raw)))
	return n
}

func bumpRefusals(path string) {
	_ = os.MkdirAll(filepath.Dir(path), 0o700)
	_ = os.WriteFile(path, []byte(strconv.Itoa(refusalCount(path)+1)), 0o600)
}

// InstanceLabel is the instance for log lines: the placeholder of a bare
// console key is not an instance, so it is not printed as one.
func (id *Identity) InstanceLabel() string {
	if id.InstanceUUID == PlaceholderInstanceID {
		return "(assigned by the platform at enrolment)"
	}
	return id.InstanceUUID
}

// EnrolSucceeded must be called after a successful enrolment: a console-staged
// document is plaintext key material and is deleted, and the refusal counter
// is reset. No-op for identities from any other source.
func (id *Identity) EnrolSucceeded() {
	if id == nil || id.Purpose != ConsolePurpose {
		return
	}
	_ = os.Remove(stagedIdentityPath)
	_ = os.Remove(consoleRefusalsPath)
}

// EnrolRefused must be called when the platform definitively refused (4xx) the
// credential: the staged console document is deleted so the next attempt
// re-prompts (or reaches the claim poll) instead of re-reading a dead key
// forever, and the refusal counts toward MaxConsoleRefusals.
func (id *Identity) EnrolRefused() {
	if id == nil || id.Purpose != ConsolePurpose {
		return
	}
	_ = os.Remove(stagedIdentityPath)
	bumpRefusals(consoleRefusalsPath)
}
