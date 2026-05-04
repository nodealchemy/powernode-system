// Package k3sd implements the agent side of the Phase 2 K3s cluster
// auto-registration protocol. The protocol surface (POST
// /api/v1/system/node_api/runtime/handshake) is shared with the
// docker daemon flow but uses K3s-specific phases:
//
//   bootstrap     (k3s_server only) — agent reports a fresh K3s
//                 cluster came up. Body carries the captured
//                 kubeconfig + server/agent join tokens. Platform
//                 creates a Devops::KubernetesCluster row.
//
//   join_request  (k3s_agent only) — agent asks the platform for the
//                 cluster's api_endpoint + agent_token so it can
//                 invoke `k3s agent --server <api> --token <token>`.
//                 Returns the membership material.
//
//   ready         (both) — agent reports the kubelet is up.
//                 Platform flips the corresponding KubernetesNode
//                 to status=active.
//
//   stopped       (both) — agent reports clean shutdown. Platform
//                 flips the node to status=disconnected.
//
// systemctl integration, k3s install, and config file writing live
// in a sibling package internal/k3sd/applier — extracted in a
// follow-up slice. This package is strictly the wire protocol +
// state machine, testable in isolation against an httptest server.
package k3sd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/powernode/platform/extensions/system/agent/internal/transport"
)

// HandshakePath is the agent → platform endpoint. Shared with the
// docker daemon protocol — same controller, different runtimes.
const HandshakePath = "/api/v1/system/node_api/runtime/handshake"

// RuntimeKind tracks which K3s role the calling agent is playing.
// Values must match the platform's RUNTIME_MODULES keys exactly.
type RuntimeKind string

const (
	RuntimeK3sServer RuntimeKind = "k3s_server"
	RuntimeK3sAgent  RuntimeKind = "k3s_agent"
)

// Phase is the state-machine transition the agent is announcing.
type Phase string

const (
	PhaseBootstrap   Phase = "bootstrap"
	PhaseJoinRequest Phase = "join_request"
	PhaseReady       Phase = "ready"
	PhaseStopped     Phase = "stopped"
)

// Role values reported on phase=ready. Mirrors the platform's
// devops_kubernetes_nodes.role enum (k3s vocab subset; kubeadm
// vocab covered by the same enum but reported only by Phase 3
// runtimes).
const (
	RoleServer = "server"
	RoleAgent  = "agent"
)

// HandshakeRequest is the JSON body posted to /runtime/handshake.
// Optional fields are zero-value-omitted on the wire so a stopped
// signal doesn't leak bootstrap noise into platform logs.
//
// Fields are a superset of the K3s phases — bootstrap uses
// Kubeconfig/ServerToken/AgentToken/K8sVersion; join_request uses
// none of them; ready uses Version + Role.
type HandshakeRequest struct {
	Runtime RuntimeKind `json:"runtime"`
	Phase   Phase       `json:"phase"`

	// Bootstrap fields (k3s_server, phase=bootstrap)
	Kubeconfig  string `json:"kubeconfig,omitempty"`
	ServerToken string `json:"server_token,omitempty"`
	AgentToken  string `json:"agent_token,omitempty"`
	K8sVersion  string `json:"k8s_version,omitempty"`

	// Ready fields (both, phase=ready)
	Version string `json:"version,omitempty"`
	Role    string `json:"role,omitempty"`
}

// BootstrapAck is the payload returned for phase=bootstrap. Mirrors
// the platform's KubernetesClusterProvisionerService.bootstrap!
// response shape.
type BootstrapAck struct {
	ClusterID     string `json:"cluster_id"`
	ClusterStatus string `json:"cluster_status"`
	APIEndpoint   string `json:"api_endpoint"`
}

// JoinRequestPayload is what the platform returns for phase=join_request.
// Agent uses APIEndpoint + AgentToken to run `k3s agent --server <api>
// --token <token>`. CAPem is optional (platform may not be able to
// extract it from the kubeconfig in v1; agent should fall back to
// kubeconfig retrieval if needed).
type JoinRequestPayload struct {
	ClusterID   string `json:"cluster_id"`
	APIEndpoint string `json:"api_endpoint"`
	AgentToken  string `json:"agent_token"`
	CAPem       string `json:"ca_pem,omitempty"`
}

// ReadyAck is the payload returned for phase=ready. Captures the
// node-side bookkeeping flip (joining → active) the platform just
// applied.
type ReadyAck struct {
	NodeID     string `json:"node_id"`
	ClusterID  string `json:"cluster_id"`
	NodeStatus string `json:"node_status"`
	Role       string `json:"role"`
}

// StoppedAck is the payload returned for phase=stopped.
type StoppedAck struct {
	Acknowledged bool   `json:"acknowledged"`
	NodeID       string `json:"node_id,omitempty"`
}

// envelope mirrors the platform's render_success shape:
//   { success: true, data: { ... } } on 2xx
//   { success: false, error: "..." }  on 4xx/5xx
type envelope[T any] struct {
	Success bool   `json:"success"`
	Error   string `json:"error,omitempty"`
	Data    T      `json:"data"`
}

// HandshakeError is returned when the platform rejects a handshake.
// Status distinguishes operator-fixable issues (403 missing module
// assignment, 422 unsupported phase) from transient ones (503 CA
// or DB unavailable). Callers branch on Status to decide retry
// strategy.
type HandshakeError struct {
	Status  int
	Phase   Phase
	Runtime RuntimeKind
	Body    string
}

func (e *HandshakeError) Error() string {
	return fmt.Sprintf("k3sd handshake %s/%s failed: HTTP %d: %s",
		e.Runtime, e.Phase, e.Status, e.Body)
}

// Client is the typed wrapper around transport.Client. Construct with
// NewClient(transportClient).
type Client struct {
	transport *transport.Client
}

// NewClient wraps an existing transport client. Same shape as
// dockerd.NewClient — the transport handles mTLS + auth, this just
// adds typed K3s methods.
func NewClient(t *transport.Client) *Client {
	return &Client{transport: t}
}

// Bootstrap (k3s_server only) reports a freshly-installed cluster up
// to the platform. The platform creates the cluster row + bootstrap
// KubernetesNode in one transaction. Idempotent — re-bootstrapping
// refreshes credentials.
func (c *Client) Bootstrap(ctx context.Context, kubeconfig, serverToken, agentToken, k8sVersion string) (*BootstrapAck, error) {
	if kubeconfig == "" {
		return nil, errors.New("Bootstrap: kubeconfig required")
	}
	if serverToken == "" {
		return nil, errors.New("Bootstrap: serverToken required")
	}
	req := HandshakeRequest{
		Runtime:     RuntimeK3sServer,
		Phase:       PhaseBootstrap,
		Kubeconfig:  kubeconfig,
		ServerToken: serverToken,
		AgentToken:  agentToken,
		K8sVersion:  k8sVersion,
	}
	var ack BootstrapAck
	if err := c.do(ctx, req, &ack); err != nil {
		return nil, err
	}
	return &ack, nil
}

// JoinRequest (k3s_agent only) asks the platform for the cluster's
// api_endpoint + agent_token. Returned token feeds directly into
// `k3s agent --server <api> --token <token>`.
func (c *Client) JoinRequest(ctx context.Context) (*JoinRequestPayload, error) {
	req := HandshakeRequest{
		Runtime: RuntimeK3sAgent,
		Phase:   PhaseJoinRequest,
	}
	var payload JoinRequestPayload
	if err := c.do(ctx, req, &payload); err != nil {
		return nil, err
	}
	return &payload, nil
}

// ReportReady (both server + agent) announces kubelet is up. Optional
// version helps operators see which release each node is running per
// rolling-upgrade tick.
func (c *Client) ReportReady(ctx context.Context, runtime RuntimeKind, role, version string) (*ReadyAck, error) {
	req := HandshakeRequest{
		Runtime: runtime,
		Phase:   PhaseReady,
		Version: version,
		Role:    role,
	}
	var ack ReadyAck
	if err := c.do(ctx, req, &ack); err != nil {
		return nil, err
	}
	return &ack, nil
}

// ReportStopped (both) announces clean shutdown. Best-effort —
// callers should NOT block on the result.
func (c *Client) ReportStopped(ctx context.Context, runtime RuntimeKind) (*StoppedAck, error) {
	req := HandshakeRequest{Runtime: runtime, Phase: PhaseStopped}
	var ack StoppedAck
	if err := c.do(ctx, req, &ack); err != nil {
		return nil, err
	}
	return &ack, nil
}

// do is the shared HTTP path. Body marshaling, auth header, and
// success/error envelope handling live here so each phase method
// stays single-purpose. Mirrors dockerd.Client.do — small intentional
// duplication to keep the K3s package self-contained until a future
// slice extracts internal/runtime_handshake.
func (c *Client) do(ctx context.Context, body HandshakeRequest, out any) error {
	if c.transport == nil || c.transport.Client == nil {
		return errors.New("k3sd.Client: transport not configured")
	}
	buf, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("marshal request: %w", err)
	}
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost,
		c.transport.PlatformURL+HandshakePath, bytes.NewReader(buf))
	if err != nil {
		return fmt.Errorf("build request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")
	if c.transport.InstanceToken != "" {
		httpReq.Header.Set("Authorization", "Bearer "+c.transport.InstanceToken)
	}

	resp, err := c.transport.Do(httpReq)
	if err != nil {
		return fmt.Errorf("post handshake: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("read response: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		var env envelope[json.RawMessage]
		_ = json.Unmarshal(respBody, &env)
		msg := env.Error
		if msg == "" {
			msg = string(respBody)
		}
		return &HandshakeError{Status: resp.StatusCode, Phase: body.Phase,
			Runtime: body.Runtime, Body: msg}
	}

	env := envelope[json.RawMessage]{}
	if err := json.Unmarshal(respBody, &env); err != nil {
		return fmt.Errorf("decode envelope: %w", err)
	}
	if !env.Success {
		return &HandshakeError{Status: resp.StatusCode, Phase: body.Phase,
			Runtime: body.Runtime, Body: "platform returned success=false on 2xx"}
	}
	if len(env.Data) == 0 || string(env.Data) == "null" {
		return nil
	}
	if err := json.Unmarshal(env.Data, out); err != nil {
		return fmt.Errorf("decode data: %w", err)
	}
	return nil
}

// nilTimeFromMaybeRFC3339 best-effort parses an RFC3339 timestamp
// string. Returns zero Time on parse failure — callers treat zero as
// "unknown". Kept here for the BootstrapAck etc. — currently unused
// directly but useful for upcoming Phase 3 kubeadm fields.
func nilTimeFromMaybeRFC3339(s string) time.Time {
	if s == "" {
		return time.Time{}
	}
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return t
	}
	return time.Time{}
}

var _ = nilTimeFromMaybeRFC3339 // silence unused warning; kept for Phase 3
