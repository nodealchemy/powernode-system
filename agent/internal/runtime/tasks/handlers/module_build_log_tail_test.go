package handlers

import (
	"encoding/base64"
	"fmt"
	"math/rand"
	"strings"
	"testing"
	"time"
)

// wantKeyBodyMarker is the contract text a stripped run is replaced with.
const wantKeyBodyMarker = "[truncated key material removed]"

// IMP-33ab99763220 — a log_tail window is a byte-bounded cut of a stream. A
// headed key is removed from the whole stream before the cut (the tests
// further down); a body printed WITHOUT its header (the fallback exercised
// here, so these fixtures carry no BEGIN line at all) can still straddle the
// cut and leave a headerless PEM body at the window's start, which no
// header-keyed server pattern can see. The window must drop that body.

// syntheticPEMBody is seeded random bytes in 64-column standard base64, the
// shape of a PEM body. Synthetic only — never key material.
func syntheticPEMBody(t *testing.T, seed int64, n int) []string {
	t.Helper()
	raw := make([]byte, n*48)
	rand.New(rand.NewSource(seed)).Read(raw)
	enc := base64.StdEncoding.EncodeToString(raw)
	lines := make([]string, 0, n)
	for len(enc) > 0 {
		cut := min(64, len(enc))
		lines = append(lines, enc[:cut])
		enc = enc[cut:]
	}
	return lines
}

func filler(prefix string, n int) string {
	var b strings.Builder
	for i := 0; i < n; i++ {
		fmt.Fprintf(&b, "%s line %d of ordinary build output\n", prefix, i)
	}
	return b.String()
}

// requireCutInsideBody fails the test unless the window's first byte lands
// after the BEGIN line and inside the body: otherwise a passing assertion
// would be positional, not the strip.
func requireCutInsideBody(t *testing.T, stream []byte, max int, probe string) string {
	t.Helper()
	if len(stream) <= max {
		t.Fatalf("fixture: stream of %d bytes is not cut at %d", len(stream), max)
	}
	window := string(stream[len(stream)-max:])
	if strings.Contains(window, "-----BEGIN") {
		t.Fatalf("fixture: BEGIN header is inside the window; the cut must land in the body")
	}
	if !strings.Contains(window, probe) {
		t.Fatalf("fixture: probe body line is not inside the window")
	}
	return window
}

func TestLogTail_CutInsideStdoutKeyBodyStripsThroughEnd(t *testing.T) {
	// An RSA-4096-sized body (50 lines) with ~1 KB of output after it: the
	// 4096-byte window opens a few hundred bytes into the body.
	body := syntheticPEMBody(t, 33, 50)
	probe := body[len(body)-3]
	stdout := []byte(filler("npm notice", 20) +
		strings.Join(body, "\n") + "\n-----END RSA PRIVATE KEY-----\n" +
		filler("npm notice", 25) + `{"ok":true,"module":"demo"}` + "\n")
	requireCutInsideBody(t, stdout, logTailMaxBytes, probe)

	tail := logTail(stdout, []byte("build ok"))
	if strings.Contains(tail, probe) {
		t.Fatalf("headerless key body survived the stdout cut:\n%s", tail)
	}
	if !strings.HasPrefix(tail, "stdout: "+wantKeyBodyMarker+"\n") {
		t.Fatalf("expected the marker right after the stdout prefix, got:\n%s", tail)
	}
	if strings.Contains(tail, "-----END") {
		t.Fatalf("END marker should be dropped with the body:\n%s", tail)
	}
	if !strings.Contains(tail, `{"ok":true,"module":"demo"}`) {
		t.Fatalf("result line after the key must survive:\n%s", tail)
	}
	if !strings.HasSuffix(tail, "\nstderr: build ok") {
		t.Fatalf("stderr window must be untouched:\n%s", tail)
	}
}

func TestLogTail_CutInsideStderrKeyBodyStripsThroughEnd(t *testing.T) {
	// The body straddles the 131072-byte cut because the stages AFTER the key
	// print ~120 KB of diagnostics; the window opens a few lines into it.
	body := syntheticPEMBody(t, 34, 190)
	probe := body[len(body)-3]
	after := "-----END OPENSSH PRIVATE KEY-----\r\n" + filler("npm WARN", 2800) + "error: stage 3 failed\n"
	if len(after) >= logTailStderrMaxBytes {
		t.Fatalf("fixture: trailing output must be shorter than the stderr window")
	}
	stderr := []byte(filler("apt", 50) + strings.Join(body, "\r\n") + "\r\n" + after)
	requireCutInsideBody(t, stderr, logTailStderrMaxBytes, probe)

	tail := logTail([]byte(`{"ok":false}`), stderr)
	if strings.Contains(tail, probe) {
		t.Fatalf("headerless key body survived the stderr cut")
	}
	if !strings.Contains(tail, "\nstderr: "+wantKeyBodyMarker+"\n") {
		t.Fatalf("expected the marker right after the stderr prefix, got head:\n%.300s", tail)
	}
	if strings.Contains(tail, "-----END") {
		t.Fatalf("END marker should be dropped with the body")
	}
	if !strings.HasSuffix(tail, "error: stage 3 failed") || !strings.Contains(tail, "npm WARN line 0 of ordinary build output") {
		t.Fatalf("diagnostics after the key must survive, got tail end:\n%.300s", tail[len(tail)-300:])
	}
	if !strings.HasPrefix(tail, "stdout: {\"ok\":false}\n") {
		t.Fatalf("stdout window must be untouched:\n%.100s", tail)
	}
}

func TestLogTail_CutInsideKeyBodyWithoutEndDropsOnlyBodyLines(t *testing.T) {
	body := syntheticPEMBody(t, 35, 50)
	probe := body[len(body)-3]
	after := "stage 2: packaging\n" + filler("stage 2", 25) + `{"ok":true}` + "\n"
	stdout := []byte(filler("npm notice", 20) + strings.Join(body, "\n") + "\n" + after)
	requireCutInsideBody(t, stdout, logTailMaxBytes, probe)

	tail := logTail(stdout, []byte("ok"))
	if strings.Contains(tail, probe) {
		t.Fatalf("headerless key body survived the cut:\n%s", tail)
	}
	want := "stdout: " + wantKeyBodyMarker + "\n" + strings.TrimSpace(after) + "\nstderr: ok"
	if tail != want {
		t.Fatalf("expected the first prose line onward to survive verbatim, got:\n%s", tail)
	}
}

func TestLogTail_CutInsideKeyBodyRunningToEndLeavesOnlyTheMarker(t *testing.T) {
	body := syntheticPEMBody(t, 36, 80)
	probe := body[len(body)-3]
	stdout := []byte(filler("npm notice", 5) + strings.Join(body, "\n") + "\n")
	requireCutInsideBody(t, stdout, logTailMaxBytes, probe)

	tail := logTail(stdout, []byte("ok"))
	if want := "stdout: " + wantKeyBodyMarker + "\nstderr: ok"; tail != want {
		t.Fatalf("expected only the marker, got:\n%s", tail)
	}
}

func TestLogTail_CutInsideOrdinaryLogLinesIsUntouched(t *testing.T) {
	// The window opens on "deprecated": base64-alphabet-only, like a body
	// fragment, but followed by ordinary lines. It must survive verbatim.
	var window strings.Builder
	window.WriteString("deprecated\n")
	for window.Len() < logTailMaxBytes {
		window.WriteString("npm WARN deprecated foo@1.2.3: use bar instead\n")
	}
	w := window.String()[:logTailMaxBytes]
	stdout := []byte("npm WARN " + w)

	tail := logTail(stdout, []byte("ok"))
	if want := "stdout: " + strings.TrimSpace(w) + "\nstderr: ok"; tail != want {
		t.Fatalf("ordinary cut window was altered, got:\n%.200s", tail)
	}
	if strings.Contains(tail, wantKeyBodyMarker) {
		t.Fatalf("no key material, no marker")
	}
}

func TestLogTail_NoCutWindowsAreUnchanged(t *testing.T) {
	body := syntheticPEMBody(t, 37, 3)
	stdout := strings.Join(body, "\n") + "\n-----END RSA PRIVATE KEY-----\n"
	stderr := "warn: something\n"

	tail := logTail([]byte(stdout), []byte(stderr))
	if want := "stdout: " + strings.TrimSpace(stdout) + "\nstderr: " + strings.TrimSpace(stderr); tail != want {
		t.Fatalf("an uncut window must be served as before, got:\n%s", tail)
	}
}

func TestLogTail_CutInsideEncryptionHeaderKeepsFragmentAndStripsBody(t *testing.T) {
	// The cut lands in the Proc-Type line of a headerless encrypted body: the
	// window opens on a fragment that is not base64 ("Type: 4,ENCRYPTED"),
	// which is kept, while the DEK-Info line and the body after it are
	// stripped through the END footer.
	body := syntheticPEMBody(t, 38, 50)
	probe := body[len(body)-3]
	head := "Type: 4,ENCRYPTED\nDEK-Info: AES-128-CBC,0123456789ABCDEF0123456789ABCDEF\n\n" +
		strings.Join(body, "\n") + "\n-----END RSA PRIVATE KEY-----\n"
	rest := filler("npm notice", 40)[:logTailMaxBytes-len(head)]
	stdout := []byte("Proc-" + head + rest)
	if len(stdout)-logTailMaxBytes != len("Proc-") {
		t.Fatalf("fixture: window must open exactly at the header-line fragment")
	}

	tail := logTail(stdout, []byte("ok"))
	if strings.Contains(tail, probe) || strings.Contains(tail, "DEK-Info") {
		t.Fatalf("headerless key body survived the cut:\n%s", tail)
	}
	if want := "stdout: Type: 4,ENCRYPTED\n" + wantKeyBodyMarker + "\n" + strings.TrimSpace(rest) + "\nstderr: ok"; tail != want {
		t.Fatalf("expected the fragment kept and the body stripped, got:\n%.300s", tail)
	}
}

// ---- fix round: a HEADED key is redacted from the whole stream before the
// cut, so its placement relative to the window is irrelevant; the post-cut
// fallback tolerates whitespace and a short final body line.

// wantKeyBlockMarker is the contract text a whole private-key block is
// replaced with before the window is cut.
const wantKeyBlockMarker = "[key material removed]"

// syntheticPEMBodyBytes draws n bytes so the last base64 line can be SHORT
// (a real body's last line is the remainder, 4..64 chars).
func syntheticPEMBodyBytes(t *testing.T, seed int64, n int) []string {
	t.Helper()
	raw := make([]byte, n)
	rand.New(rand.NewSource(seed)).Read(raw)
	enc := base64.StdEncoding.EncodeToString(raw)
	var lines []string
	for len(enc) > 0 {
		cut := min(64, len(enc))
		lines = append(lines, enc[:cut])
		enc = enc[cut:]
	}
	return lines
}

type headedKeyShape struct {
	name  string
	text  string // the key as it appears in the stream, BEGIN through END (plus any line terminator)
	probe string // a body chunk that sits after any cut landing inside the key
}

func headedKeyShapes(t *testing.T) []headedKeyShape {
	t.Helper()
	body := syntheticPEMBodyBytes(t, 41, 50*48+3) // last line is 4 chars
	if got := len(body[len(body)-1]); got != 4 {
		t.Fatalf("fixture: want a 4-char last line, got %d", got)
	}
	probe := body[len(body)-3]
	begin, end := "-----BEGIN RSA PRIVATE KEY-----", "-----END RSA PRIVATE KEY-----"
	indent := func(prefix string, lines []string) string {
		var b strings.Builder
		for _, l := range lines {
			b.WriteString(prefix + l + "\n")
		}
		return b.String()
	}
	all := append(append([]string{begin}, body...), end)
	return []headedKeyShape{
		{"plain LF, short last line", strings.Join(all, "\n") + "\n", probe},
		{"indented YAML block scalar", "rsa_private: |\n" + indent("      ", all), probe},
		{"per-line prefix", indent("#12 0.345 ", all), probe},
		{"JSON-escaped single line", `{"private_key":"` + strings.Join(all, `\n`) + `\n"}` + "\n", probe},
		{"echo $KEY single line", strings.Join(all, " ") + "\n", probe},
		{"trailing whitespace", strings.Join(all, " \t\n") + " \t\n", probe},
		{"CRLF", strings.Join(all, "\r\n") + "\r\n", probe},
	}
}

func TestLogTail_HeadedKeyWhollyInsideTheWindowIsRemoved(t *testing.T) {
	for _, shape := range headedKeyShapes(t) {
		t.Run(shape.name, func(t *testing.T) {
			stdout := []byte(filler("npm notice", 120) + shape.text + `{"ok":true}` + "\n")
			if len(stdout) <= logTailMaxBytes {
				t.Fatalf("fixture: stream must be cut")
			}
			window := string(stdout[len(stdout)-logTailMaxBytes:])
			if !strings.Contains(window, "-----BEGIN") || !strings.Contains(window, shape.probe) {
				t.Fatalf("fixture: the whole key must sit inside the window")
			}

			tail := logTail(stdout, []byte("ok"))
			if strings.Contains(tail, shape.probe) || strings.Contains(tail, "-----END") {
				t.Fatalf("headed key reached the tail:\n%.400s", tail)
			}
			if !strings.Contains(tail, wantKeyBlockMarker) || !strings.HasSuffix(tail, "{\"ok\":true}\nstderr: ok") {
				t.Fatalf("expected the block marker and the result line, got:\n%.400s", tail)
			}
		})
	}
}

func TestLogTail_CutInsideHeadedKeyIsRemovedWhateverItsForm(t *testing.T) {
	for _, shape := range headedKeyShapes(t) {
		t.Run(shape.name, func(t *testing.T) {
			stdout := []byte(filler("npm notice", 20) + shape.text + filler("npm notice", 25) + `{"ok":true}` + "\n")
			requireCutInsideBody(t, stdout, logTailMaxBytes, shape.probe)

			tail := logTail(stdout, []byte("ok"))
			if strings.Contains(tail, shape.probe) || strings.Contains(tail, "-----END") {
				t.Fatalf("key body survived the cut:\n%.400s", tail)
			}
			if !strings.HasSuffix(tail, "{\"ok\":true}\nstderr: ok") || !strings.Contains(tail, "npm notice line 0 of ordinary build output") {
				t.Fatalf("output after the key must survive, got:\n%.400s", tail)
			}
		})
	}
}

func TestLogTail_HeadedKeyInAnUncutStderrIsRemoved(t *testing.T) {
	shape := headedKeyShapes(t)[0]
	stderr := "warn: dumping config\n" + shape.text + "error: stage 3 failed\n"
	tail := logTail([]byte(`{"ok":false}`), []byte(stderr))
	if strings.Contains(tail, shape.probe) {
		t.Fatalf("headed key in an uncut window reached the tail")
	}
	if want := "stdout: {\"ok\":false}\nstderr: warn: dumping config\n" + wantKeyBlockMarker + "\nerror: stage 3 failed"; tail != want {
		t.Fatalf("got:\n%s", tail)
	}
}

func TestLogTail_ClippedHeadedKeyWithNoEndIsRemoved(t *testing.T) {
	body := syntheticPEMBodyBytes(t, 42, 30*48+3)
	probe := body[len(body)-3]
	stdout := "stage 1\n-----BEGIN OPENSSH PRIVATE KEY-----\n" + strings.Join(body, "\n")
	tail := logTail([]byte(stdout), []byte("ok"))
	if strings.Contains(tail, probe) || strings.Contains(tail, body[len(body)-1]) {
		t.Fatalf("clipped key body reached the tail:\n%.300s", tail)
	}
	if want := "stdout: stage 1\n" + wantKeyBlockMarker + "\nstderr: ok"; tail != want {
		t.Fatalf("got:\n%s", tail)
	}
}

func TestLogTail_ALineThatMerelyNamesAKeyFileKeepsTheProseAfterIt(t *testing.T) {
	stdout := "cosign: unsupported PEM block -----BEGIN RSA PRIVATE KEY----- in cosign.key\nstage 2: packaging\n"
	tail := logTail([]byte(stdout), []byte("ok"))
	if !strings.Contains(tail, "stage 2: packaging") || !strings.HasPrefix(tail, "stdout: cosign: unsupported PEM block ") {
		t.Fatalf("prose around a header MENTION must survive, got:\n%s", tail)
	}
}

func TestLogTail_HeadlessBodyWithShortLastLineIsStrippedThroughEnd(t *testing.T) {
	// The header fell before the STREAM (not just the window): only the
	// post-cut fallback can act, and the body's 4-char last line must not
	// stop it short of the END footer.
	body := syntheticPEMBodyBytes(t, 43, 50*48+3)
	probe := body[len(body)-3]
	short := body[len(body)-1]
	after := filler("npm notice", 25) + `{"ok":true}` + "\n"
	stdout := []byte(strings.Join(body, "\n") + "\n-----END RSA PRIVATE KEY-----\n" + after)
	requireCutInsideBody(t, stdout, logTailMaxBytes, probe)

	tail := logTail(stdout, []byte("ok"))
	if want := "stdout: " + wantKeyBodyMarker + "\n" + strings.TrimSpace(after) + "\nstderr: ok"; tail != want {
		t.Fatalf("expected the short last line and END dropped with the body, got:\n%.300s", tail)
	}
	if strings.Contains(tail, short) {
		t.Fatalf("short last line left behind")
	}
}

func TestLogTail_HeadlessIndentedBodyWithTrailingWhitespaceIsStripped(t *testing.T) {
	body := syntheticPEMBodyBytes(t, 44, 50*48)
	probe := body[len(body)-3]
	var key strings.Builder
	for _, l := range body {
		key.WriteString("    " + l + " \t\r\n")
	}
	key.WriteString("    -----END EC PRIVATE KEY-----  \r\n")
	after := filler("npm notice", 25) + `{"ok":true}` + "\n"
	stdout := []byte(key.String() + after)
	requireCutInsideBody(t, stdout, logTailMaxBytes, probe)

	tail := logTail(stdout, []byte("ok"))
	if want := "stdout: " + wantKeyBodyMarker + "\n" + strings.TrimSpace(after) + "\nstderr: ok"; tail != want {
		t.Fatalf("expected the indented body dropped through END, got:\n%.300s", tail)
	}
}

func TestLogTail_CutWindowOpeningOnDigestLinesIsUntouched(t *testing.T) {
	for _, first := range []string{
		"sha256:" + strings.Repeat("ab12", 16),
		"h1:" + strings.Repeat("Q", 43) + "=",
		"sha512-" + strings.Repeat("Ab", 43) + "==",
		strings.Repeat("0123456789abcdef", 2), // a lone base64-looking fragment, nothing body-shaped after it
	} {
		t.Run(first[:6], func(t *testing.T) {
			var window strings.Builder
			window.WriteString(first + "\n")
			for window.Len() < logTailMaxBytes {
				window.WriteString("npm WARN deprecated foo@1.2.3: use bar instead\n")
			}
			w := window.String()[:logTailMaxBytes]
			tail := logTail([]byte("cut here "+w), []byte("ok"))
			if want := "stdout: " + strings.TrimSpace(w) + "\nstderr: ok"; tail != want {
				t.Fatalf("ordinary cut window was altered, got:\n%.200s", tail)
			}
		})
	}
}

func TestLogTail_FragmentThenBareShaLineIsTheAcceptedResidual(t *testing.T) {
	// Accepted, bounded false positive: a base64 fragment followed by a bare
	// 40-hex line anchors the run; both go, the prose after them stays.
	var window strings.Builder
	window.WriteString("deadbe\n" + strings.Repeat("a1b2c3d4e5", 4) + "\n")
	for window.Len() < logTailMaxBytes {
		window.WriteString("npm WARN deprecated foo@1.2.3: use bar instead\n")
	}
	w := window.String()[:logTailMaxBytes]
	tail := logTail([]byte("cut here "+w), []byte("ok"))
	if !strings.HasPrefix(tail, "stdout: "+wantKeyBodyMarker+"\nnpm WARN deprecated") {
		t.Fatalf("got:\n%.200s", tail)
	}
}

func BenchmarkLogTail_StderrWindowWithKeys(b *testing.B) {
	t := &testing.T{}
	body := syntheticPEMBodyBytes(t, 45, 50*48+3)
	key := "-----BEGIN RSA PRIVATE KEY-----\n" + strings.Join(body, "\n") + "\n-----END RSA PRIVATE KEY-----\n"
	stderr := []byte(filler("apt", 1500) + key + filler("npm WARN", 1500) + key + filler("stage 3", 1500) + key + filler("stage 4", 500))
	stdout := []byte(filler("npm notice", 100) + key + `{"ok":true}` + "\n")
	b.SetBytes(int64(len(stdout) + len(stderr)))
	b.ReportAllocs()
	for b.Loop() {
		_ = logTail(stdout, stderr)
	}
}

func BenchmarkLogTail_StderrWindowAllBodyNoEnd(b *testing.B) {
	// Worst case for both passes: a BEGIN with no END and a whole window of
	// body lines, so the lazy span scans to the end and the clipped
	// alternative consumes every line.
	t := &testing.T{}
	body := syntheticPEMBodyBytes(t, 46, 2100*48)
	stderr := []byte("-----BEGIN RSA PRIVATE KEY-----\n" + strings.Join(body, "\n"))
	if len(stderr) < logTailStderrMaxBytes {
		b.Fatalf("fixture: stderr must exceed the window")
	}
	b.SetBytes(int64(len(stderr)))
	b.ReportAllocs()
	for b.Loop() {
		_ = logTail([]byte(`{"ok":false}`), stderr)
	}
}

// ---- fix round 2: the block pass must be linear in the stream whatever the
// number of headers (critic B N1), must consume whole lines only (N2), must
// take an unwrapped clipped body whole (N3); the mention-plus-far-footer
// trade-off is bounded (N4); residuals are pinned (N5).

const fastEnough = 5 * time.Second // a quadratic pass measured 49-65 s on these shapes

// wantBlockSpanBound mirrors the contract: a header whose nearest footer is
// further away than this is clipped, not paired (pemBlockMaxSpan).
const wantBlockSpanBound = 128 << 10

func timedLogTail(t *testing.T, stdout, stderr []byte) string {
	t.Helper()
	start := time.Now()
	tail := logTail(stdout, stderr)
	if took := time.Since(start); took > fastEnough {
		t.Fatalf("logTail took %s on %d+%d bytes; the block pass must be linear", took, len(stdout), len(stderr))
	}
	return tail
}

func TestLogTail_ManyHeaderLinesWithoutFooterIsLinear(t *testing.T) {
	// 256 KiB of nothing but BEGIN lines and no footer anywhere: 8192
	// unpaired headers.
	line := "-----BEGIN RSA PRIVATE KEY-----\n"
	stderr := []byte(strings.Repeat(line, (256<<10)/len(line)))
	tail := timedLogTail(t, []byte(`{"ok":false}`), stderr)
	if strings.Contains(tail, "-----BEGIN") {
		t.Fatalf("an unpaired header must still be replaced")
	}
}

func TestLogTail_ManyHeaderMentionsWithoutFooterIsLinear(t *testing.T) {
	// A secret-scan report: 1000 lines that MENTION a header, ~2 KB of
	// ordinary output between them, no footer anywhere (~2 MB).
	var b strings.Builder
	for i := 0; i < 1000; i++ {
		fmt.Fprintf(&b, "leak-scan: matched -----BEGIN RSA PRIVATE KEY----- in fixtures/k%d.pem\n", i)
		b.WriteString(filler("scan", 45))
	}
	b.WriteString("scan complete\n")
	tail := timedLogTail(t, []byte(`{"ok":false}`), []byte(b.String()))
	if strings.Contains(tail, "-----BEGIN") || !strings.HasSuffix(tail, "scan complete") {
		t.Fatalf("mentions must be replaced and the report kept, got tail end:\n%.200s", tail[len(tail)-200:])
	}
	if !strings.Contains(tail, wantKeyBlockMarker+" in fixtures/k999.pem") {
		t.Fatalf("the rest of a mention line must survive, got tail end:\n%.300s", tail[len(tail)-300:])
	}
}

func TestLogTail_HeaderMentionThenFarFooterKeepsTheDiagnosticsBetween(t *testing.T) {
	// A mention, then more lint output than the span bound, then an
	// unrelated footer line: the mention is treated as clipped, nothing
	// between is lost and the lone footer line stays as the text it is.
	// (Through removeKeyBlocks directly: the stream is wider than any window.)
	between := filler("lint", 3400)
	if len(between) <= wantBlockSpanBound {
		t.Fatalf("fixture: %d bytes between is not past the bound", len(between))
	}
	in := "finding 1: -----BEGIN RSA PRIVATE KEY-----\n" + between + "finding 2: -----END RSA PRIVATE KEY-----\nsummary\n"
	start := time.Now()
	out := string(removeKeyBlocks([]byte(in)))
	if took := time.Since(start); took > fastEnough {
		t.Fatalf("removeKeyBlocks took %s", took)
	}
	if want := "finding 1: " + wantKeyBlockMarker + "\n" + between + "finding 2: -----END RSA PRIVATE KEY-----\nsummary\n"; out != want {
		t.Fatalf("got head:\n%.200s\n...tail:\n%.200s", out, out[len(out)-200:])
	}
}

func TestLogTail_HeaderMentionThenNearFooterIsTheStatedTradeOff(t *testing.T) {
	// Within the span bound a mention and a later footer are one block: the
	// text between is LOST, not leaked. Pinned as the accepted trade-off.
	stderr := "finding 1: -----BEGIN RSA PRIVATE KEY-----\n" + filler("lint", 99) + "finding 100: -----END RSA PRIVATE KEY-----\nsummary\n"
	tail := timedLogTail(t, []byte(`{"ok":false}`), []byte(stderr))
	if want := "stdout: {\"ok\":false}\nstderr: finding 1: " + wantKeyBlockMarker + "\nsummary"; tail != want {
		t.Fatalf("got:\n%.300s", tail)
	}
}

func TestLogTail_ClippedBodyKeepsTheFollowingLineIntact(t *testing.T) {
	l64 := syntheticPEMBody(t, 51, 1)[0]
	begin := "-----BEGIN RSA PRIVATE KEY-----"
	for _, tc := range []struct{ name, in, want string }{
		{"plain next line", "stage 0\n" + begin + "\n" + l64 + "\n" + l64 + "\nnext step\n",
			"stdout: stage 0\n" + wantKeyBlockMarker + "\nnext step\nstderr: ok"},
		{"next line opens with a 36-char word", "stage 0\n" + begin + "\n" + l64 + "\nabcdefghijklmnopqrstuvwxyz0123456789 is next\n",
			"stdout: stage 0\n" + wantKeyBlockMarker + "\nabcdefghijklmnopqrstuvwxyz0123456789 is next\nstderr: ok"},
		{"blank line then prose", "stage 0\n" + begin + "\n" + l64 + "\n\nnext step\n",
			"stdout: stage 0\n" + wantKeyBlockMarker + "\nnext step\nstderr: ok"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := logTail([]byte(tc.in), []byte("ok")); got != tc.want {
				t.Fatalf("got:\n%s\nwant:\n%s", got, tc.want)
			}
		})
	}
}

func TestLogTail_ClippedUnwrappedBodyIsRemovedWhole(t *testing.T) {
	in := "stage 0\n-----BEGIN RSA PRIVATE KEY-----\n" + strings.Repeat("Q", 300) + "\nnext\n"
	if got, want := logTail([]byte(in), []byte("ok")), "stdout: stage 0\n"+wantKeyBlockMarker+"\nnext\nstderr: ok"; got != want {
		t.Fatalf("got:\n%.200s", got)
	}
}

func TestLogTail_SSH2HeadedKeyIsRemoved(t *testing.T) {
	body := syntheticPEMBody(t, 52, 6)
	in := "stage 0\n---- BEGIN SSH2 ENCRYPTED PRIVATE KEY ----\nComment: \"synthetic\"\n" + strings.Join(body, "\n") + "\n---- END SSH2 ENCRYPTED PRIVATE KEY ----\nnext\n"
	got := logTail([]byte(in), []byte("ok"))
	if strings.Contains(got, body[2]) || got != "stdout: stage 0\n"+wantKeyBlockMarker+"\nnext\nstderr: ok" {
		t.Fatalf("got:\n%.300s", got)
	}
}

func TestLogTail_AcceptedResidualsArePinned(t *testing.T) {
	body := syntheticPEMBody(t, 53, 4)
	t.Run("clipped key with a per-line prefix keeps its body", func(t *testing.T) {
		var b strings.Builder
		b.WriteString("#8 0.1 -----BEGIN RSA PRIVATE KEY-----\n")
		for _, l := range body {
			b.WriteString("#8 0.1 " + l + "\n")
		}
		got := logTail([]byte(b.String()), []byte("ok"))
		if !strings.HasPrefix(got, "stdout: #8 0.1 "+wantKeyBlockMarker+"\n#8 0.1 "+body[0]) {
			t.Fatalf("residual changed shape, got:\n%.300s", got)
		}
	})
	t.Run("base64 of a whole PEM is not seen", func(t *testing.T) {
		pem := "-----BEGIN RSA PRIVATE KEY-----\n" + strings.Join(body, "\n") + "\n-----END RSA PRIVATE KEY-----\n"
		in := "tls.key: " + base64.StdEncoding.EncodeToString([]byte(pem)) + "\n"
		if got := logTail([]byte(in), []byte("ok")); got != "stdout: "+strings.TrimSpace(in)+"\nstderr: ok" {
			t.Fatalf("residual changed shape, got:\n%.300s", got)
		}
	})
}

func BenchmarkLogTail_ManyHeaderLinesNoFooter(b *testing.B) {
	line := "-----BEGIN RSA PRIVATE KEY-----\n"
	stderr := []byte(strings.Repeat(line, (256<<10)/len(line)))
	b.SetBytes(int64(len(stderr)))
	for b.Loop() {
		_ = logTail([]byte(`{"ok":false}`), stderr)
	}
}

func BenchmarkLogTail_ManyHeaderMentionsNoFooter(b *testing.B) {
	var s strings.Builder
	for i := 0; i < 1000; i++ {
		fmt.Fprintf(&s, "leak-scan: matched -----BEGIN RSA PRIVATE KEY----- in fixtures/k%d.pem\n", i)
		s.WriteString(filler("scan", 45))
	}
	stderr := []byte(s.String())
	b.SetBytes(int64(len(stderr)))
	for b.Loop() {
		_ = logTail([]byte(`{"ok":false}`), stderr)
	}
}

// ---- fix round 2, critic A addendum: its own cost shape (M1), a clipped key
// whose stream ends with a newline (L1), a truncated JSON-escaped key (L3),
// and the 76-column base64 over-redaction pinned as accepted.

func cosignMentionStream(mentions, between int) []byte {
	var b strings.Builder
	for i := 0; i < mentions; i++ {
		b.WriteString("cosign: unsupported PEM block -----BEGIN RSA PRIVATE KEY----- in cosign.key\n")
		b.WriteString(filler("stage", between))
	}
	b.WriteString("build complete\n")
	return []byte(b.String())
}

func TestLogTail_CosignMentionsWithoutFooterIsLinear(t *testing.T) {
	// Critic A's input: the cosign line 100 times with ~250 ordinary lines
	// between, no END anywhere (~0.95 MB). The regex span took 2.4 s here and
	// 15.7 s at 800 mentions.
	stderr := cosignMentionStream(100, 250)
	if len(stderr) < 900<<10 {
		t.Fatalf("fixture: %d bytes is smaller than the measured shape", len(stderr))
	}
	tail := timedLogTail(t, []byte(`{"ok":false}`), stderr)
	if strings.Contains(tail, "-----BEGIN") || !strings.HasSuffix(tail, "build complete") {
		t.Fatalf("got tail end:\n%.200s", tail[len(tail)-200:])
	}
	if !strings.Contains(tail, "cosign: unsupported PEM block "+wantKeyBlockMarker+" in cosign.key\nstage line 0 of ordinary build output") {
		t.Fatalf("the mention line and the line after it must survive intact, got:\n%.400s", tail[len(tail)-400:])
	}
}

func TestLogTail_ClippedKeyWhoseStreamEndsWithANewlineIsRemovedWhole(t *testing.T) {
	// L1: tools end their output with a newline; the 4-char remainder of a
	// clipped key must still go with the body.
	body := syntheticPEMBodyBytes(t, 61, 30*48+3)
	short := body[len(body)-1]
	for _, nl := range []string{"\n", "\r\n"} {
		in := "stage 1" + nl + "-----BEGIN OPENSSH PRIVATE KEY-----" + nl + strings.Join(body, nl) + nl
		tail := logTail([]byte(in), []byte("ok"))
		if strings.Contains(tail, short) || tail != "stdout: stage 1"+nl+wantKeyBlockMarker+"\nstderr: ok" {
			t.Fatalf("remainder survived for %q, got:\n%.300s", nl, tail)
		}
	}
}

func TestLogTail_TruncatedJSONEscapedKeyWithoutFooterIsRemoved(t *testing.T) {
	// L3: a JSON dump that stopped mid-key is ONE physical line with literal
	// \n separators and no footer.
	body := syntheticPEMBody(t, 62, 6)
	in := `{"name":"demo","private_key":"-----BEGIN PRIVATE KEY-----\n` + strings.Join(body, `\n`) + `\n` + body[0][:20]
	tail := logTail([]byte(in), []byte("ok"))
	if strings.Contains(tail, body[2]) || strings.Contains(tail, body[0][:20]) {
		t.Fatalf("escaped clipped body survived:\n%.300s", tail)
	}
	if want := `stdout: {"name":"demo","private_key":"` + wantKeyBlockMarker + "\nstderr: ok"; tail != want {
		t.Fatalf("got:\n%.300s", tail)
	}
}

func TestLogTail_CutInsideA76ColumnBase64BlobIsTheAcceptedOverRedaction(t *testing.T) {
	// A headerless `base64` dump (76 columns, not a key) that straddles the
	// cut is indistinguishable from a key body: the fallback marker replaces
	// it. Lost, not leaked; pinned as accepted.
	raw := make([]byte, 60*57)
	rand.New(rand.NewSource(63)).Read(raw)
	enc := base64.StdEncoding.EncodeToString(raw)
	var blob strings.Builder
	for len(enc) > 0 {
		cut := min(76, len(enc))
		blob.WriteString(enc[:cut] + "\n")
		enc = enc[cut:]
	}
	after := filler("stage", 20)
	stdout := []byte("dump:\n" + blob.String() + after)
	if len(stdout) <= logTailMaxBytes || len(after) >= logTailMaxBytes {
		t.Fatalf("fixture: the cut must land inside the blob")
	}
	tail := logTail(stdout, []byte("ok"))
	if want := "stdout: " + wantKeyBodyMarker + "\n" + strings.TrimSpace(after) + "\nstderr: ok"; tail != want {
		t.Fatalf("over-redaction changed shape, got:\n%.300s", tail)
	}
}

func BenchmarkLogTail_CosignMentionsNoFooter6400(b *testing.B) {
	stderr := cosignMentionStream(6400, 22) // ~6.3 MB, critic A's prototype target: 24 ms
	b.SetBytes(int64(len(stderr)))
	for b.Loop() {
		_ = logTail([]byte(`{"ok":false}`), stderr)
	}
}

// ---- round 3 (critic B L1, L2): a real key whose span exceeds the old
// 32 KiB bound and cannot be clipped; four-dash END banners in the fallback.

func TestLogTail_LargeKeyBeyond32KiBIsRemovedWhole(t *testing.T) {
	body := syntheticPEMBodyBytes(t, 71, 200*48) // RSA-16384-sized: 200 lines of 64
	probe := body[len(body)-3]
	t.Run("RSA-16384 with a 105-char per-line prefix", func(t *testing.T) {
		prefix := "2026-09-30T12:00:00.000000Z builder[module-forge] stage=3 step=sign worker=7 attempt=2 line=" + strings.Repeat("x", 15) + " "
		if len(prefix) < 105 {
			t.Fatalf("fixture: prefix is %d chars, want >= 105", len(prefix))
		}
		var in strings.Builder
		in.WriteString(prefix + "-----BEGIN RSA PRIVATE KEY-----\n")
		for _, l := range body {
			in.WriteString(prefix + l + "\n")
		}
		in.WriteString(prefix + "-----END RSA PRIVATE KEY-----\n" + prefix + "signed\n")
		if in.Len() <= 32<<10 {
			t.Fatalf("fixture: %d bytes does not exceed 32 KiB", in.Len())
		}
		out := string(removeKeyBlocks([]byte(in.String())))
		if strings.Contains(out, probe) || strings.Contains(out, "-----END") {
			t.Fatalf("a real key beyond 32 KiB leaked whole (%d bytes)", in.Len())
		}
		if want := prefix + wantKeyBlockMarker + "\n" + prefix + "signed\n"; out != want {
			t.Fatalf("got:\n%.300s", out)
		}
	})
	t.Run("PGP private key block over 32 KiB with an armor header", func(t *testing.T) {
		big := syntheticPEMBodyBytes(t, 72, 640*48) // ~41 KB of body
		in := "export:\n-----BEGIN PGP PRIVATE KEY BLOCK-----\nComment: exported\n\n" + strings.Join(big, "\n") + "\n=abcd\n-----END PGP PRIVATE KEY BLOCK-----\ndone\n"
		if len(in) <= 32<<10 {
			t.Fatalf("fixture: %d bytes does not exceed 32 KiB", len(in))
		}
		out := string(removeKeyBlocks([]byte(in)))
		if strings.Contains(out, big[len(big)-3]) || strings.Contains(out, "-----END") {
			t.Fatalf("a PGP block beyond 32 KiB leaked whole")
		}
		if want := "export:\n" + wantKeyBlockMarker + "\ndone\n"; out != want {
			t.Fatalf("got:\n%.300s", out)
		}
	})
}

func TestLogTail_FourDashBannersInACutWindowAreUntouched(t *testing.T) {
	for _, first := range []string{
		"ated\n---- END OF BUILD LOG ----\n",
		"---- END 2 ----\n",
	} {
		t.Run(strings.Fields(first)[0], func(t *testing.T) {
			var window strings.Builder
			window.WriteString(first + "summary\n")
			for window.Len() < logTailMaxBytes {
				window.WriteString("npm WARN deprecated foo@1.2.3: use bar instead\n")
			}
			w := window.String()[:logTailMaxBytes]
			tail := logTail([]byte("cut here "+w), []byte("ok"))
			if want := "stdout: " + strings.TrimSpace(w) + "\nstderr: ok"; tail != want {
				t.Fatalf("a banner was taken for a footer, got:\n%.200s", tail)
			}
		})
	}
}

func TestLogTail_HeadlessSSH2BodyIsStillStrippedThroughItsFooter(t *testing.T) {
	body := syntheticPEMBodyBytes(t, 73, 60*48)
	probe := body[len(body)-3]
	after := filler("npm notice", 25) + `{"ok":true}` + "\n"
	stdout := []byte(strings.Join(body, "\n") + "\n---- END SSH2 ENCRYPTED PRIVATE KEY ----\n" + after)
	requireCutInsideBody(t, stdout, logTailMaxBytes, probe)
	tail := logTail(stdout, []byte("ok"))
	if want := "stdout: " + wantKeyBodyMarker + "\n" + strings.TrimSpace(after) + "\nstderr: ok"; tail != want {
		t.Fatalf("got:\n%.300s", tail)
	}
}

func BenchmarkLogTail_8MiBHeaderLinesNoFooter(b *testing.B) {
	line := "-----BEGIN RSA PRIVATE KEY-----\n"
	stderr := []byte(strings.Repeat(line, (8<<20)/len(line)))
	b.SetBytes(int64(len(stderr)))
	for b.Loop() {
		_ = logTail([]byte(`{"ok":false}`), stderr)
	}
}

func BenchmarkLogTail_8MiBHeaderEvery33KiBOneFarFooter(b *testing.B) {
	var s strings.Builder
	chunk := filler("stage", 760) // ~33 KiB
	for s.Len() < 8<<20 {
		s.WriteString("-----BEGIN RSA PRIVATE KEY-----\n" + chunk)
	}
	s.WriteString("-----END RSA PRIVATE KEY-----\n")
	stderr := []byte(s.String())
	b.SetBytes(int64(len(stderr)))
	for b.Loop() {
		_ = logTail([]byte(`{"ok":false}`), stderr)
	}
}
