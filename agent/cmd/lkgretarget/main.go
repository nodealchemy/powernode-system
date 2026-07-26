// Command lkgretarget surgically repoints ONE module in a frozen boot LKG at a
// new blob digest, reusing the agent's own WriteBootLKG/ValidateBootLKG so the
// checksum is computed exactly as the boot path will verify it.
//
// Why this exists: on a SELF-HOSTED control plane the node is its own platform,
// so ComposeForPivot's pre-pivot fetch can never succeed, every boot is
// from_lkg, and LKGCapturer therefore never promotes a new LKG. The documented
// refresh path ("remove the file so the next app-health-confirmed boot
// recaptures") bricks such a node: with no LKG and no reachable platform there
// is nothing to compose. Repointing the frozen file in place is the only way to
// deliver a module to it.
//
// SAFETY CONTRACT — this edits the file that decides whether the node boots at
// all, on nodes that typically cannot be re-provisioned:
//   - the candidate is written to a TEMP file, validated with the agent's own
//     ValidateBootLKG, and only then renamed over the live LKG. A rejected
//     candidate never touches it;
//   - the original is always copied to a timestamped .bak first;
//   - the new digest's blob must EXIST and its sha256 must MATCH. ValidateBootLKG
//     only stats the blob, but the boot path re-hashes it and treats a mismatch
//     as a cache miss — which on a self-hosted control plane means pulling from a
//     platform that is down pre-pivot, i.e. a brick. A truncated or zero-byte
//     blob (exactly the state a recovering operator is in) must be rejected here;
//   - dry-run performs the identical write+validate against the temp file, so a
//     clean dry-run genuinely predicts a clean apply.
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/runtime"
)

var sha256Re = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "lkgretarget:", err)
		os.Exit(1)
	}
}

func run() error {
	path := flag.String("path", runtime.BootLKGPath, "frozen LKG path")
	match := flag.String("module", "", "substring of the module name to retarget (must match exactly one)")
	digest := flag.String("digest", "", "new sha256:<64-hex> blob digest")
	fsv := flag.String("fsverity", "", "new sha256:<64-hex> fsverity root hash")
	cacheDir := flag.String("cache-dir", "/persist/cache/modules", "module erofs blob cache")
	apply := flag.Bool("apply", false, "write the change (default: dry-run, which still validates)")
	flag.Parse()

	// Input validation FIRST. A forgotten flag must never reach the file: an
	// empty -module matches EVERY module (and the ambiguity check needs >=2
	// matches, so on a single-module LKG it would silently select it), and an
	// empty -digest would drop the key entirely via omitempty.
	if strings.TrimSpace(*match) == "" {
		return fmt.Errorf("-module is required (an empty value matches every module)")
	}
	if !sha256Re.MatchString(*digest) {
		return fmt.Errorf("-digest must be sha256:<64 lowercase hex>, got %q", *digest)
	}
	if !sha256Re.MatchString(*fsv) {
		return fmt.Errorf("-fsverity must be sha256:<64 lowercase hex>, got %q", *fsv)
	}

	lkg, err := runtime.LoadBootLKG(*path)
	if err != nil {
		return fmt.Errorf("load %s: %w", *path, err)
	}

	idx := -1
	for i, m := range lkg.Modules {
		if strings.Contains(m.Name, *match) {
			if idx != -1 {
				return fmt.Errorf("%q matches more than one module (%s, %s)", *match, lkg.Modules[idx].Name, m.Name)
			}
			idx = i
		}
	}
	if idx == -1 {
		return fmt.Errorf("no module matching %q", *match)
	}

	m := &lkg.Modules[idx]
	fmt.Printf("module   : %s (%s)\n", m.Name, m.ID)
	fmt.Printf("digest   : %s -> %s\n", m.Digest, *digest)

	// The blob must be present AND hash to the new digest. ValidateBootLKG only
	// stats it; the boot path re-hashes and cache-misses on a mismatch.
	cachePath := func(d string) string {
		return filepath.Join(*cacheDir, strings.Replace(d, "sha256:", "sha256_", 1)+".erofs")
	}
	if err := verifyBlob(cachePath(*digest), *digest); err != nil {
		return fmt.Errorf("blob check: %w", err)
	}
	fmt.Printf("blob     : %s (sha256 verified)\n", cachePath(*digest))

	if len(m.Manifest) > 0 {
		patched, prev, err := patchManifest(m.Manifest, *digest, *fsv)
		if err != nil {
			return fmt.Errorf("manifest: %w", err)
		}
		fmt.Printf("fsverity : %s -> %s\n", prev, *fsv)
		m.Manifest = patched
	}
	m.Digest = *digest

	// Write the candidate to a TEMP file beside the target and validate THAT.
	// Only a candidate the agent's own validator accepts may become the live LKG.
	// Per-process candidate: a fixed shared name lets two concurrent runs
	// validate their own bytes and then rename the OTHER's under that approval.
	// Both are independently validated so the promoted file is still valid, but
	// the operator would not be looking at what landed.
	tmp := fmt.Sprintf("%s.candidate.%d", *path, os.Getpid())
	defer os.Remove(tmp)
	if err := runtime.WriteBootLKG(tmp, lkg); err != nil {
		return fmt.Errorf("write candidate: %w", err)
	}
	back, err := runtime.LoadBootLKG(tmp)
	if err != nil {
		return fmt.Errorf("reload candidate: %w", err)
	}
	if err := runtime.ValidateBootLKG(back, cachePath); err != nil {
		return fmt.Errorf("candidate REJECTED, live LKG untouched: %w", err)
	}
	fmt.Printf("candidate: VALID (frozen=%v modules=%d checksum=%s…)\n",
		back.Frozen, len(back.Modules), back.Checksum[:16])

	if !*apply {
		fmt.Println("DRY RUN — candidate validated, nothing replaced (pass -apply)")
		return nil
	}

	bak := fmt.Sprintf("%s.bak-%s.%d", *path, time.Now().UTC().Format("20060102T150405Z"), os.Getpid())
	if err := copyFile(*path, bak); err != nil {
		return fmt.Errorf("backup: %w", err)
	}
	fmt.Printf("backup   : %s\n", bak)

	if err := os.Rename(tmp, *path); err != nil {
		return fmt.Errorf("promote candidate (original preserved at %s): %w", bak, err)
	}
	// Durability: the rename is atomic but the DIRECTORY entry is not yet on
	// stable storage. Power loss here silently reverts to the old LKG — valid,
	// so not a brick, but a retarget the operator was told had APPLIED.
	if err := syncDir(filepath.Dir(*path)); err != nil {
		return fmt.Errorf("fsync %s after promote: %w", filepath.Dir(*path), err)
	}
	fmt.Printf("APPLIED  : %s now targets %s\n", *path, *digest)
	return nil
}

// patchManifest rewrites digest + fsverity_root_hash inside the embedded
// manifest. UseNumber keeps integers exact: a plain map[string]any decode routes
// every number through float64 and silently corrupts anything above 2^53 (epoch
// nanoseconds, large IDs) on the round-trip.
func patchManifest(raw json.RawMessage, digest, fsv string) (json.RawMessage, string, error) {
	dec := json.NewDecoder(strings.NewReader(string(raw)))
	dec.UseNumber()
	var man map[string]any
	if err := dec.Decode(&man); err != nil {
		return nil, "", err
	}
	prev, _ := man["fsverity_root_hash"].(string)
	man["digest"] = digest
	man["fsverity_root_hash"] = fsv
	out, err := json.Marshal(man)
	if err != nil {
		return nil, "", err
	}
	return out, prev, nil
}

func verifyBlob(path, digest string) error {
	f, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("%s not in the cache — the boot path would have to pull it from a platform that is down pre-pivot: %w", path, err)
	}
	defer f.Close()
	h := sha256.New()
	n, err := io.Copy(h, f)
	if err != nil {
		return err
	}
	got := "sha256:" + hex.EncodeToString(h.Sum(nil))
	if got != digest {
		return fmt.Errorf("%s hashes to %s, not %s (%d bytes — truncated or partial pull)", path, got, digest, n)
	}
	return nil
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	mode := os.FileMode(0o644)
	if st, serr := in.Stat(); serr == nil {
		mode = st.Mode().Perm()
	}
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	defer out.Close()
	if _, err := io.Copy(out, in); err != nil {
		return err
	}
	if err := out.Sync(); err != nil {
		return err
	}
	return syncDir(filepath.Dir(dst))
}

// syncDir fsyncs a directory so a rename/create in it survives power loss.
func syncDir(dir string) error {
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}
