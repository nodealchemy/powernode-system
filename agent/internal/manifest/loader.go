package manifest

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/powernode/platform/extensions/system/agent/internal/fsutil"
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

// ──────────────────────────────────────────────────────────────────
// Legacy init_start parsing
// ──────────────────────────────────────────────────────────────────

// singleUnitRE matches a single `systemctl <verb> <unit>` invocation.
// Anything more complex (semicolons, multiple commands, env vars)
// fails to match — callers fall back to declaring units explicitly
// in Manifest.Config["units"].
var singleUnitRE = regexp.MustCompile(`^\s*systemctl\s+(?:start|restart|reload)\s+(\S+)\s*$`)

func parseSingleUnit(initStart string) []string {
	m := singleUnitRE.FindStringSubmatch(initStart)
	if m == nil {
		return nil
	}
	return []string{m[1]}
}
