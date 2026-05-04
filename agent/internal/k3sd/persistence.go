package k3sd

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// DefaultServerStatePath + DefaultAgentStatePath are where the Server
// + Agent managers persist their state caches. Lives under /persist
// so it survives reboots; agent restarts load these at NewManager
// time so reconciler state (especially `bootstrappedFor` for the
// Server and `joinedClusterID` for the Agent) isn't lost on every
// agent restart — which would otherwise re-trigger expensive
// bootstrap/join_request calls.
const (
	DefaultServerStatePath = "/persist/var/lib/powernode/k3sd_server_state.json"
	DefaultAgentStatePath  = "/persist/var/lib/powernode/k3sd_agent_state.json"
)

const stateSchemaVersion = 1

// ──────────────────────────────────────────────────────────────────
// ServerManager state persistence
// ──────────────────────────────────────────────────────────────────

type serverPersistedState struct {
	BootstrappedFor   string    `json:"bootstrapped_for,omitempty"`
	ReadyReportedFor  string    `json:"ready_reported_for,omitempty"`
	StoppedReportedAt time.Time `json:"stopped_reported_at,omitempty"`
	WrittenAt         time.Time `json:"written_at"`
	SchemaVersion     int       `json:"schema_version"`
}

func (m *ServerManager) loadState() {
	if m.StatePath == "" {
		return
	}
	body, err := os.ReadFile(m.StatePath)
	if err != nil {
		if !os.IsNotExist(err) {
			m.recordError("load_state", fmt.Errorf("read state file: %w", err))
		}
		return
	}
	var ps serverPersistedState
	if err := json.Unmarshal(body, &ps); err != nil {
		m.recordError("load_state", fmt.Errorf("decode state: %w", err))
		return
	}
	if ps.SchemaVersion != stateSchemaVersion {
		return
	}
	m.state.bootstrappedFor = ps.BootstrappedFor
	m.state.readyReportedFor = ps.ReadyReportedFor
	m.state.stoppedReportedAt = ps.StoppedReportedAt
}

func (m *ServerManager) persistState() {
	if m.StatePath == "" {
		return
	}
	ps := serverPersistedState{
		BootstrappedFor:   m.state.bootstrappedFor,
		ReadyReportedFor:  m.state.readyReportedFor,
		StoppedReportedAt: m.state.stoppedReportedAt,
		WrittenAt:         time.Now().UTC(),
		SchemaVersion:     stateSchemaVersion,
	}
	if err := atomicWriteJSON(m.StatePath, ps); err != nil {
		m.recordError("persist_state", err)
	}
}

// ──────────────────────────────────────────────────────────────────
// AgentManager state persistence
// ──────────────────────────────────────────────────────────────────

type agentPersistedState struct {
	JoinedClusterID   string    `json:"joined_cluster_id,omitempty"`
	ReadyReportedFor  string    `json:"ready_reported_for,omitempty"`
	StoppedReportedAt time.Time `json:"stopped_reported_at,omitempty"`
	WrittenAt         time.Time `json:"written_at"`
	SchemaVersion     int       `json:"schema_version"`
}

func (m *AgentManager) loadState() {
	if m.StatePath == "" {
		return
	}
	body, err := os.ReadFile(m.StatePath)
	if err != nil {
		if !os.IsNotExist(err) {
			m.recordError("load_state", fmt.Errorf("read state file: %w", err))
		}
		return
	}
	var ps agentPersistedState
	if err := json.Unmarshal(body, &ps); err != nil {
		m.recordError("load_state", fmt.Errorf("decode state: %w", err))
		return
	}
	if ps.SchemaVersion != stateSchemaVersion {
		return
	}
	m.state.joinedClusterID = ps.JoinedClusterID
	m.state.readyReportedFor = ps.ReadyReportedFor
	m.state.stoppedReportedAt = ps.StoppedReportedAt
}

func (m *AgentManager) persistState() {
	if m.StatePath == "" {
		return
	}
	ps := agentPersistedState{
		JoinedClusterID:   m.state.joinedClusterID,
		ReadyReportedFor:  m.state.readyReportedFor,
		StoppedReportedAt: m.state.stoppedReportedAt,
		WrittenAt:         time.Now().UTC(),
		SchemaVersion:     stateSchemaVersion,
	}
	if err := atomicWriteJSON(m.StatePath, ps); err != nil {
		m.recordError("persist_state", err)
	}
}

// ──────────────────────────────────────────────────────────────────
// Shared atomic JSON write helper
// ──────────────────────────────────────────────────────────────────

// atomicWriteJSON writes the marshaled value to path via .tmp +
// rename. Same atomicity guarantees as agent's other state files
// (cert files, daemon.json) — readers either see the old contents
// or the new, never half-written.
func atomicWriteJSON(path string, v any) error {
	body, err := json.Marshal(v)
	if err != nil {
		return fmt.Errorf("marshal: %w", err)
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("mkdir %s: %w", dir, err)
	}
	tmp, err := os.CreateTemp(dir, ".k3sd-state-*")
	if err != nil {
		return fmt.Errorf("create temp: %w", err)
	}
	cleanup := func() { _ = os.Remove(tmp.Name()) }
	if _, err := tmp.Write(body); err != nil {
		_ = tmp.Close()
		cleanup()
		return err
	}
	if err := tmp.Close(); err != nil {
		cleanup()
		return err
	}
	return os.Rename(tmp.Name(), path)
}
