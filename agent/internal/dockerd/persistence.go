package dockerd

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// DefaultStatePath is where Manager persists its state cache. Lives
// under /persist so it survives reboots; agent restarts load this
// file at NewManager time so reconciler state isn't lost on every
// agent restart.
const DefaultStatePath = "/persist/var/lib/powernode/dockerd_state.json"

// persistedState mirrors managedState (the in-memory cache) but with
// JSON-serializable types. ReadyReportedFor was already a string;
// StoppedReportedAt converts to ISO8601 for stable round-tripping.
//
// Schema version bumped to 2 in slice 10 to add LastConfigHash; the
// loader ignores prior-version files and treats them as cold-boot
// state, which is correct since hash detection should NOT trigger a
// restart on first observation post-upgrade.
type persistedState struct {
	ReadyReportedFor   string    `json:"ready_reported_for,omitempty"`
	StoppedReportedAt  time.Time `json:"stopped_reported_at,omitempty"`
	LastConfigHash     string    `json:"last_config_hash,omitempty"`
	WrittenAt          time.Time `json:"written_at"`
	SchemaVersion      int       `json:"schema_version"`
}

const stateSchemaVersion = 2

// loadState reads the state file at path and applies it to the Manager's
// in-memory cache. Silent on missing file (first boot) — returns
// without error. Logs + ignores corrupted file (operator can wipe).
func (m *Manager) loadState() {
	if m.StatePath == "" {
		return
	}
	body, err := os.ReadFile(m.StatePath)
	if err != nil {
		// Missing file is the first-boot common case; don't log.
		// Permission errors are real but the reconciler still works
		// without persistence (just suboptimal); record + continue.
		if !os.IsNotExist(err) {
			m.recordError("load_state", fmt.Errorf("read state file: %w", err))
		}
		return
	}
	var ps persistedState
	if err := json.Unmarshal(body, &ps); err != nil {
		// Corrupted file. Don't crash; treat as cold boot and let
		// the next persist overwrite.
		m.recordError("load_state", fmt.Errorf("decode state: %w", err))
		return
	}
	if ps.SchemaVersion != stateSchemaVersion {
		// Schema mismatch — silently ignore; future migrations slot
		// in here. Cold boot is harmless.
		return
	}
	m.state.readyReportedFor = ps.ReadyReportedFor
	m.state.stoppedReportedAt = ps.StoppedReportedAt
	m.state.lastConfigHash = ps.LastConfigHash
}

// persistState writes the in-memory cache to disk. Called after every
// transition that mutates state. Best-effort — errors recorded but
// don't block the reconciler. Atomic write via .tmp + rename so a
// concurrent crash never leaves a half-written file.
func (m *Manager) persistState() {
	if m.StatePath == "" {
		return
	}
	ps := persistedState{
		ReadyReportedFor:  m.state.readyReportedFor,
		StoppedReportedAt: m.state.stoppedReportedAt,
		LastConfigHash:    m.state.lastConfigHash,
		WrittenAt:         time.Now().UTC(),
		SchemaVersion:     stateSchemaVersion,
	}
	body, err := json.Marshal(ps)
	if err != nil {
		m.recordError("persist_state", fmt.Errorf("marshal state: %w", err))
		return
	}
	dir := filepath.Dir(m.StatePath)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		m.recordError("persist_state", fmt.Errorf("mkdir %s: %w", dir, err))
		return
	}
	tmp, err := os.CreateTemp(dir, ".dockerd-state-*")
	if err != nil {
		m.recordError("persist_state", fmt.Errorf("create temp: %w", err))
		return
	}
	cleanup := func() { _ = os.Remove(tmp.Name()) }
	if _, err := tmp.Write(body); err != nil {
		_ = tmp.Close()
		cleanup()
		m.recordError("persist_state", err)
		return
	}
	if err := tmp.Close(); err != nil {
		cleanup()
		m.recordError("persist_state", err)
		return
	}
	if err := os.Rename(tmp.Name(), m.StatePath); err != nil {
		cleanup()
		m.recordError("persist_state", err)
	}
}
