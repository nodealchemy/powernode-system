//go:build linux

package mount

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/sys/unix"
)

func TestKernelAtLeast(t *testing.T) {
	cases := []struct {
		release string
		want    bool
	}{
		{"6.8.0-136-generic", true},
		{"6.5.0", true},
		{"6.4.16-arch1", false},
		{"5.15.0-91-generic", false},
		{"7.0.0", true},
		{"6.5-rc1", true},
		{"garbage", false},
		{"6", false},
	}
	for _, c := range cases {
		if got := kernelAtLeast(c.release, 6, 5); got != c.want {
			t.Errorf("kernelAtLeast(%q, 6, 5) = %v, want %v", c.release, got, c.want)
		}
	}
}

func TestComposeOverlayFD_Validation(t *testing.T) {
	if _, err := ComposeOverlayFD(nil, "", ""); err == nil {
		t.Error("empty lower stack must be rejected before any syscall")
	}
	if _, err := ComposeOverlayFD([]string{"/a"}, "/up", ""); err == nil {
		t.Error("upperDir without workDir must be rejected")
	}
	if _, err := ComposeOverlayFD([]string{"/a"}, "", "/work"); err == nil {
		t.Error("workDir without upperDir must be rejected")
	}
}

// The real thing: compose two read-only unions and atomically swap the
// mount at a target, verifying both halves of the contract —
//   - new lookups see the new union immediately after the swap;
//   - a file HELD OPEN across the swap keeps serving the old content
//     (the lazily-detached old union stays alive for existing refs).
//
// Needs root + kernel >= 6.5; skipped otherwise (CI runs it in the
// privileged integration lane, `sudo go test -run TestSwapBeneath`).
func TestSwapBeneath_Integration(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("requires root (mount syscalls)")
	}
	if !KernelSupportsMoveMountBeneath() {
		t.Skip("requires kernel >= 6.5 (MOVE_MOUNT_BENEATH)")
	}

	// Upper-less overlay needs >= 2 lowers, so each union is
	// (generation layer, shared base).
	base := t.TempDir()
	genA := t.TempDir()
	genB := t.TempDir()
	target := t.TempDir()
	writeBeneathFile(t, base, "base.txt", "base")
	writeBeneathFile(t, genA, "who", "A")
	writeBeneathFile(t, genB, "who", "B")

	fdA, err := ComposeOverlayFD([]string{genA, base}, "", "")
	if err != nil {
		// euid 0 is NOT the same as holding CAP_SYS_ADMIN. Inside an
		// unprivileged container the process is root and the kernel is new
		// enough, so both guards above pass — but the capability was dropped,
		// and fsopen("overlay") returns EPERM. That is exactly what happens on
		// the go-agent CI job (ghcr.io/catthehacker/ubuntu:act-24.04), where
		// this was the ONLY failing package while every sibling passed:
		//   beneath_test.go:75: compose union A: fsopen overlay: operation not permitted
		// It held the whole go-agent gate red, which trains readers to ignore
		// that job — so a real agent regression would land unseen.
		//
		// Skip ONLY on the permission errors, never on error generally: a
		// blanket skip would silently swallow a genuine overlay regression and
		// recreate the same blindness one layer down.
		if errors.Is(err, unix.EPERM) || errors.Is(err, unix.EACCES) {
			t.Skipf("requires CAP_SYS_ADMIN for fsopen(overlay), which euid 0 alone does not grant "+
				"(unprivileged container?): %v", err)
		}
		t.Fatalf("compose union A: %v", err)
	}
	defer unix.Close(fdA)
	// Plain attach of the first union (no beneath — nothing there yet).
	if err := unix.MoveMount(fdA, "", unix.AT_FDCWD, target, unix.MOVE_MOUNT_F_EMPTY_PATH); err != nil {
		t.Fatalf("attach union A at %s: %v", target, err)
	}
	defer unix.Unmount(target, unix.MNT_DETACH)

	if got := readBeneathFile(t, filepath.Join(target, "who")); got != "A" {
		t.Fatalf("pre-swap union serves %q, want A", got)
	}

	// Hold a file open across the swap.
	held, err := os.Open(filepath.Join(target, "who"))
	if err != nil {
		t.Fatalf("open held file: %v", err)
	}
	defer held.Close()

	fdB, err := ComposeOverlayFD([]string{genB, base}, "", "")
	if err != nil {
		t.Fatalf("compose union B: %v", err)
	}
	defer unix.Close(fdB)
	if err := SwapBeneath(fdB, target); err != nil {
		t.Fatalf("SwapBeneath: %v", err)
	}

	if got := readBeneathFile(t, filepath.Join(target, "who")); got != "B" {
		t.Errorf("post-swap lookup serves %q, want B — the swap did not land", got)
	}
	if got := readBeneathFile(t, filepath.Join(target, "base.txt")); got != "base" {
		t.Errorf("shared lower content %q, want base — the new union lost a layer", got)
	}
	heldBytes, err := io.ReadAll(held)
	if err != nil {
		t.Fatalf("read held-open file: %v", err)
	}
	if string(heldBytes) != "A" {
		t.Errorf("held-open file reads %q, want A — old refs must keep the old union until released", heldBytes)
	}
}

func writeBeneathFile(t *testing.T, dir, rel, content string) {
	t.Helper()
	p := filepath.Join(dir, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatalf("mkdir for %s: %v", rel, err)
	}
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", rel, err)
	}
}

func readBeneathFile(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("read %s: %v", p, err)
	}
	return string(b)
}
