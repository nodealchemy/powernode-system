package mount

import (
	"path/filepath"
	"sort"
)

// Layout describes the canonical mount-point layout the agent maintains.
// Defaults follow the Golden Eclipse hybrid upper-layer design:
//
//	/sysroot                       — overlay merged view (the running rootfs)
//	/run/powernode/scratch         — single shared tmpfs (parent of upper + work)
//	/run/powernode/scratch/upper   — overlayfs upperdir (ephemeral)
//	/run/powernode/scratch/work    — overlayfs workdir (overlayfs internal)
//	/run/powernode/modules/<digest> — erofs lower per module
//	/persist/var                   — persistent /var (bind-mounted onto /sysroot/var)
//	/persist/cache/modules         — erofs blob cache (digest store)
//
// Upper and work share ONE tmpfs because overlayfs requires
// `upperdir` and `workdir` to be on the same MOUNT (not just the
// same filesystem). Earlier code mounted a separate tmpfs at each
// path; the kernel rejected the overlay with "workdir and upperdir
// must reside under the same mount". Quotas are now applied to the
// shared scratch pool (size=512m) rather than per-path; in practice
// upper is the only thing that grows materially, work just holds
// overlay's internal whiteout state.
type Layout struct {
	Root              string // default: ""
	SysRoot           string // default: "/sysroot"
	ScratchRoot       string // default: "/run/powernode/scratch"
	UpperDir          string // default: "/run/powernode/scratch/upper"
	WorkDir           string // default: "/run/powernode/scratch/work"
	ModulesMountRoot  string // default: "/run/powernode/modules"
	ModulesCacheRoot  string // default: "/persist/cache/modules"
	PersistentVarRoot string // default: "/persist/var"
}

// DefaultLayout returns the production-canonical layout.
func DefaultLayout() Layout {
	return Layout{
		SysRoot:           "/sysroot",
		ScratchRoot:       "/run/powernode/scratch",
		UpperDir:          "/run/powernode/scratch/upper",
		WorkDir:           "/run/powernode/scratch/work",
		ModulesMountRoot:  "/run/powernode/modules",
		ModulesCacheRoot:  "/persist/cache/modules",
		PersistentVarRoot: "/persist/var",
	}
}

// NextrootLayout returns the Layout for composing a soft-reboot target
// union at /run/nextroot (the path systemd-soft-reboot switches into):
// same module mounts + blob cache as the live layout — erofs lowers are
// read-only and safely shared between unions — but its OWN scratch tmpfs,
// because two overlays sharing one upperdir/workdir is undefined kernel
// behavior and the live root's scratch is in use by /.
//
// gen disambiguates repeated soft-recomposes within one kernel boot: each
// prepare gets a fresh scratch (a stale prepared union can be torn down,
// but a scratch that BECAME the live root's upper after a soft-reboot
// cannot), so superseded scratch mounts are left for the next full reboot
// to clear. Empty gen means the bare path.
func NextrootLayout(gen string) Layout {
	l := DefaultLayout()
	l.SysRoot = "/run/nextroot"
	scratch := "/run/powernode/nextroot-scratch"
	if gen != "" {
		scratch += "-" + gen
	}
	l.ScratchRoot = scratch
	l.UpperDir = filepath.Join(scratch, "upper")
	l.WorkDir = filepath.Join(scratch, "work")
	return l
}

// Resolve applies Root to all paths, returning a copy with absolute paths
// rooted under l.Root (used in tests to redirect to a temp dir).
func (l Layout) Resolve() Layout {
	r := l
	r.SysRoot = join(l.Root, l.SysRoot)
	r.ScratchRoot = join(l.Root, l.ScratchRoot)
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

// ModuleCachePath returns the local-cache path of a module's pulled
// erofs blob. The digest alone uniquely identifies the content
// (it's the sha256 of the blob bytes); the `.erofs` extension keeps
// the cache human-inspectable.
func (l Layout) ModuleCachePath(digest string) string {
	return filepath.Join(l.ModulesCacheRoot, sanitizeDigest(digest)+".erofs")
}

// DigestStorePath returns the shared content-addressed store directory
// (one per node, all modules share). erofs's mount option points at
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
	// FsverityRoot is the fs-verity MERKLE ROOT of the erofs blob, which is a
	// different hash from Digest: Digest is the sha256 of the blob bytes as
	// stored in the registry, while this is the root of the Merkle tree the
	// kernel builds over the file. Comparing one against the other never
	// matches. Carried here because the verifier needs it at mount time and the
	// manifest is not in scope there. Empty when the platform published no
	// fs-verity root for this version.
	FsverityRoot string
	// CosignBundleB64 is the platform's `cosign sign-blob` bundle over the
	// erofs blob, base64, carried from the manifest for the same reason
	// FsverityRoot is: the verifier needs it at mount time. The puller
	// materialises it beside the blob. Empty when the platform published no
	// blob signature for this version.
	CosignBundleB64 string
	// Units names the systemd unit names (lifecycle.UnitName(ID, service))
	// this attached entry's manifest declared at the time it was attached
	// (round 9, in-place upgrade). Persisted in state.json alongside the
	// rest of the entry so a LATER upgrade of this same module ID can
	// compute exactly which units are leaving (Units minus the new
	// manifest's own UnitNames()) without needing the OLD manifest's full
	// content — round 7's digest-keyed attached-snapshot store (deleted in
	// round 9, its symbols no longer exist in this codebase) existed only
	// to answer this same question, at a heavier cost (a full manifest
	// round-trip through disk) for what is really just a name list. Empty
	// (omitted from state.json) for an entry attached by a pre-round-9
	// agent build; upgradeModule resolves and PERSISTS the fallback onto
	// this field the first time it needs to (M7, review round 9), rather
	// than re-deriving it from a manifest cache on every attempt.
	Units []string `json:"Units,omitempty"`
	// PendingDigest (M9, review round 9) names the digest an in-place
	// upgrade of THIS entry is currently mid-way toward, while Digest above
	// still names the old, still-running one. Set by upgradeModule right
	// before step 4 starts restarting units — persisted and saved to disk
	// IMMEDIATELY, before any restart, so a partial multi-unit restart (one
	// unit lands on the new binary, a LATER one in the same module fails)
	// is never invisible: without this, state.json and the heartbeat both
	// still claimed Digest alone, which by then describes neither unit's
	// actual running binary. Cleared (empty, omitted) once the upgrade
	// commits (Digest itself becomes the new value) or the module is
	// otherwise replaced/removed. See buildHeartbeat's own
	// PendingModuleDigests for how this surfaces to the platform.
	PendingDigest string `json:"PendingDigest,omitempty"`
	// PendingDigestAttempts (N2, review round 11) counts how many times
	// upgradeModule has actually attempted THIS SPECIFIC PendingDigest
	// (reached the point of issuing step 4's restart), success or failure.
	// Reset to 0 whenever PendingDigest changes — a re-target to a
	// different digest, or a revert back to Digest itself — since the count
	// describes attempts against one specific target only. Read by the
	// per-digest backoff at the top of upgradeModule so a binary that
	// crashes on every restart is not force-restarted every single
	// reconcile tick forever.
	PendingDigestAttempts int `json:"PendingDigestAttempts,omitempty"`
	// PendingDigestLastAttemptUnix (N2, review round 11) is the unix-seconds
	// timestamp of the attempt PendingDigestAttempts above counts most
	// recently — the backoff clock's reference point. Unix seconds (not
	// time.Time) to keep state.json's encoding for this struct uniform with
	// its other plain scalar fields.
	PendingDigestLastAttemptUnix int64 `json:"PendingDigestLastAttemptUnix,omitempty"`
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
