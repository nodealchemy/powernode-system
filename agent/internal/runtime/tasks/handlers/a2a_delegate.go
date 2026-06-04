package handlers

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/a2a"
	"github.com/nodealchemy/powernode-system/agent/internal/enroll"
	"github.com/nodealchemy/powernode-system/agent/internal/runtime/tasks"
	"github.com/nodealchemy/powernode-system/agent/internal/transport"
)

// executeResultPath reports a delegated call's outcome so the mission's
// aggregate! flips the assignee from dispatched -> executed.
const executeResultPath = "/api/v1/system/node_api/peer/execute_result"

// A2ADelegateHandler executes a mission-delegated agent-to-agent (A2A) call: it
// presents THIS node's enrolled mTLS identity + the platform-minted capability
// token (carried in the task) to a peer's A2A server, invokes the skill, and
// reports the outcome via node_api/peer/execute_result — the on-node half of
// mission-driven A2A delegation (the platform mints the token at delegate! time;
// this consumes it over the mesh with no platform round-trip at call time).
type A2ADelegateHandler struct {
	PKIDir    string
	Transport *transport.SwappableClient
}

// delegation is the parsed Task.Options for an a2a_call.
type delegation struct {
	PeerURL string
	Skill   string
	Args    any
	Token   *a2a.Token
}

// parseDelegation validates + normalizes the task options. peer_url wins; else
// the first target_addresses entry becomes https://<addr>. Pure (no I/O) so the
// validation + address derivation are unit-testable without certs or a server.
func parseDelegation(options map[string]any) (delegation, error) {
	var o struct {
		PeerURL         string   `json:"peer_url"`
		TargetAddresses []string `json:"target_addresses"`
		Skill           string   `json:"skill"`
		Args            any      `json:"args"`
		CapabilityToken struct {
			Envelope  string `json:"envelope"`
			Signature string `json:"signature"`
		} `json:"capability_token"`
	}
	raw, _ := json.Marshal(options)
	if err := json.Unmarshal(raw, &o); err != nil {
		return delegation{}, fmt.Errorf("a2a_call: bad options: %w", err)
	}

	peerURL := o.PeerURL
	if peerURL == "" && len(o.TargetAddresses) > 0 {
		peerURL = "https://" + o.TargetAddresses[0]
	}
	if peerURL == "" {
		return delegation{}, fmt.Errorf("a2a_call: peer_url or target_addresses is required")
	}
	if o.Skill == "" {
		return delegation{}, fmt.Errorf("a2a_call: skill is required")
	}
	if o.CapabilityToken.Envelope == "" || o.CapabilityToken.Signature == "" {
		return delegation{}, fmt.Errorf("a2a_call: capability_token {envelope, signature} is required")
	}
	return delegation{
		PeerURL: peerURL,
		Skill:   o.Skill,
		Args:    o.Args,
		Token:   &a2a.Token{Envelope: o.CapabilityToken.Envelope, Signature: o.CapabilityToken.Signature},
	}, nil
}

func (h *A2ADelegateHandler) Execute(_ context.Context, task *tasks.Task) (tasks.Result, error) {
	d, err := parseDelegation(task.Options)
	if err != nil {
		return nil, err
	}
	client, err := h.a2aClient()
	if err != nil {
		return nil, err
	}

	res, callErr := client.CallSkill(d.PeerURL, d.Token, d.Skill, d.Args)
	h.reportResult(callErr == nil) // best-effort; mission aggregate! reads this

	if callErr != nil {
		return nil, fmt.Errorf("a2a_call %q -> %s: %w", d.Skill, d.PeerURL, callErr)
	}
	return tasks.Result{"skill": d.Skill, "target": d.PeerURL, "a2a_response": json.RawMessage(res)}, nil
}

// a2aClient builds an A2A client presenting this node's enrolled cert, verifying
// the peer's server cert against the issuing internal CA (ca-chain.crt) — the
// same trust root the peer's A2A server presents.
func (h *A2ADelegateHandler) a2aClient() (*a2a.Client, error) {
	paths := enroll.PathsUnder(h.PKIDir)
	cert, err := tls.LoadX509KeyPair(paths.Cert, paths.Key)
	if err != nil {
		return nil, fmt.Errorf("a2a_call: load node identity from %s: %w", h.PKIDir, err)
	}
	caPEM, err := os.ReadFile(paths.CAChain)
	if err != nil {
		return nil, fmt.Errorf("a2a_call: read ca chain: %w", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caPEM) {
		return nil, fmt.Errorf("a2a_call: ca chain %s has no parseable certs", paths.CAChain)
	}
	httpClient := &http.Client{
		Timeout:   30 * time.Second,
		Transport: &http.Transport{TLSClientConfig: a2a.ClientTLSConfig(cert, pool)},
	}
	return a2a.NewClient(httpClient), nil
}

func (h *A2ADelegateHandler) reportResult(success bool) {
	if h.Transport == nil {
		return
	}
	body, _ := json.Marshal(map[string]any{"success": success})
	resp, err := h.Transport.Get().PostJSON(executeResultPath, body)
	if err == nil && resp != nil {
		_ = resp.Body.Close()
	}
}

// RegisterA2ADelegate binds the a2a_call command to the delegation executor.
func RegisterA2ADelegate(r *tasks.Registry, deps tasks.Dependencies) {
	r.Register("a2a_call", &A2ADelegateHandler{PKIDir: deps.PKIDir, Transport: deps.Transport})
}
