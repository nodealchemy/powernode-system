package handlers

import (
	"encoding/base64"
	"fmt"
	"math/rand"
	"strings"
	"testing"
)

// wantKeyBodyMarker is the contract text a stripped run is replaced with.
const wantKeyBodyMarker = "[truncated key material removed]"

// IMP-33ab99763220 — a log_tail window is a byte-bounded cut of a stream. A
// key printed by a build step whose BEGIN header fell before the cut leaves a
// HEADERLESS PEM body at the window's start, which no header-keyed server
// pattern can see. The window must drop that body at the source.

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
		"-----BEGIN RSA PRIVATE KEY-----\n" + strings.Join(body, "\n") + "\n-----END RSA PRIVATE KEY-----\n" +
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
	stderr := []byte(filler("apt", 50) + "-----BEGIN OPENSSH PRIVATE KEY-----\r\n" + strings.Join(body, "\r\n") + "\r\n" + after)
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
	stdout := []byte(filler("npm notice", 20) + "-----BEGIN EC PRIVATE KEY-----\n" + strings.Join(body, "\n") + "\n" + after)
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
	stdout := []byte(filler("npm notice", 5) + "-----BEGIN RSA PRIVATE KEY-----\n" + strings.Join(body, "\n") + "\n")
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

func TestLogTail_CutInsideBeginLineKeepsFragmentAndStripsBody(t *testing.T) {
	// The cut lands in the BEGIN line itself: the window opens on a fragment
	// that is not base64 ("PRIVATE KEY-----"), which is kept, while the body
	// after it is still stripped through the END footer.
	body := syntheticPEMBody(t, 38, 50)
	probe := body[len(body)-3]
	head := "PRIVATE KEY-----\n" + strings.Join(body, "\n") + "\n-----END RSA PRIVATE KEY-----\n"
	rest := filler("npm notice", 40)[:logTailMaxBytes-len(head)]
	stdout := []byte("-----BEGIN RSA " + head + rest)
	if len(stdout)-logTailMaxBytes != len("-----BEGIN RSA ") {
		t.Fatalf("fixture: window must open exactly at the BEGIN line fragment")
	}

	tail := logTail(stdout, []byte("ok"))
	if strings.Contains(tail, probe) {
		t.Fatalf("headerless key body survived the cut:\n%s", tail)
	}
	if want := "stdout: PRIVATE KEY-----\n" + wantKeyBodyMarker + "\n" + strings.TrimSpace(rest) + "\nstderr: ok"; tail != want {
		t.Fatalf("expected the fragment kept and the body stripped, got:\n%.300s", tail)
	}
}
