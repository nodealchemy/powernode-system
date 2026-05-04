// Package dockerd implements the agent side of the Phase B Docker daemon
// auto-registration protocol. The protocol surface (POST
// /api/v1/system/node_api/runtime/handshake) is defined platform-side
// in extensions/system/server/.../runtime_controller.rb; this package is
// the typed Go client for it.
//
// Three phases keyed by `phase`:
//
//   wants_cert: agent generates an Ed25519 keypair, builds a CSR with
//               CN = "docker-daemon-<node_instance_id>", POSTs the CSR.
//               Platform returns the CA-signed leaf cert + CA chain.
//               Idempotent — repeated calls re-issue cleanly so cert
//               rotation rides the same code path.
//
//   ready:      agent reports dockerd is up, observed version. Platform
//               flips the managed Devops::DockerHost row from `pending`
//               to `connected`. Sent once per dockerd start.
//
//   stopped:    agent reports dockerd is no longer listening (clean
//               shutdown, module unassignment). Platform flips host to
//               `disconnected`. Sent best-effort during teardown.
//
// systemctl integration, daemon.json writing, file persistence, and
// systemd unit lifecycle live in a sibling package
// (internal/runtime/docker_daemon, future slice). This package is
// strictly the wire protocol — testable in isolation against an
// httptest server.
package dockerd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/powernode/platform/extensions/system/agent/internal/enroll"
	"github.com/powernode/platform/extensions/system/agent/internal/transport"
)

// HandshakePath is the agent → platform endpoint. Mounted under
// /api/v1/system/node_api/ with the standard mTLS+JWT auth chain
// (BaseController#authenticate_instance!).
const HandshakePath = "/api/v1/system/node_api/runtime/handshake"

// RuntimeKind is the daemon family the handshake is for. Controller's
// RUNTIME_MODULES allow-list expands across phases:
//   Phase 1 (now):  "docker"
//   Phase 2:        "k3s_server", "k3s_agent"
//   Phase 3:        "kubeadm_controlplane", "kubeadm_worker"
type RuntimeKind string

const (
	RuntimeDocker RuntimeKind = "docker"
)

// Phase is the state-machine transition the agent is announcing.
type Phase string

const (
	PhaseWantsCert Phase = "wants_cert"
	PhaseReady     Phase = "ready"
	PhaseStopped   Phase = "stopped"
)

// HandshakeRequest is the JSON body posted to /runtime/handshake.
// Optional fields are zero-value-omitted on the wire so a stopped
// signal doesn't leak version/csr noise into platform logs.
type HandshakeRequest struct {
	Runtime       RuntimeKind `json:"runtime"`
	Phase         Phase       `json:"phase"`
	CSRPEM        string      `json:"csr_pem,omitempty"`
	Version       string      `json:"version,omitempty"`
	ListenAddress string      `json:"listen_address,omitempty"`
}

// SignedCertificate is the payload returned for phase=wants_cert. The
// agent persists Cert + CAChain to disk + uses them in dockerd's
// /etc/docker/daemon.json. NotAfter is informational — agent should
// rotate well before expiry (refresh recommended at ~75% of lifetime).
type SignedCertificate struct {
	CertPEM    string    `json:"cert_pem"`
	CAChainPEM string    `json:"ca_chain_pem"`
	Serial     string    `json:"serial"`
	NotAfter   time.Time `json:"-"`
	NotAfterISO string   `json:"not_after"`
}

// ReadyAck is the payload returned for phase=ready. Mirrors the platform
// host_summary shape for a managed DockerHost.
type ReadyAck struct {
	HostID      string `json:"host_id"`
	HostStatus  string `json:"host_status"`
	APIEndpoint string `json:"api_endpoint"`
}

// StoppedAck is the payload returned for phase=stopped.
type StoppedAck struct {
	Acknowledged bool   `json:"acknowledged"`
	HostID       string `json:"host_id,omitempty"`
}

// envelope mirrors the platform's render_success shape:
//   { success: true, data: { ... } } on 2xx
//   { success: false, error: "..." }  on 4xx/5xx
type envelope[T any] struct {
	Success bool   `json:"success"`
	Error   string `json:"error,omitempty"`
	Data    T      `json:"data"`
}

// wantsCertEnvelope wraps the cert payload — platform returns it as
// { success: true, data: { certificate: {...} } } per render_success
// expansion of the keyword arg.
type certData struct {
	Certificate SignedCertificate `json:"certificate"`
}

// HandshakeError is returned when the platform rejects a handshake. The
// status code distinguishes operator-fixable issues (403 missing
// module assignment, 422 unsupported runtime) from transient ones
// (503 CA unavailable). Callers can branch on Status to decide retry
// vs. backoff.
type HandshakeError struct {
	Status  int
	Phase   Phase
	Runtime RuntimeKind
	Body    string
}

func (e *HandshakeError) Error() string {
	return fmt.Sprintf("dockerd handshake %s/%s failed: HTTP %d: %s",
		e.Runtime, e.Phase, e.Status, e.Body)
}

// Client is the typed wrapper around transport.Client. Construct with
// NewClient(transportClient).
type Client struct {
	transport *transport.Client
}

// NewClient wraps an existing transport client. The transport client
// owns the mTLS material + platform URL; this just adds typed methods.
func NewClient(t *transport.Client) *Client {
	return &Client{transport: t}
}

// RequestServerCert generates a fresh Ed25519 keypair, builds a CSR
// with CN="docker-daemon-<nodeInstanceID>", and POSTs phase=wants_cert.
// Returns the keypair (so the caller can persist the private key
// alongside the signed cert) plus the platform's signed cert payload.
//
// Usage pattern:
//   kp, signed, err := client.RequestServerCert(ctx, instanceID)
//   if err != nil { return err }
//   keyPEM, _ := kp.PrivatePEM()
//   writeFile("/etc/docker/server-key.pem", keyPEM)
//   writeFile("/etc/docker/server-cert.pem", []byte(signed.CertPEM))
//   writeFile("/etc/docker/ca.pem",          []byte(signed.CAChainPEM))
func (c *Client) RequestServerCert(ctx context.Context, nodeInstanceID string) (*enroll.Keypair, *SignedCertificate, error) {
	if nodeInstanceID == "" {
		return nil, nil, errors.New("RequestServerCert: nodeInstanceID required")
	}
	kp, err := enroll.GenerateKeypair()
	if err != nil {
		return nil, nil, fmt.Errorf("generate keypair: %w", err)
	}
	csr, err := enroll.BuildCSR(kp, "docker-daemon-"+nodeInstanceID)
	if err != nil {
		return nil, nil, fmt.Errorf("build CSR: %w", err)
	}

	req := HandshakeRequest{
		Runtime: RuntimeDocker,
		Phase:   PhaseWantsCert,
		CSRPEM:  string(csr),
	}
	var data certData
	if err := c.do(ctx, req, &data); err != nil {
		return kp, nil, err
	}

	// Best-effort NotAfter parse; platform sends ISO-8601 UTC. If the
	// parse fails we leave NotAfter zero — the caller's rotation
	// scheduler can fall back to a conservative default.
	if data.Certificate.NotAfterISO != "" {
		if t, perr := time.Parse(time.RFC3339, data.Certificate.NotAfterISO); perr == nil {
			data.Certificate.NotAfter = t
		}
	}
	return kp, &data.Certificate, nil
}

// ReportReady POSTs phase=ready announcing the daemon is live. Optional
// version (semver string from `docker version`) helps operators see
// which release is running per-host.
func (c *Client) ReportReady(ctx context.Context, version, listenAddress string) (*ReadyAck, error) {
	req := HandshakeRequest{
		Runtime:       RuntimeDocker,
		Phase:         PhaseReady,
		Version:       version,
		ListenAddress: listenAddress,
	}
	var ack ReadyAck
	if err := c.do(ctx, req, &ack); err != nil {
		return nil, err
	}
	return &ack, nil
}

// ReportStopped POSTs phase=stopped during clean teardown. Best-effort —
// callers should NOT block on the result; if the platform is
// unreachable, the watchdog (sync_interval_seconds) will eventually
// flip the host status.
func (c *Client) ReportStopped(ctx context.Context) (*StoppedAck, error) {
	req := HandshakeRequest{
		Runtime: RuntimeDocker,
		Phase:   PhaseStopped,
	}
	var ack StoppedAck
	if err := c.do(ctx, req, &ack); err != nil {
		return nil, err
	}
	return &ack, nil
}

// do is the shared HTTP path. Body marshaling, auth header, and
// success/error envelope handling all live here so each phase method
// stays single-purpose.
func (c *Client) do(ctx context.Context, body HandshakeRequest, out any) error {
	if c.transport == nil || c.transport.Client == nil {
		return errors.New("dockerd.Client: transport not configured")
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
		// Try to extract the platform's error message from the envelope.
		var env envelope[json.RawMessage]
		_ = json.Unmarshal(respBody, &env)
		msg := env.Error
		if msg == "" {
			msg = string(respBody)
		}
		return &HandshakeError{
			Status:  resp.StatusCode,
			Phase:   body.Phase,
			Runtime: body.Runtime,
			Body:    msg,
		}
	}

	// 2xx — unmarshal the data envelope into the typed payload.
	env := envelope[json.RawMessage]{}
	if err := json.Unmarshal(respBody, &env); err != nil {
		return fmt.Errorf("decode envelope: %w", err)
	}
	if !env.Success {
		return &HandshakeError{Status: resp.StatusCode, Phase: body.Phase, Runtime: body.Runtime,
			Body: "platform returned success=false on 2xx"}
	}
	if len(env.Data) == 0 || string(env.Data) == "null" {
		// 2xx with no data — treat as success but leave `out` zero.
		return nil
	}
	if err := json.Unmarshal(env.Data, out); err != nil {
		return fmt.Errorf("decode data: %w", err)
	}
	return nil
}
