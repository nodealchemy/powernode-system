package runtime

// Boot last-known-good (LKG) fallback — Level 1 boot-independence (#39).
//
// Problem: ComposeForPivot (the initramfs pre-pivot compose) live-fetches the
// module assignment from the platform with NO fallback (see compose.go). If the
// controlling plane is unreachable at boot — e.g. after it is decommissioned —
// the fetch fails and the node cannot compose a root: it bricks.
//
// Level 1 closes this with a durable, FROZEN "last-known-good" boot composition
// on /persist. ComposeForPivot falls back to it when the live fetch fails, so a
// node survives the loss of its controlling plane by cold-booting the last
// composition that was PROVEN to boot healthy.
//
// Two artifacts, deliberately separate (this separation is load-bearing — it is
// how the design guarantees the LKG is only ever a proven-cold-boots set):
//
//   - BootComposedBreadcrumb (boot-composed.json): the EXACT module set
//     ComposeForPivot composed for the CURRENT boot, written pre-pivot by
//     ComposeForPivot itself. It records what actually booted — never a set the
//     post-boot reconcile loop later hot-reconciles to.
//
//   - BootLKG (assignment-lkg.json): the frozen last-known-good. It is promoted
//     from the breadcrumb ONLY after the COMPOSED control plane passes an
//     application-level health check (see lkg_capture.go). Because promotion
//     reads the breadcrumb (what booted) and not the live/hot-reconciled state,
//     and only fires after the composed app is confirmed serving, the LKG is
//     always a composition that has actually cold-booted AND served — closing
//     the "hot-mount != code-active" poison (a hot-mounted new module version
//     whose code only runs after a future reboot could otherwise be certified
//     against the still-running OLD code and brick the next cold boot).
//
// The LKG is self-contained: each module carries its resolved digest AND the
// manifest bytes at that digest, so a fallback compose never depends on the
// mutable per-module-id manifest cache (which the reconcile loop refreshes on a
// TTL and can drift to a newer digest whose blob isn't cached). Erofs blobs come
// from the digest-keyed, immutable-per-digest cache and are validated present
// before compose.

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/fsutil"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// Paths for the boot-LKG artifacts + kill-switch sentinel. Vars (not consts) so
// tests can redirect them to a temp dir. All under /persist so they survive a
// reboot AND are readable by ComposeForPivot in the initramfs (where /persist is
// already mounted before compose runs).
var (
	// BootLKGPath is the frozen last-known-good boot composition.
	BootLKGPath = "/persist/var/lib/powernode/assignment-lkg.json"
	// BootBreadcrumbPath records the set THIS boot composed (written pre-pivot).
	BootBreadcrumbPath = "/persist/var/lib/powernode/boot-composed.json"
	// LKGDisableSentinel, when present, disables the fallback READ at boot
	// (reverts to today's live-only behavior). The fallback ships DEFAULT-ON;
	// this sentinel (or the powernode.lkg=off kernel cmdline) DISABLES it.
	LKGDisableSentinel = "/persist/var/lib/powernode/lkg-fallback.disabled"
	// procCmdlinePath is /proc/cmdline; a var for test override.
	procCmdlinePath = "/proc/cmdline"
)

const (
	// bootLKGSchemaVersion is the on-disk schema version. Bumped only on a
	// breaking format change; ComposeForPivot rejects an unknown version rather
	// than misinterpret an incompatible file.
	bootLKGSchemaVersion = 1

	// DefaultLKGStalenessThreshold is the compile-time default staleness bound,
	// used when neither the LKG-recorded threshold (backend-delivered, from a
	// SiteSetting) nor the powernode.lkg_max_age kernel-cmdline override is set.
	// Staleness is advisory: a stale boot ALERTS but never blocks (a stale boot
	// beats a brick).
	DefaultLKGStalenessThreshold = 7 * 24 * time.Hour
)

// LKGModule is one module of a boot composition snapshot: the resolved
// {id, digest, effective_priority} PLUS the manifest bytes at that digest, so a
// fallback compose is fully self-contained and independent of the mutable
// per-id manifest cache. Manifest is empty for config/skill modules
// (has_data_file=false) — they contribute no blob to mount, exactly as the live
// compose path skips them.
type LKGModule struct {
	ID                string          `json:"id"`
	Name              string          `json:"name,omitempty"`
	EffectivePriority int             `json:"effective_priority"`
	HasDataFile       bool            `json:"has_data_file"`
	Variety           string          `json:"variety,omitempty"`
	Digest            string          `json:"digest,omitempty"`
	Manifest          json.RawMessage `json:"manifest,omitempty"`
}

// BootComposedBreadcrumb records the exact module set ComposeForPivot composed
// for the CURRENT boot, written pre-pivot. The post-boot capturer promotes THIS
// (never the live/hot-reconciled set) to the frozen LKG after an app-health
// confirm — the mechanism that keeps the LKG a proven-cold-boots composition.
type BootComposedBreadcrumb struct {
	SchemaVersion             int          `json:"schema_version"`
	ComposedAt                time.Time    `json:"composed_at"`
	FromLKG                   bool         `json:"from_lkg"`
	LKGConfirmedAt            time.Time    `json:"lkg_confirmed_at,omitempty"`
	Source                    string       `json:"source,omitempty"`
	NodeID                    string       `json:"node_id,omitempty"`
	Hostname                  string       `json:"hostname,omitempty"`
	StalenessThresholdSeconds int64        `json:"staleness_threshold_seconds,omitempty"`
	AppHealth                 AppHealthCfg `json:"app_health,omitempty"`
	// Incomplete is set when at least one assigned data module was dropped at
	// compose (manifest unresolved / no digest) — the node still booted on the
	// remaining modules, but the composed set is NOT the complete assignment.
	// The capturer refuses to freeze an incomplete set as last-known-good, so the
	// LKG is only ever a COMPLETE proven composition.
	Incomplete bool `json:"incomplete,omitempty"`
	// FromPending marks a boot that composed from a STAGED, not-yet-proven set
	// (see pending_compose.go). Unlike FromLKG, such a boot is exactly what the
	// capturer must promote once health-gated — that promotion is the only way a
	// self-hosted control plane's frozen LKG can ever advance.
	FromPending bool `json:"from_pending,omitempty"`
	// BootID is the kernel's boot_id at compose time. The capturer refuses a
	// breadcrumb from a different boot: the breadcrumb write is best-effort, so a
	// failed write leaves the PREVIOUS boot's file on disk — and once FromPending
	// can authorise overwriting a proven LKG, a stale one could promote a set that
	// already failed. Cheap to stamp, and it hardens the FromLKG/Incomplete reads
	// as well.
	BootID  string      `json:"boot_id,omitempty"`
	Modules []LKGModule `json:"modules"`
}

// AppHealthCfg is the SiteSetting-delivered promotion-gate config, carried on
// the boot envelope → breadcrumb → LKG so the gate can be reconfigured (e.g.
// strengthened from /up to a composed-API check, or a longer confirm window)
// centrally, with NO new agent binary. Zero values mean "use the agent's
// compile-time defaults".
type AppHealthCfg struct {
	URL                 string `json:"url,omitempty"`
	RequiredConsecutive int    `json:"required_consecutive,omitempty"`
	PollIntervalSeconds int    `json:"poll_interval_seconds,omitempty"`
}

// BootLKG is the durable, frozen last-known-good boot composition. Frozen is
// always true once written; the capturer never overwrites a frozen file.
// Re-provisioning (to capture a newer desired composition before a
// decommission) is a deliberate operator action that removes this file so the
// next app-health-confirmed boot recaptures.
type BootLKG struct {
	SchemaVersion             int          `json:"schema_version"`
	Frozen                    bool         `json:"frozen"`
	ConfirmedAt               time.Time    `json:"confirmed_at"`
	Source                    string       `json:"source,omitempty"`
	NodeID                    string       `json:"node_id,omitempty"`
	Hostname                  string       `json:"hostname,omitempty"`
	StalenessThresholdSeconds int64        `json:"staleness_threshold_seconds,omitempty"`
	AppHealth                 AppHealthCfg `json:"app_health,omitempty"`
	Modules                   []LKGModule  `json:"modules"`
	// Checksum is sha256(canonical-JSON(Modules)) — detects truncation /
	// corruption / tampering before a fallback trusts the snapshot.
	Checksum string `json:"checksum"`
}

// checksumModules returns sha256 hex over the canonical JSON of the module
// slice. json.Marshal is deterministic for a struct slice (declared field
// order, RawMessage passed through verbatim), so the same modules always hash
// identically.
func checksumModules(mods []LKGModule) (string, error) {
	b, err := json.Marshal(mods)
	if err != nil {
		return "", fmt.Errorf("checksum marshal: %w", err)
	}
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:]), nil
}

// WriteBootLKG stamps the schema version + checksum and atomically writes the
// frozen LKG. Always sets Frozen=true — a written LKG is by definition the
// frozen last-known-good.
func WriteBootLKG(path string, lkg *BootLKG) error {
	if lkg == nil {
		return errors.New("WriteBootLKG: nil lkg")
	}
	if len(lkg.Modules) == 0 {
		return errors.New("WriteBootLKG: refusing to write an empty module set")
	}
	lkg.SchemaVersion = bootLKGSchemaVersion
	lkg.Frozen = true
	sum, err := checksumModules(lkg.Modules)
	if err != nil {
		return err
	}
	lkg.Checksum = sum
	// Ensure the survival dir exists — AtomicWriteJSON does NOT mkdir, and this
	// write must not silently no-op on a first boot where nothing else has
	// created /persist/var/lib/powernode yet (mirrors mount.SaveState).
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("mkdir %s: %w", filepath.Dir(path), err)
	}
	return fsutil.AtomicWriteJSON(path, lkg, 0o644)
}

// LoadBootLKG reads + decodes the LKG. Returns os.ErrNotExist (wrapped) when
// absent so callers can branch on errors.Is(err, os.ErrNotExist).
func LoadBootLKG(path string) (*BootLKG, error) {
	body, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var lkg BootLKG
	if err := json.Unmarshal(body, &lkg); err != nil {
		return nil, fmt.Errorf("decode boot-lkg %s: %w", path, err)
	}
	return &lkg, nil
}

// ValidateBootLKG fail-loud-checks a loaded LKG before it is trusted for a
// fallback compose: schema match, non-empty, checksum integrity, and for every
// data-bearing module a non-empty digest + embedded manifest + present erofs
// blob. cachePath maps a digest to its on-disk erofs path (production:
// mount.Layout.ModuleCachePath). A nil/failed check means the fallback must NOT
// compose from this snapshot — better to fail the boot loudly (operator +
// ZFS-belt recovery) than compose a half-broken root.
func ValidateBootLKG(lkg *BootLKG, cachePath func(digest string) string) error {
	if lkg == nil {
		return errors.New("boot-lkg: nil")
	}
	if lkg.SchemaVersion != bootLKGSchemaVersion {
		return fmt.Errorf("boot-lkg: schema %d != supported %d", lkg.SchemaVersion, bootLKGSchemaVersion)
	}
	if len(lkg.Modules) == 0 {
		return errors.New("boot-lkg: empty module set")
	}
	sum, err := checksumModules(lkg.Modules)
	if err != nil {
		return err
	}
	if sum != lkg.Checksum {
		return fmt.Errorf("boot-lkg: checksum mismatch (have %s want %s) — corrupt or truncated", lkg.Checksum, sum)
	}
	mountable := 0
	for _, m := range lkg.Modules {
		if !m.HasDataFile {
			continue // config/skill modules mount nothing — same as the live path
		}
		mountable++
		if m.Digest == "" {
			return fmt.Errorf("boot-lkg: module %s has_data_file but no digest", m.ID)
		}
		if len(m.Manifest) == 0 {
			return fmt.Errorf("boot-lkg: module %s missing embedded manifest", m.ID)
		}
		if cachePath != nil {
			blob := cachePath(m.Digest)
			if _, err := os.Stat(blob); err != nil {
				return fmt.Errorf("boot-lkg: module %s blob absent at %s: %w", m.ID, blob, err)
			}
		}
	}
	if mountable == 0 {
		return errors.New("boot-lkg: no mountable (has_data_file) modules — cannot compose a root")
	}
	return nil
}

// ToComposeInputs converts an LKG into the (desired stack, manifests) pair the
// compose path consumes — identical shape to the live path's resolution, so the
// downstream mount/union/identity/unit logic is fully shared. Only data-bearing
// modules become mount entries; each manifest is unmarshalled from the embedded
// bytes (NOT the mutable per-id cache), pinning the compose to the LKG digest.
func (lkg *BootLKG) ToComposeInputs() (mount.ModuleStack, map[string]*manifest.Manifest, error) {
	desired := make(mount.ModuleStack, 0, len(lkg.Modules))
	manifests := make(map[string]*manifest.Manifest, len(lkg.Modules))
	for _, m := range lkg.Modules {
		if !m.HasDataFile {
			continue
		}
		var mf manifest.Manifest
		if err := json.Unmarshal(m.Manifest, &mf); err != nil {
			return nil, nil, fmt.Errorf("boot-lkg: decode manifest for %s: %w", m.ID, err)
		}
		desired = append(desired, mount.Module{ID: m.ID, Digest: m.Digest, Priority: m.EffectivePriority})
		manifests[m.ID] = &mf
	}
	if len(desired) == 0 {
		return nil, nil, errors.New("boot-lkg: no mountable modules")
	}
	return desired, manifests, nil
}

// WriteBreadcrumb atomically records what THIS boot composed. Best-effort in
// callers: a failed breadcrumb write must not abort a boot (the node still
// runs; it just can't self-provision an LKG this boot).
// CurrentBootID reads the kernel's per-boot random id. Empty when unavailable
// (non-Linux, or /proc not mounted yet) — callers treat empty as "unknown" and
// fall back to the pre-existing behaviour rather than refusing to work.
func CurrentBootID() string {
	b, err := os.ReadFile("/proc/sys/kernel/random/boot_id")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

func WriteBreadcrumb(path string, bc *BootComposedBreadcrumb) error {
	if bc == nil {
		return errors.New("WriteBreadcrumb: nil breadcrumb")
	}
	bc.SchemaVersion = bootLKGSchemaVersion
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("mkdir %s: %w", filepath.Dir(path), err)
	}
	return fsutil.AtomicWriteJSON(path, bc, 0o644)
}

// LoadBreadcrumb reads the current boot's breadcrumb.
func LoadBreadcrumb(path string) (*BootComposedBreadcrumb, error) {
	body, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var bc BootComposedBreadcrumb
	if err := json.Unmarshal(body, &bc); err != nil {
		return nil, fmt.Errorf("decode breadcrumb %s: %w", path, err)
	}
	return &bc, nil
}

// LKGFallbackDisabled reports whether the boot-LKG fallback READ is disabled —
// either the /persist sentinel exists (normal durable toggle) or the kernel
// cmdline carries powernode.lkg=off (one-boot console override for when /persist
// itself is suspect). The fallback ships DEFAULT-ENABLED; both mechanisms only
// DISABLE it (reverting to today's live-fetch-only boot).
func LKGFallbackDisabled(sentinelPath string) bool {
	if sentinelPath != "" {
		if _, err := os.Stat(sentinelPath); err == nil {
			return true
		}
	}
	return cmdlineHasFlag("powernode.lkg", "off")
}

// stalenessThreshold resolves the staleness bound with precedence:
// kernel-cmdline (powernode.lkg_max_age=<seconds>) > recorded (seconds) >
// compile-time default. Config-driven; never a bare hardcode at the use site.
func stalenessThreshold(recordedSeconds int64) time.Duration {
	if v, ok := cmdlineFlagValue("powernode.lkg_max_age"); ok {
		if secs, err := parsePositiveInt(v); err == nil && secs > 0 {
			return time.Duration(secs) * time.Second
		}
	}
	if recordedSeconds > 0 {
		return time.Duration(recordedSeconds) * time.Second
	}
	return DefaultLKGStalenessThreshold
}

// cmdlineHasFlag reports whether /proc/cmdline contains key=val.
func cmdlineHasFlag(key, val string) bool {
	if v, ok := cmdlineFlagValue(key); ok {
		return v == val
	}
	return false
}

// cmdlineFlagValue returns the value of a key=value token in /proc/cmdline.
func cmdlineFlagValue(key string) (string, bool) {
	body, err := os.ReadFile(procCmdlinePath)
	if err != nil {
		return "", false
	}
	for _, tok := range strings.Fields(string(body)) {
		if k, v, ok := strings.Cut(tok, "="); ok && k == key {
			return v, true
		}
	}
	return "", false
}

func parsePositiveInt(s string) (int64, error) {
	var n int64
	if _, err := fmt.Sscanf(s, "%d", &n); err != nil {
		return 0, err
	}
	return n, nil
}
