package k3sd

import "context"

// ModulesAPI is the surface the K3s reconcilers use to learn whether
// the k3s-server / k3s-agent module is assigned. Defined locally as
// an interface so callers can reuse dockerd.HTTPModulesClient (which
// satisfies this shape implicitly) — Go's structural typing makes
// the cross-package reuse free.
type ModulesAPI interface {
	AssignedModules(ctx context.Context) ([]string, error)
}

// CNI plugin identifiers accepted in BootstrapConfig.CniPlugin.
//
//   CniPluginFlannel       — K3s default. Embedded Flannel VXLAN +
//                            kube-proxy NetworkPolicy (lightweight
//                            profile). No extra install args.
//
//   CniPluginOvnKubernetes — Replace Flannel with OVN-Kubernetes
//                            (heavyweight profile, Phase O4). Agent
//                            installs K3s with `--flannel-backend=none
//                            --disable-network-policy` so the K3s
//                            server skips Flannel + kube-proxy
//                            NetworkPolicy and the OVN-K8s manifests
//                            (delivered separately at runtime) own
//                            the pod network end-to-end.
//
// Empty string is treated as CniPluginFlannel — same default as K3s.
// Unknown values fall back to flannel with a logged warning so a
// stale platform payload can't brick a cluster bootstrap.
const (
	CniPluginFlannel       = "flannel"
	CniPluginOvnKubernetes = "ovn_kubernetes"
)

// BootstrapConfig captures the per-instance K3s server bootstrap
// knobs the platform stamps in the runtime config payload. Fields
// are zero-value safe — an empty BootstrapConfig produces the
// upstream K3s default install (single-node, embedded Flannel,
// embedded etcd).
//
// CniPlugin selects the cluster's CNI driver. See the CniPlugin*
// constants for accepted values. The agent does NOT install the
// chosen CNI's manifests — that's a separate runtime step. Its job
// here is solely to gate the K3s install so the right pieces are
// or are not provisioned by K3s itself.
type BootstrapConfig struct {
	CniPlugin string `json:"cni_plugin"`
}

// InstallArgs returns the extra positional args that should be
// appended after `sh -s -` in the K3s install command for this
// bootstrap config. Returns (args, ok) — when ok is false, the
// CniPlugin value is unrecognized and the caller should log a
// warning and fall back to the flannel default (empty args).
//
// The K3s install script forwards everything after the `-s -`
// delimiter into the systemd unit's ExecStart, which becomes the
// `k3s server` invocation's argv. So `--flannel-backend=none
// --disable-network-policy` here translates 1:1 to the running
// daemon's flags.
func (c BootstrapConfig) InstallArgs() (args []string, ok bool) {
	switch c.CniPlugin {
	case "", CniPluginFlannel:
		return nil, true
	case CniPluginOvnKubernetes:
		return []string{"--flannel-backend=none", "--disable-network-policy"}, true
	default:
		return nil, false
	}
}

// ServerApplier is the agent's local-side surface for the K3s server
// daemon lifecycle. Production wraps `apt` + file IO + systemctl;
// tests inject an in-memory stub. Implementations MUST be idempotent
// — Reconcile may call any method on every tick when state is stable.
//
// The shell-out implementation (`shell_server_applier.go`, future
// slice) will:
//   - HasInstalled: stat /usr/local/bin/k3s
//   - InstallK3sServer: shell out to the k3s install script
//                       (curl -sfL https://get.k3s.io | sh -s - <args>)
//                       where <args> are the BootstrapConfig-derived
//                       flags (CNI selection, etc.).
//   - IsRunning / Start / Stop: systemctl on k3s.service
//   - Version: parse `k3s --version`
//   - CaptureBootstrapState: read /etc/rancher/k3s/k3s.yaml
//                            (kubeconfig) +
//                            /var/lib/rancher/k3s/server/node-token
//                            (server_token) — uses same token as
//                            agent_token in single-cluster v1.
//   - Cleanup: shell out to /usr/local/bin/k3s-uninstall.sh
type ServerApplier interface {
	HasInstalled(ctx context.Context) (bool, error)

	// InstallK3sServer runs the upstream K3s install script, baking
	// the per-instance bootstrap config (CNI selection, etc.) into
	// the resulting systemd unit's ExecStart. cfg.InstallArgs()
	// translates the typed config into the positional install-script
	// args; passing a zero-value BootstrapConfig is equivalent to
	// the upstream K3s default (embedded Flannel, embedded etcd).
	InstallK3sServer(ctx context.Context, cfg BootstrapConfig) error

	IsRunning(ctx context.Context) (bool, error)
	Start(ctx context.Context) error
	Stop(ctx context.Context) error
	Version(ctx context.Context) (string, error)

	// CaptureBootstrapState reads on-disk state populated by the K3s
	// server during bootstrap. Returns kubeconfig + tokens — the
	// payload the platform's bootstrap phase expects. Returns ""
	// strings + nil error when the daemon hasn't finished bootstrap
	// yet (caller defers to next tick).
	CaptureBootstrapState(ctx context.Context) (BootstrapState, error)

	// Cleanup tears down installation artifacts when the module is
	// unassigned. Tolerates "already removed".
	Cleanup(ctx context.Context) error
}

// AgentApplier is the worker-side counterpart. Less state to capture
// (no kubeconfig to upload) but more config to write (K3S_URL +
// K3S_TOKEN env from the platform's join_request response).
//
// Implemented by ShellAgentApplier (production) — Phase 1 finalization
// confirmed: end-to-end coverage in shell_applier_test.go covers
// install (TestShellAgentApplier_InstallShellsToAgentScript), join
// config write (TestShellAgentApplier_WriteJoinConfig_RendersValidEnv,
// _RejectsEmpty, _TrueAfterWrite), start (_StartUsesAgentUnit), and
// cleanup (_Cleanup_RemovesEnvFile). State-machine integration is
// covered by agent_manager_test.go.
//
// On the platform endpoint side: GET /runtime/k3s_agent/config returns
// empty in v1 because the join state (K3S_URL + K3S_TOKEN) is delivered
// inline in the join_request handshake response. Splitting it across a
// second endpoint would duplicate state without operator benefit; future
// per-runtime config overrides can land via that endpoint without
// changing the join flow.
type AgentApplier interface {
	HasInstalled(ctx context.Context) (bool, error)
	InstallK3sAgent(ctx context.Context) error
	IsRunning(ctx context.Context) (bool, error)
	Start(ctx context.Context) error
	Stop(ctx context.Context) error
	Version(ctx context.Context) (string, error)

	// HasJoinConfig returns true iff /etc/systemd/system/k3s-agent
	// .service.d/override.conf (or equivalent) carries a valid
	// K3S_URL + K3S_TOKEN. Used by Reconcile to decide whether to
	// hit the platform's join_request endpoint.
	HasJoinConfig(ctx context.Context) (bool, error)

	// WriteJoinConfig persists the cluster membership material
	// fetched from join_request. Atomic write — daemon won't see a
	// half-written config.
	WriteJoinConfig(ctx context.Context, cfg AgentJoinConfig) error

	Cleanup(ctx context.Context) error
}

// BootstrapState is the on-disk state the agent captures from a
// freshly-bootstrapped K3s server. All fields required for
// Bootstrap() — empty strings mean "not yet ready, retry next tick".
type BootstrapState struct {
	Kubeconfig  string
	ServerToken string
	AgentToken  string
}

// AgentJoinConfig is what the platform's join_request endpoint
// returns + what the agent persists locally so k3s-agent.service
// can read its env on start.
type AgentJoinConfig struct {
	APIEndpoint string // K3S_URL
	AgentToken  string // K3S_TOKEN
	CAPem       string // optional; empty when platform can't extract
}
