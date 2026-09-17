package verify

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// IMP-20cd36a71ecf — FsVerifier shells out to `fsverity`, so the fs-verity arm
// can only ever measure until the node images ship that binary. It runs at two
// places: post-pivot (service loop, CLI) out of the base-os userland, and
// pre-pivot (SiteBoot, the direct_kernel boot composer) out of the initramfs.
// Both images must carry it.

func repoFile(t *testing.T, parts ...string) string {
	t.Helper()
	p := filepath.Join(append([]string{"..", "..", ".."}, parts...)...)
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("read %s: %v", p, err)
	}
	return string(b)
}

// topLevelList returns the "  - item" entries of a top-level YAML list key,
// ignoring comments. The manifests keep package_spec a flat string list.
func topLevelList(doc, key string) []string {
	var out []string
	in := false
	for _, line := range strings.Split(doc, "\n") {
		if strings.HasPrefix(line, key+":") {
			in = true
			continue
		}
		if !in {
			continue
		}
		if line != "" && line[0] != ' ' && line[0] != '#' {
			break
		}
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "- ") {
			out = append(out, strings.Trim(strings.TrimSpace(trimmed[2:]), `"'`))
		}
	}
	return out
}

func TestBaseOSShipsFsverityBinary(t *testing.T) {
	manifest := repoFile(t, "modules", "base-os-ubuntu-noble", "manifest.yaml")
	pkgs := topLevelList(manifest, "package_spec")
	if len(pkgs) < 5 {
		t.Fatalf("parsed only %d package_spec entries (%v) — parser or manifest shape changed", len(pkgs), pkgs)
	}
	for _, p := range pkgs {
		if p == "fsverity" {
			return
		}
	}
	t.Errorf("base-os-ubuntu-noble package_spec does not list fsverity (the Ubuntu package that ships /usr/bin/fsverity); got %v", pkgs)
}

func TestInitramfsShipsFsverityBinary(t *testing.T) {
	setup := repoFile(t, "initramfs", "modules.d", "90powernode", "module-setup.sh")
	// Required, not `inst_multiple -o`: an optional install lets an initramfs
	// ship without the binary and the boot composer report "not found" again.
	if !regexp.MustCompile(`(?m)^\s*inst_multiple\s+fsverity\s*$`).MatchString(setup) {
		t.Errorf("initramfs module-setup.sh does not install fsverity with a required inst_multiple")
	}

	// dracut runs inside the disk-image build containers, and a missing binary
	// is only a dracut warning there. Each container must install fsverity
	// and name it in its fail-loud tool check.
	wf := repoFile(t, ".gitea", "workflows", "build-disk-image.yaml")
	checks := regexp.MustCompile(`(?m)^\s*for t in ([^;]*); do command -v "\$t"`).FindAllStringSubmatch(wf, -1)
	if len(checks) < 2 {
		t.Fatalf("found %d initramfs tool checks in build-disk-image.yaml, want the amd64 and arm64 ones", len(checks))
	}
	for i, c := range checks {
		if !regexp.MustCompile(`\bfsverity\b`).MatchString(c[1]) {
			t.Errorf("initramfs tool check #%d (%q) does not require fsverity", i+1, c[1])
		}
	}
	// Each container apt install runs just before its tool check.
	installs := regexp.MustCompile(`(?s)apt-get install -y --no-install-recommends \\\n(.*?)\n\s*for t in`).FindAllStringSubmatch(wf, -1)
	if len(installs) != len(checks) {
		t.Fatalf("found %d container apt installs for %d tool checks", len(installs), len(checks))
	}
	for i, in := range installs {
		if !strings.Contains(in[1], "dracut-core") {
			t.Fatalf("container apt install #%d does not install dracut-core — pattern matched the wrong block", i+1)
		}
		if !regexp.MustCompile(`\bfsverity\b`).MatchString(in[1]) {
			t.Errorf("container apt install #%d does not install fsverity", i+1)
		}
	}
}
