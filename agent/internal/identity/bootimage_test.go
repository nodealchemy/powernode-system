package identity

import (
	"os"
	"path/filepath"
	"testing"
)

func writeTemp(t *testing.T, dir, name, content string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", name, err)
	}
	return p
}

func TestBootedImageGitSHA_ReadsCmdline(t *testing.T) {
	dir := t.TempDir()
	cmdline := writeTemp(t, dir, "cmdline",
		"console=ttyS0,115200 powernode.boot=1 powernode.image_git_sha=abc123 ip=dhcp\n")

	if got := bootedImageGitSHA(cmdline); got != "abc123" {
		t.Fatalf("want abc123 from cmdline, got %q", got)
	}
}

func TestBootedImageGitSHA_EmptyWhenCmdlineLacksParam(t *testing.T) {
	dir := t.TempDir()
	// Netboot / pre-campaign / rpi4 cmdline: no powernode.image_git_sha.
	// Must be empty ("unknown"), NOT fall back to any on-disk file — a
	// promotion-unbound sha would manufacture false drift.
	cmdline := writeTemp(t, dir, "cmdline", "console=ttyS0,115200 powernode.boot=1 ip=dhcp\n")
	if got := bootedImageGitSHA(cmdline); got != "" {
		t.Fatalf("want empty when cmdline lacks the param, got %q", got)
	}
}

func TestBootedImageGitSHA_EmptyWhenCmdlineMissing(t *testing.T) {
	dir := t.TempDir()
	if got := bootedImageGitSHA(filepath.Join(dir, "nope")); got != "" {
		t.Fatalf("want empty when cmdline file missing, got %q", got)
	}
}

func TestBootedImageGitSHA_EmptyValue(t *testing.T) {
	dir := t.TempDir()
	// An explicitly empty value is still "unknown".
	cmdline := writeTemp(t, dir, "cmdline", "powernode.image_git_sha= powernode.boot=1\n")
	if got := bootedImageGitSHA(cmdline); got != "" {
		t.Fatalf("want empty for empty param value, got %q", got)
	}
}
