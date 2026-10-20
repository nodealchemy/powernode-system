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
)

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
	Open         func() (ConsoleTTY, error) // default: /dev/console
	Term         Termios                    // default: the platform termios
	Timeout      time.Duration              // 0 = 60s; <0 = prompt disabled
	Skip         func() bool                // true = do not prompt (default: node already enrolled)
	BootStrategy Strategy                   // default: BootIdentityStrategy (/boot/identity.cfg)
	StagePath    string                     // default: /run/powernode/identity.cfg
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

// readMasked reads one line byte-wise (the terminal is in non-canonical mode,
// so it is not bound by the 4 KiB canonical line limit), handling backspace.
func readMasked(r io.Reader, max int) ([]byte, error) {
	buf := make([]byte, 0, 256)
	one := make([]byte, 1)
	for {
		n, err := r.Read(one)
		if n == 1 {
			switch c := one[0]; {
			case c == '\n' || c == '\r':
				wipe(one)
				return buf, nil
			case c == 0x7f || c == 0x08:
				if len(buf) > 0 {
					buf[len(buf)-1] = 0
					buf = buf[:len(buf)-1]
				}
			case c == 0x15: // ^U: kill line
				wipe(buf)
				buf = buf[:0]
			case c < 0x20:
				// ignore other control characters
			default:
				if len(buf) >= provisionMaxDocBytes {
					wipe(one)
					wipe(buf)
					return nil, refuse("input too large")
				}
				buf = append(buf, c)
			}
		}
		if err != nil {
			wipe(one)
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

func (s *ConsolePromptStrategy) Discover(ctx context.Context) (*Identity, error) {
	if s.skipped() {
		return nil, ErrNotFound
	}
	// Same activation as the claim poll: only a generic-image node (boot
	// identity.cfg with SERVER) is prompted. A cloud VM or any node without a
	// boot config is never blocked here; its cloud sources come next.
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
	if boot == nil || boot.PlatformURL == "" {
		return nil, ErrNotFound
	}
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
	var restore func()
	var derr error
	if cerr := tty.Control(func(fd uintptr) { restore, derr = term.DisableEcho(fd) }); cerr != nil || derr != nil || restore == nil {
		_ = tty.Close()
		return nil, ErrNotFound
	}

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
		_ = tty.Close() // unblocks the reader
		restore()
		go func() { wipe((<-ch).buf) }()
		return nil, ErrNotFound
	}
	restore()
	fmt.Fprint(tty, "\r\n")
	_ = tty.Close()
	defer wipe(res.buf)

	if res.err != nil {
		if errors.Is(res.err, ErrProvisionRefused) {
			return nil, res.err
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
			return nil, err
		}
		defer wipe(built)
		doc = built
	}
	id, err := ParseProvisionDocument(doc)
	if err != nil {
		return nil, err // terminal: wraps ErrProvisionRefused
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
		"purpose": "console-prompt",
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
