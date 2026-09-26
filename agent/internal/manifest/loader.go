package manifest

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/fsutil"
)

// DefaultRoot is the canonical on-disk location for cached manifests.
// Lives under /persist so it survives reboots — reconcile + CLI work
// air-gapped after a successful FetchAndCache.
const DefaultRoot = "/persist/var/lib/powernode/modules"

// Client is the minimal subset of *transport.Client the loader needs.
// Defined as an interface so tests can stub without a httptest server.
type Client interface {
	GetJSON(path string) (*http.Response, error)
}

// FetchAndCache pulls the manifest from the platform and writes it
// to the on-disk cache. Returns the parsed Manifest. The caller is
// responsible for creating the parent dir if needed (the helper does
// MkdirAll for the per-module subdir but assumes Root exists).
func FetchAndCache(c Client, root, moduleID string) (*Manifest, error) {
	if c == nil {
		return nil, errors.New("manifest.FetchAndCache: nil client")
	}
	if moduleID == "" {
		return nil, errors.New("manifest.FetchAndCache: empty moduleID")
	}
	resp, err := c.GetJSON(fmt.Sprintf("/api/v1/system/node_api/modules/%s", moduleID))
	if err != nil {
		return nil, fmt.Errorf("get module %s: %w", moduleID, err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20)) // 1 MiB ceiling
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("manifest %s status %d: %s", moduleID, resp.StatusCode, strings.TrimSpace(string(body)))
	}

	var env struct {
		Success bool      `json:"success"`
		Data    *Manifest `json:"data"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, fmt.Errorf("decode manifest: %w", err)
	}
	if env.Data == nil {
		return nil, fmt.Errorf("manifest %s: empty data envelope", moduleID)
	}

	// IMP-2dfbd7f62441 review finding R2-N1: the on-disk cache is a
	// FALLBACK OF LAST RESORT for later ticks (agent/internal/runtime's
	// RunOnce falls back to it when a later fetch fails) — its contract is
	// "last KNOWN GOOD", not "last fetched". A response with no digest is a
	// live-but-degraded view (see the caller-side comment on the no-digest
	// branch in RunOnce for why this is reachable for a genuinely assigned
	// module, not only an unpublished one): if a PREVIOUSLY cached manifest
	// for this module had a real digest, writing this digest-less one over
	// it would destroy the only usable fallback a later failed fetch could
	// have used, for no benefit — nothing reads "the cache" as "what the
	// platform said most recently", only as "the last manifest we know was
	// usable". The in-memory return value is NOT touched: the caller still
	// sees THIS tick's real (degraded) response and reacts accordingly; only
	// the on-disk file is protected.
	if env.Data.Digest == "" {
		if existing, lerr := LoadFromDisk(root, moduleID); lerr == nil && existing != nil && existing.Digest != "" {
			return env.Data, nil
		}
	}

	if err := writeCache(root, env.Data); err != nil {
		// Cache failures don't fail the fetch — caller still gets
		// the in-memory manifest. Surface as warning via the
		// returned error... actually the design is silent on this.
		// Return nil for the cache write error so the manifest is
		// usable; the caller can re-call FetchAndCache later if
		// they specifically need a cached copy.
		return env.Data, fmt.Errorf("manifest fetched but cache write failed: %w", err)
	}
	return env.Data, nil
}

// LoadFromDisk reads the cached manifest for moduleID. Returns
// os.ErrNotExist when no cache exists.
func LoadFromDisk(root, moduleID string) (*Manifest, error) {
	path := manifestPath(root, moduleID)
	body, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var m Manifest
	if err := json.Unmarshal(body, &m); err != nil {
		return nil, fmt.Errorf("decode cached manifest %s: %w", path, err)
	}
	return &m, nil
}

// LoadOrFetch tries disk first. Falls back to platform when:
//   - Disk read fails with os.ErrNotExist (no cache)
//   - staleAfter > 0 AND cache file mtime is older than staleAfter
//
// Pass staleAfter=0 to disable staleness check (always prefer disk
// when present). Pass a small staleAfter (e.g. 5*time.Minute) for the
// reconcile loop; pass time.Duration(math.MaxInt64) for offline-
// preferring CLI commands.
func LoadOrFetch(c Client, root, moduleID string, staleAfter time.Duration) (*Manifest, error) {
	path := manifestPath(root, moduleID)
	st, err := os.Stat(path)
	if err == nil {
		if staleAfter == 0 || time.Since(st.ModTime()) < staleAfter {
			if m, lerr := LoadFromDisk(root, moduleID); lerr == nil {
				return m, nil
			}
			// Fall through to FetchAndCache on decode error — the
			// cache file is corrupt; refresh it.
		}
	} else if !os.IsNotExist(err) {
		return nil, fmt.Errorf("stat %s: %w", path, err)
	}
	return FetchAndCache(c, root, moduleID)
}

// writeCache persists m as JSON. Caller's `root` typically defaults
// to DefaultRoot.
func writeCache(root string, m *Manifest) error {
	if m == nil || m.ID == "" {
		return errors.New("manifest.writeCache: nil or empty ID")
	}
	dir := filepath.Join(root, m.ID)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("mkdir %s: %w", dir, err)
	}
	path := filepath.Join(dir, "manifest.json")
	return fsutil.AtomicWriteJSON(path, m, 0o644)
}

func manifestPath(root, moduleID string) string {
	return filepath.Join(root, moduleID, "manifest.json")
}

// SaveAttachedSnapshot persists m, keyed by (moduleID, digest) rather than
// moduleID alone (L1, review round 7, CRITICAL). The plain manifest.json
// cache (writeCache/manifestPath above) is keyed by module ID ONLY and is
// overwritten on every fetch REGARDLESS of whether that fetch's digest ever
// successfully attached — its contract is "last fetched", not "last
// attached". A version-bump rollback (agent/internal/runtime's
// rollbackVersionBumpDetach) needs "the manifest content that was actually
// used the last time THIS EXACT DIGEST attached successfully", which a
// fetch that happens in between (even one whose own attach then fails) can
// silently clobber if the two are conflated — see rollbackVersionBumpDetach's
// own doc comment for the exact multi-tick sequence this caused (a rollback
// re-attaching the OLD digest using the NEW manifest's content, which then
// fails Apply/Validate identically and drops the module from state.json
// entirely).
//
// The caller (attachModule, on a fully successful attach only) is the sole
// writer. Best-effort: a write failure here must never fail the attach it
// is recording — the caller logs it via OnError and the module still comes
// up; only a LATER rollback attempt is degraded (falls back to the
// mutable per-ID cache, same limitation this store exists to remove).
func SaveAttachedSnapshot(root, moduleID, digest string, m *Manifest) error {
	if m == nil {
		return errors.New("manifest.SaveAttachedSnapshot: nil manifest")
	}
	if moduleID == "" || digest == "" {
		return fmt.Errorf("manifest.SaveAttachedSnapshot: empty moduleID/digest (moduleID=%q digest=%q)", moduleID, digest)
	}
	dir := filepath.Join(root, moduleID, "attached")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("mkdir %s: %w", dir, err)
	}
	return fsutil.AtomicWriteJSON(attachedSnapshotPath(root, moduleID, digest), m, 0o644)
}

// LoadAttachedSnapshot reads back what SaveAttachedSnapshot wrote for the
// exact (moduleID, digest) pair. Returns os.ErrNotExist (wrapped, so
// os.IsNotExist still matches) when no snapshot was ever recorded for this
// digest — expected for a module attached by an agent build that predates
// this store, or one that has never yet attached successfully at all; the
// caller falls back to its own next-best source in that case.
func LoadAttachedSnapshot(root, moduleID, digest string) (*Manifest, error) {
	path := attachedSnapshotPath(root, moduleID, digest)
	body, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var m Manifest
	if err := json.Unmarshal(body, &m); err != nil {
		return nil, fmt.Errorf("decode attached-snapshot manifest %s: %w", path, err)
	}
	return &m, nil
}

func attachedSnapshotPath(root, moduleID, digest string) string {
	return filepath.Join(root, moduleID, "attached", sanitizeDigestForFilename(digest)+".json")
}

// sanitizeDigestForFilename substitutes characters that are unsafe (or just
// awkward when unquoted) in a filesystem path component. Digests are
// typically "sha256:abc...": the colon is legal on Linux but is replaced
// here anyway for consistency with the same substitution the oci/mount
// packages already apply to digest-derived filenames elsewhere in this
// codebase (oci.sanitizeDigest / mount.Layout's identically-named
// function) — this is a SEPARATE, independent copy (this package imports
// neither), not required to match theirs byte-for-byte, since it only
// needs to be a stable, collision-free key into ITS OWN store.
func sanitizeDigestForFilename(d string) string {
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
