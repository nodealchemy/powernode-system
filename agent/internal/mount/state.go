package mount

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// StatePath is where the agent persists its current attach/detach state.
// Lives under /persist/var so it survives reboots.
const StatePath = "/persist/var/lib/powernode/state.json"

// State is the JSON-serialized snapshot of the agent's current view of
// what's mounted. Read at boot to reconcile against platform-supplied
// assignments; written after each successful attach/detach.
type State struct {
	BootID            string    `json:"boot_id"`
	AgentVersion      string    `json:"agent_version"`
	LastUpdated       time.Time `json:"last_updated"`
	UnionMounted      bool      `json:"union_mounted"`
	PersistentVarBind bool      `json:"persistent_var_bind"`
	AttachedModules   []Module  `json:"attached_modules"`

	// LastAttachedManifestHashes records, per module-id, the SHA256 of
	// the manifest's services block at the time of the last successful
	// AttachServices call. The reconciler reads this on every cycle to
	// detect manifest-only changes (no digest change) and re-runs
	// AttachServices when the hash drifts. Without this, a manifest
	// edit that adds a new service or changes a start_command is never
	// picked up by the agent — the module is already in Reconcile()'s
	// toKeep set, so attachModule never re-fires. Discovered 2026-05-25
	// via qemu-guest-agent dogfood: services row populated post-publish
	// (after a delayed migration) but no unit file ever generated.
	LastAttachedManifestHashes map[string]string `json:"last_attached_manifest_hashes,omitempty"`

	// UnmaterializedModules names the module IDs that are MOUNTED — they are
	// in AttachedModules, their erofs layer really is attached — but whose
	// file content was never copied onto the live root, because the
	// hot-materialization was refused (today: the scratch budget guard, see
	// runtime.ErrScratchBudget). On a pivot node the running files come from
	// the live root, so such a module is running the PREVIOUS version's files
	// no matter what digest AttachedModules records.
	//
	// It exists to keep the heartbeat honest. buildHeartbeat reported every
	// AttachedModules digest as `module_digests` (the platform's
	// running_module_digests), so a refused materialization read as a
	// successful deploy — ops-hub 2026-09-04, where hub-backend v92/v93 were
	// reported running while the node served v91's files. Modules listed here
	// are omitted from that report instead.
	//
	// Recomputed from scratch by every reconcile pass that reaches the state
	// write, so it always describes the pass that just ran: a module converges
	// off the list simply by materializing on a later tick.
	//
	// Read it INTERSECTED with AttachedModules, never on its own. An entry is
	// a statement about an attachment, and the single-module CLI paths
	// (AttachOne/DetachOne) are not reconcile passes — they can leave an id
	// here whose module is no longer attached, until the next pass rewrites
	// the field.
	UnmaterializedModules []string `json:"unmaterialized_modules,omitempty"`
}

// LoadState reads State from `path`. Returns a zero-value State and
// nil error when the file doesn't exist (first boot).
func LoadState(path string) (*State, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return &State{}, nil
		}
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	var s State
	if err := json.Unmarshal(data, &s); err != nil {
		return nil, fmt.Errorf("decode %s: %w", path, err)
	}
	return &s, nil
}

// SaveState writes State atomically to `path`.
func SaveState(path string, s *State) error {
	if s == nil {
		return errors.New("SaveState: nil state")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("mkdir %s: %w", filepath.Dir(path), err)
	}
	s.LastUpdated = time.Now().UTC()
	body, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal state: %w", err)
	}

	tmp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".tmp.*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if _, err := tmp.Write(body); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, path)
}

// Reconcile computes the diff between desired (from platform) and current
// (from disk State). Returns lists of modules to attach and detach.
func Reconcile(current *State, desired ModuleStack) (toAttach, toDetach ModuleStack) {
	have := map[string]Module{}
	if current != nil {
		for _, m := range current.AttachedModules {
			have[m.Digest] = m
		}
	}
	want := map[string]Module{}
	for _, m := range desired {
		want[m.Digest] = m
	}
	for d, m := range want {
		if _, ok := have[d]; !ok {
			toAttach = append(toAttach, m)
		}
	}
	for d, m := range have {
		if _, ok := want[d]; !ok {
			toDetach = append(toDetach, m)
		}
	}
	return toAttach, toDetach
}
