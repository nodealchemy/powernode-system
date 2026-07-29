package runtime

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// This file closes the deletion half of the hot-reconcile contract.
//
// SyncModuleFilesToRoot (hotreconcile.go) copies a changed module's files
// onto the live root so a new version applies without a reboot. Its v1
// contract explicitly excluded REMOVALS: a file the old version shipped and
// the new one dropped survived until a reboot recomposed the union from
// scratch. That made "recompose live unless reboot_required" true only for
// updates that add or modify, which is a materially weaker guarantee than it
// sounds — a dropped /etc/profile.d entry, for instance, keeps editing PATH
// for every login shell on the node until someone reboots it.
//
// WHY THE OBVIOUS IMPLEMENTATION IS WRONG. The tempting shape (the one the
// original TODO assumed) is "diff the old and new erofs trees". It cannot
// work here: RunOnce's detach loop unmounts the superseded layer BEFORE the
// attach loop runs, so by the time hotReconcileIfNeeded fires there is no
// old tree left to walk. The old version's path set must therefore be
// captured while it is still mounted and carried forward — see
// captureOutgoingPaths in reconcile.go.
//
// WHY A NAIVE UNLINK IS WORSE THAN THE GAP. The live root is an overlayfs
// merged view. Removing a path through that view does not "undo" the module;
// it creates a WHITEOUT in the upperdir that hides the path across every
// lower layer at once. If any other module in the stack also ships that path
// — which is the normal case for shared prefixes like /usr/bin — the unlink
// silently deletes a file the union should still be serving, and the damage
// only becomes visible after the next reboot recomposes without the
// whiteout. So every candidate is first re-resolved against the surviving
// layers, in the same highest-priority-first order overlayfs itself uses
// (mount.LowerDirString). A path another layer provides is REWRITTEN from
// that layer, never unlinked. Only a path no surviving layer provides is
// removed, and there the whiteout is exactly the desired effect: it is what
// hides a stale copy that lives in a read-only lower and cannot be deleted
// directly.

// TreePaths is the path inventory of one mounted module tree, rooted at "/"
// (so entries are directly comparable across layers and against the live
// root).
//
// The split matters. Files is the set of PRUNABLE entries — regular files
// and symlinks. All additionally carries directories, and is what a
// candidate is tested against: if the new version ships /usr/bin/tool as a
// directory where the old shipped a file, that is a refactor, not a removal,
// and pruning it would delete content the new version depends on.
type TreePaths struct {
	All   map[string]bool
	Files map[string]bool
}

// ModuleTreePaths walks a mounted module erofs tree and inventories it.
//
// A missing directory degrades to an empty inventory rather than an error:
// callers reach this with a mount path that may legitimately have gone away
// (a layer unmounted between the capture and the walk), and an empty
// inventory produces exactly the right downstream behaviour — nothing is
// considered removed, nothing is pruned. Failing loudly there would turn a
// benign race into a reconcile error every tick.
//
// Only the walk is done here; no file contents are read and nothing is
// hashed, so this stays cheap even on a large runtime tree.
func ModuleTreePaths(erofsDir string) (TreePaths, error) {
	tp := TreePaths{All: map[string]bool{}, Files: map[string]bool{}}
	if erofsDir == "" {
		return tp, nil
	}
	if _, err := os.Stat(erofsDir); err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return tp, nil
		}
		return tp, fmt.Errorf("stat module tree %s: %w", erofsDir, err)
	}

	var problems []error
	err := filepath.WalkDir(erofsDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			problems = append(problems, err)
			// Skip the unreadable subtree but keep inventorying siblings.
			if d != nil && d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		rel, rerr := filepath.Rel(erofsDir, path)
		if rerr != nil {
			problems = append(problems, rerr)
			return nil
		}
		if rel == "." {
			// The tree root is not an entry the module "ships".
			return nil
		}
		abs := "/" + filepath.ToSlash(rel)
		tp.All[abs] = true
		if !d.IsDir() {
			tp.Files[abs] = true
		}
		return nil
	})
	if err != nil {
		problems = append(problems, err)
	}
	return tp, errors.Join(problems...)
}

// PruneOptions describes one module's removal reconciliation. Every input is
// explicit — nothing is read from global or mount state — so the decision
// logic is exercisable without a composed root.
type PruneOptions struct {
	// OldPaths is the set of root-rooted paths (files and symlinks) the
	// OUTGOING module version shipped, captured while its tree was still
	// mounted.
	OldPaths map[string]bool

	// NewErofsDir is the incoming version's mounted tree. Anything it
	// provides — at any entry kind — is not a removal.
	NewErofsDir string

	// DstRoot is the live root to reconcile ("/" in production).
	DstRoot string

	// SurvivingLayers are the other mounted module trees, HIGHEST priority
	// FIRST, matching overlayfs lower order. A candidate any of these
	// provides is rewritten from the first one that has it, not removed.
	SurvivingLayers []string

	// Protected is the module's protected_spec: paths it declares it does
	// not own outright. They are never removed and never rewritten.
	Protected []string
}

// PruneResult counts what happened, for the caller's logging.
//
// Removed is deliberately separate from Restored: on a healthy node the
// steady state is all-zero, a version bump that drops files shows Removed>0
// exactly once, and a persistently non-zero Restored means two modules are
// fighting over the same path — a composition smell worth surfacing rather
// than averaging into one number.
type PruneResult struct {
	Removed  int // no surviving layer provided it; taken off the live root
	Restored int // another layer still provides it; rewritten from that layer
	Kept     int // protected, absent, a directory, or already correct
}

// PruneRemovedFiles reconciles the paths an outgoing module version shipped
// that the incoming one does not.
//
// Per-candidate failures are collected and joined rather than aborting, so
// one stuck entry cannot block the rest — the same contract
// SyncModuleFilesToRoot follows. Candidates are processed in sorted order so
// behaviour does not depend on Go's randomized map iteration.
func PruneRemovedFiles(opts PruneOptions) (PruneResult, error) {
	var res PruneResult
	if len(opts.OldPaths) == 0 {
		return res, nil
	}

	newTree, err := ModuleTreePaths(opts.NewErofsDir)
	// A walk error still yields a partial inventory. Treating a partially
	// read new tree as authoritative would let a transient read failure be
	// interpreted as "the new version dropped these files" and delete them,
	// so bail out instead: skipping this tick is always recoverable, an
	// erroneous prune is not.
	if err != nil {
		return res, fmt.Errorf("inventory new module tree: %w", err)
	}

	dstRoot := filepath.Clean(opts.DstRoot)
	candidates := make([]string, 0, len(opts.OldPaths))
	for p := range opts.OldPaths {
		if newTree.All[p] {
			continue // still provided by the incoming version
		}
		candidates = append(candidates, p)
	}
	sort.Strings(candidates)

	var problems []error
	for _, rel := range candidates {
		if matchesAnySpec(rel, opts.Protected) {
			res.Kept++
			continue
		}
		dst, ok := resolveUnder(dstRoot, rel)
		if !ok {
			// A path that escapes the destination root is never acted on.
			// Nothing in the pipeline should produce one; if something
			// does, refusing is the only safe response.
			problems = append(problems, fmt.Errorf("refusing path outside root: %q", rel))
			res.Kept++
			continue
		}

		info, err := os.Lstat(dst)
		if err != nil {
			if errors.Is(err, fs.ErrNotExist) {
				// Already gone — the steady state after the first prune.
				res.Kept++
				continue
			}
			problems = append(problems, fmt.Errorf("lstat %s: %w", dst, err))
			continue
		}
		if info.IsDir() {
			// Directories are never removed. An empty one left behind is
			// harmless; removing one that is not empty would take unrelated
			// content with it.
			res.Kept++
			continue
		}

		// Re-resolve against the surviving stack BEFORE considering removal.
		if src, srcInfo, found := findInLayers(opts.SurvivingLayers, rel); found {
			changed, err := restoreFrom(src, dst, srcInfo)
			switch {
			case err != nil:
				problems = append(problems, fmt.Errorf("restore %s from %s: %w", dst, src, err))
			case changed:
				res.Restored++
			default:
				res.Kept++
			}
			continue
		}

		if err := os.Remove(dst); err != nil {
			problems = append(problems, fmt.Errorf("remove %s: %w", dst, err))
			continue
		}
		res.Removed++
	}
	return res, errors.Join(problems...)
}

// findInLayers returns the first layer that provides rel, honouring the
// caller's highest-priority-first ordering. A layer that provides rel as a
// DIRECTORY counts as providing it: the correct response there is to leave
// the destination alone, which restoreFrom handles by reporting no change.
func findInLayers(layers []string, rel string) (string, os.FileInfo, bool) {
	for _, layer := range layers {
		src, ok := resolveUnder(filepath.Clean(layer), rel)
		if !ok {
			continue
		}
		info, err := os.Lstat(src)
		if err != nil {
			continue
		}
		return src, info, true
	}
	return "", nil, false
}

// restoreFrom rewrites dst from a surviving layer's copy, reusing the same
// atomic-write and verbatim-symlink helpers SyncModuleFilesToRoot uses so
// restore and sync cannot drift apart in their guarantees.
func restoreFrom(src, dst string, info os.FileInfo) (bool, error) {
	switch {
	case info.Mode()&os.ModeSymlink != 0:
		return syncSymlink(src, dst)
	case info.Mode().IsRegular():
		return syncRegularFile(src, dst, info.Mode().Perm())
	default:
		// A directory (or device/FIFO/socket) in the surviving layer where
		// the live root has a file: out of scope for a prune pass, and
		// silently rewriting across entry kinds is how data gets lost.
		return false, nil
	}
}

// resolveUnder joins a root-rooted path onto root and confirms the result
// stays inside it. Returns ok=false for any path that would escape.
func resolveUnder(root, rel string) (string, bool) {
	full := filepath.Clean(filepath.Join(root, rel))
	if root == string(filepath.Separator) {
		// Everything is under "/" by construction.
		return full, true
	}
	if full == root {
		return "", false
	}
	if !strings.HasPrefix(full, root+string(filepath.Separator)) {
		return "", false
	}
	return full, true
}

// matchesAnySpec reports whether path matches any of the manifest-style
// specs (file_spec / protected_spec / mask share this syntax).
//
// The syntax is segment-wise: "*" matches within one path segment, "**"
// matches one or more whole segments. "/usr/local/**" therefore covers
// everything UNDER /usr/local but not /usr/local itself, which is what the
// manifests mean by it — a module declaring "/usr/local/**" is claiming the
// contents, not the mount point. filepath.Match alone cannot express this
// ("*" there also matches "/"), which is why this exists.
func matchesAnySpec(path string, specs []string) bool {
	if len(specs) == 0 {
		return false
	}
	segs := splitSpecPath(path)
	for _, spec := range specs {
		if spec == "" {
			continue
		}
		if matchSegments(splitSpecPath(spec), segs) {
			return true
		}
	}
	return false
}

func splitSpecPath(p string) []string {
	p = strings.Trim(filepath.ToSlash(p), "/")
	if p == "" {
		return nil
	}
	return strings.Split(p, "/")
}

func matchSegments(pat, seg []string) bool {
	if len(pat) == 0 {
		return len(seg) == 0
	}
	if pat[0] == "**" {
		// One or more segments — see matchesAnySpec's doc on why zero would
		// be wrong for the "/usr/local/**" idiom.
		for i := 1; i <= len(seg); i++ {
			if matchSegments(pat[1:], seg[i:]) {
				return true
			}
		}
		return false
	}
	if len(seg) == 0 {
		return false
	}
	ok, err := filepath.Match(pat[0], seg[0])
	if err != nil || !ok {
		return false
	}
	return matchSegments(pat[1:], seg[1:])
}
