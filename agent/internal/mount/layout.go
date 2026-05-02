package mount

import (
	"path/filepath"
	"sort"
)

// Layout describes the canonical mount-point layout the agent maintains.
// Defaults follow the Golden Eclipse hybrid upper-layer design:
//
//	/sysroot              — overlay merged view (the running rootfs)
//	/run/powernode/upper  — tmpfs upperdir (ephemeral)
//	/run/powernode/work   — tmpfs workdir (overlayfs internal)
//	/run/powernode/modules/<digest>  — composefs lower per module
//	/persist/var          — persistent /var (bind-mounted onto /sysroot/var)
//	/persist/cache/modules — composefs blob cache (digest store)
type Layout struct {
	Root              string // default: ""
	SysRoot           string // default: "/sysroot"
	UpperDir          string // default: "/run/powernode/upper"
	WorkDir           string // default: "/run/powernode/work"
	ModulesMountRoot  string // default: "/run/powernode/modules"
	ModulesCacheRoot  string // default: "/persist/cache/modules"
	PersistentVarRoot string // default: "/persist/var"
}

// DefaultLayout returns the production-canonical layout.
func DefaultLayout() Layout {
	return Layout{
		SysRoot:           "/sysroot",
		UpperDir:          "/run/powernode/upper",
		WorkDir:           "/run/powernode/work",
		ModulesMountRoot:  "/run/powernode/modules",
		ModulesCacheRoot:  "/persist/cache/modules",
		PersistentVarRoot: "/persist/var",
	}
}

// Resolve applies Root to all paths, returning a copy with absolute paths
// rooted under l.Root (used in tests to redirect to a temp dir).
func (l Layout) Resolve() Layout {
	r := l
	r.SysRoot = join(l.Root, l.SysRoot)
	r.UpperDir = join(l.Root, l.UpperDir)
	r.WorkDir = join(l.Root, l.WorkDir)
	r.ModulesMountRoot = join(l.Root, l.ModulesMountRoot)
	r.ModulesCacheRoot = join(l.Root, l.ModulesCacheRoot)
	r.PersistentVarRoot = join(l.Root, l.PersistentVarRoot)
	return r
}

func join(root, p string) string {
	if root == "" {
		return p
	}
	return filepath.Join(root, p)
}

// ModuleMountPath returns the per-module mount point for a given digest.
func (l Layout) ModuleMountPath(digest string) string {
	return filepath.Join(l.ModulesMountRoot, sanitizeDigest(digest))
}

// ModuleCachePath returns the local-cache path of a module's composefs
// metadata file (the .cfs blob).
func (l Layout) ModuleCachePath(digest string) string {
	return filepath.Join(l.ModulesCacheRoot, sanitizeDigest(digest)+".cfs")
}

// DigestStorePath returns the shared content-addressed store directory
// (one per node, all modules share). composefs's mount option points at
// this dir for the actual file contents.
func (l Layout) DigestStorePath() string {
	return filepath.Join(l.ModulesCacheRoot, ".store")
}

// sanitizeDigest replaces characters that are unsafe in filesystem paths.
// OCI digests are typically "sha256:abc...", which is fine on Linux but
// the colon trips up some tools when passed unquoted; use "_" for safety.
func sanitizeDigest(d string) string {
	out := make([]byte, 0, len(d))
	for _, c := range []byte(d) {
		switch {
		case c == ':' || c == '/' || c == ' ':
			out = append(out, '_')
		default:
			out = append(out, c)
		}
	}
	return string(out)
}

// ModuleStack is the ordered list of modules to compose into an overlay
// lower stack. Lower index = lower priority (mounted first; gets shadowed
// by higher entries). The platform's effective_priority drives the order.
type ModuleStack []Module

// Module describes one entry in the lower stack.
type Module struct {
	ID       string // platform NodeModule.id
	Digest   string // OCI digest, "sha256:..."
	Priority int    // effective_priority (higher = closer to merged top)
}

// SortByPriority sorts the stack ascending by priority. Pass the result
// to overlay.LowerDirString to get the colon-separated lowerdir arg.
func (s ModuleStack) SortByPriority() ModuleStack {
	out := append(ModuleStack(nil), s...)
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Priority != out[j].Priority {
			return out[i].Priority < out[j].Priority
		}
		return out[i].ID < out[j].ID
	})
	return out
}
