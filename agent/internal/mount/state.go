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
