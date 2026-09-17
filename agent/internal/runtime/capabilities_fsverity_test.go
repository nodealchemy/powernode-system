package runtime

import (
	"os/exec"
	"testing"
)

// IMP-20cd36a71ecf — fs-verity needs the kernel feature AND the fsverity
// binary the verifier shells out to. A kernel-version-only answer reported
// true on nodes where every check fails with "executable file not found".
func TestDetectCapabilitiesFsverityNeedsTheBinary(t *testing.T) {
	cases := []struct {
		name  string
		found bool
		want  bool
	}{
		{"binary present", true, true},
		{"binary absent", false, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newHWFixture(t)
			k := f.kernelProbe()
			var asked string
			k.lookPath = func(name string) (string, error) {
				asked = name
				if tc.found {
					return "/usr/bin/" + name, nil
				}
				return "", &exec.Error{Name: name, Err: exec.ErrNotFound}
			}
			caps := detectCapabilities(k, f.hardwareProbe(fakeRun(nil)))
			if asked != "fsverity" {
				t.Errorf("looked up %q, want fsverity", asked)
			}
			if caps.FsverityAvailable != tc.want {
				t.Errorf("FsverityAvailable = %v, want %v", caps.FsverityAvailable, tc.want)
			}
		})
	}
}

// A new kernel does not rescue a missing binary, and a present binary does
// not rescue an old kernel.
func TestDetectCapabilitiesFsverityNeedsTheKernel(t *testing.T) {
	f := newHWFixture(t)
	k := f.kernelProbe()
	k.procRoot = t.TempDir() // no osrelease: kernel unknown
	k.lookPath = func(name string) (string, error) { return "/usr/bin/" + name, nil }
	if detectCapabilities(k, f.hardwareProbe(fakeRun(nil))).FsverityAvailable {
		t.Error("FsverityAvailable = true with an unknown kernel")
	}

	k = f.kernelProbe()
	k.lookPath = nil // unset seam must fail closed, not panic
	if detectCapabilities(k, f.hardwareProbe(fakeRun(nil))).FsverityAvailable {
		t.Error("FsverityAvailable = true with no binary lookup wired")
	}
}
