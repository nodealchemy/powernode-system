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

	// RebasedAgainst names the boot composition this state was last rebased
	// against (runtime.stateRebaseKey: the breadcrumb's boot id + compose
	// time). state.json lives on /persist and outlives every boot, but a boot
	// composes its root from the breadcrumb, not from this file — so entries
	// for modules that boot did not compose can sit here forever, reported as
	// running and proposed for detach every tick. The rebase drops those once
	// per composition; this key is how it knows it already ran.
	//
	// Written ONLY by an enforcing rebase. Every other writer (reconcile
	// passes, AttachOne/DetachOne) carries it through unchanged; a pass that
	// skipped or only reported the rebase never sets it, so the rebase is
	// retried rather than silently marked done.
	RebasedAgainst string `json:"rebased_against,omitempty"`

	// ConfinementReconfirmed (round Y, IMP-caef5c00d63f — N5 from the round-X
	// confirm review) maps moduleID -> the boot composition
	// (runtime.stateRebaseKeyOf: same key shape RebasedAgainst uses — boot
	// id + compose time, not the kernel boot id alone) the live path last
	// forced THAT module's security drop-ins to be RE-APPLIED for,
	// regardless of whether the attach stamp matched.
	//
	// PER-MODULE, not a single global flag (the pre-round-Y
	// ConfinementReconfirmedAgainst this replaces): the recheck loop
	// processes every attached module independently, and a global "all OK"
	// flag meant ONE module's policy-decision error or fail-closed drop-in
	// blocked the composition key from EVER being marked done — so every
	// OTHER, perfectly healthy module got re-forced through the drop-in
	// stage on every single tick for as long as the one bad module stayed
	// bad, not just re-examined once. Keying by module ID means a clean
	// module's own key is set the tick it succeeds and stays set,
	// independent of any other module's fate.
	//
	// The attach stamp compares MANIFEST content, not what is actually on
	// disk — the drop-ins themselves live in the tmpfs upper, rewritten
	// fresh by EVERY boot's own compose step, possibly by an OLDER
	// initramfs agent binary that renders a different (or no) drop-in for
	// the SAME manifest content. A boot whose compose wrote a stale/absent
	// drop-in for an already-stamped module is invisible to the ordinary
	// stamp-diff check: the stamp still matches, so the module never
	// re-enters the reattach loop, and the drop-in stays wrong until the
	// next manifest edit — which may never come.
	//
	// Set for a module on the first live reconcile tick of each NEW
	// composition that module's own drop-in stage resolves cleanly for
	// (whether or not anything actually needed re-applying); carried
	// through unchanged by every other writer, so a tick that could not
	// determine the current composition (root mode not native, no usable
	// boot breadcrumb) never marks any module done and a later tick
	// retries. Old field simply stops being read on upgrade — the first
	// tick after an agent upgrade re-runs the (idempotent) recheck once
	// per module, same as a brand-new composition would.
	ConfinementReconfirmed map[string]string `json:"confinement_reconfirmed,omitempty"`

	// SecurityFailClosedUnits (R6, review round 14) is the LAST PUBLISHED
	// copy of the live reconcile path's own fail-closed set
	// (Reconciler.SecurityFailClosedUnits — see that method's own doc for
	// what "fail closed" means here). Written every time
	// publishSecurityFailClosed runs, purely so NewReconciler can seed the
	// in-memory atomic from it on startup: without this, an agent restart
	// (a real one, or this process simply exiting and a fresh one starting)
	// makes the FIRST heartbeat after that restart report a clean node —
	// SecurityFailClosedUnits() returns nil until the first RunOnce pass
	// actually reaches and re-decides every module — even though a module
	// was refused, unconfined, right up until the restart. A brief false
	// "clean" reading on an ALREADY-refused module is exactly the gap a
	// security-fail-closed sensor must never have.
	SecurityFailClosedUnits []string `json:"security_fail_closed_units,omitempty"`
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
