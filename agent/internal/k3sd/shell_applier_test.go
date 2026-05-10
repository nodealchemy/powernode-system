package k3sd

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// recordingExec is the test stub for ShellServerApplier.Exec /
// ShellAgentApplier.Exec. Records every invocation; returns canned
// stdout/error per command name.
type recordingExec struct {
	calls  []execCall
	stdout map[string]string
	err    map[string]error
}
type execCall struct {
	name string
	args []string
}

func (r *recordingExec) run(_ context.Context, name string, args ...string) ([]byte, error) {
	r.calls = append(r.calls, execCall{name: name, args: append([]string(nil), args...)})
	return []byte(r.stdout[name]), r.err[name]
}

func newRecordingExec() *recordingExec {
	return &recordingExec{stdout: map[string]string{}, err: map[string]error{}}
}

// serverApplierWithTmpPaths returns a ShellServerApplier rooted in a
// tmpdir + a stub Exec.
func serverApplierWithTmpPaths(t *testing.T) (*ShellServerApplier, *recordingExec, string) {
	t.Helper()
	dir := t.TempDir()
	exec := newRecordingExec()
	a := &ShellServerApplier{
		Paths: DaemonPaths{
			BinaryPath:          filepath.Join(dir, "bin/k3s"),
			UninstallScriptPath: filepath.Join(dir, "bin/k3s-uninstall.sh"),
			KubeconfigPath:      filepath.Join(dir, "etc/rancher/k3s/k3s.yaml"),
			ServerTokenPath:     filepath.Join(dir, "var/lib/rancher/k3s/server/node-token"),
		},
		Unit: "k3s.service",
		Exec: exec.run,
	}
	return a, exec, dir
}

func agentApplierWithTmpPaths(t *testing.T) (*ShellAgentApplier, *recordingExec, string) {
	t.Helper()
	dir := t.TempDir()
	exec := newRecordingExec()
	a := &ShellAgentApplier{
		Paths: DaemonPaths{
			BinaryPath:         filepath.Join(dir, "bin/k3s"),
			UninstallAgentPath: filepath.Join(dir, "bin/k3s-agent-uninstall.sh"),
			AgentEnvFilePath:   filepath.Join(dir, "etc/systemd/system/k3s-agent.service.d/override.conf"),
		},
		Unit: "k3s-agent.service",
		Exec: exec.run,
	}
	return a, exec, dir
}

// ──────────────────────────────────────────────────────────────────
// ShellServerApplier tests
// ──────────────────────────────────────────────────────────────────

func TestShellServerApplier_HasInstalled_FalseWhenAbsent(t *testing.T) {
	a, _, _ := serverApplierWithTmpPaths(t)
	got, err := a.HasInstalled(context.Background())
	if err != nil {
		t.Fatalf("HasInstalled: %v", err)
	}
	if got {
		t.Fatal("expected HasInstalled=false on empty tmpdir")
	}
}

func TestShellServerApplier_HasInstalled_TrueWhenBinaryExists(t *testing.T) {
	a, _, _ := serverApplierWithTmpPaths(t)
	if err := os.MkdirAll(filepath.Dir(a.Paths.BinaryPath), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(a.Paths.BinaryPath, []byte("fake-binary"), 0o755); err != nil {
		t.Fatalf("write fake binary: %v", err)
	}
	got, err := a.HasInstalled(context.Background())
	if err != nil {
		t.Fatalf("HasInstalled: %v", err)
	}
	if !got {
		t.Fatal("expected HasInstalled=true after binary present")
	}
}

func TestShellServerApplier_InstallShellsToScript(t *testing.T) {
	a, exec, _ := serverApplierWithTmpPaths(t)
	if err := a.InstallK3sServer(context.Background(), BootstrapConfig{}); err != nil {
		t.Fatalf("InstallK3sServer: %v", err)
	}
	if len(exec.calls) != 1 {
		t.Fatalf("expected 1 exec call, got %d", len(exec.calls))
	}
	if exec.calls[0].name != "sh" {
		t.Fatalf("expected sh, got %q", exec.calls[0].name)
	}
	joined := strings.Join(exec.calls[0].args, " ")
	if !strings.Contains(joined, "INSTALL_K3S_EXEC=server") {
		t.Fatalf("expected install script to set INSTALL_K3S_EXEC=server, got %v", exec.calls[0].args)
	}
	// Empty BootstrapConfig must NOT smuggle in CNI args (default
	// flannel = upstream K3s default = no extra args).
	if strings.Contains(joined, "--flannel-backend") || strings.Contains(joined, "--disable-network-policy") {
		t.Fatalf("empty BootstrapConfig leaked CNI args: %v", exec.calls[0].args)
	}
}

func TestShellServerApplier_IsDaemonRunning_ParsesActive(t *testing.T) {
	a, exec, _ := serverApplierWithTmpPaths(t)
	exec.stdout["systemctl"] = "active\n"

	got, err := a.IsRunning(context.Background())
	if err != nil {
		t.Fatalf("IsRunning: %v", err)
	}
	if !got {
		t.Fatal("expected true for active output")
	}
	if exec.calls[0].args[0] != "is-active" || exec.calls[0].args[1] != "k3s.service" {
		t.Fatalf("expected systemctl is-active k3s.service, got %v", exec.calls[0].args)
	}
}

func TestShellServerApplier_IsDaemonRunning_FalseForInactive(t *testing.T) {
	a, exec, _ := serverApplierWithTmpPaths(t)
	exec.stdout["systemctl"] = "inactive\n"
	got, _ := a.IsRunning(context.Background())
	if got {
		t.Fatal("expected false for inactive")
	}
}

func TestShellServerApplier_VersionParsesK3sOutput(t *testing.T) {
	a, exec, _ := serverApplierWithTmpPaths(t)
	exec.stdout[a.Paths.BinaryPath] = "k3s version v1.30.4+k3s1 (abc1234)\ngo version go1.22.5\n"

	got, err := a.Version(context.Background())
	if err != nil {
		t.Fatalf("Version: %v", err)
	}
	if got != "v1.30.4+k3s1" {
		t.Fatalf("expected v1.30.4+k3s1, got %q", got)
	}
}

func TestShellServerApplier_VersionEmptyOnExecError(t *testing.T) {
	a, exec, _ := serverApplierWithTmpPaths(t)
	exec.err[a.Paths.BinaryPath] = errors.New("exec failed")

	got, err := a.Version(context.Background())
	if err != nil {
		t.Fatalf("expected nil error on exec failure, got %v", err)
	}
	if got != "" {
		t.Fatalf("expected empty version on error, got %q", got)
	}
}

func TestShellServerApplier_CaptureBootstrapState_EmptyWhenAbsent(t *testing.T) {
	a, _, _ := serverApplierWithTmpPaths(t)
	state, err := a.CaptureBootstrapState(context.Background())
	if err != nil {
		t.Fatalf("CaptureBootstrapState: %v", err)
	}
	if state.Kubeconfig != "" || state.ServerToken != "" {
		t.Fatalf("expected empty state when files absent, got %+v", state)
	}
}

func TestShellServerApplier_CaptureBootstrapState_PopulatedFromFiles(t *testing.T) {
	a, _, _ := serverApplierWithTmpPaths(t)
	if err := os.MkdirAll(filepath.Dir(a.Paths.KubeconfigPath), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.MkdirAll(filepath.Dir(a.Paths.ServerTokenPath), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(a.Paths.KubeconfigPath, []byte("apiVersion: v1\nkind: Config"), 0o600); err != nil {
		t.Fatalf("write kubeconfig: %v", err)
	}
	if err := os.WriteFile(a.Paths.ServerTokenPath, []byte("K10server-token\n"), 0o600); err != nil {
		t.Fatalf("write token: %v", err)
	}

	state, err := a.CaptureBootstrapState(context.Background())
	if err != nil {
		t.Fatalf("CaptureBootstrapState: %v", err)
	}
	if !strings.Contains(state.Kubeconfig, "apiVersion: v1") {
		t.Fatalf("kubeconfig not loaded: %q", state.Kubeconfig)
	}
	if state.ServerToken != "K10server-token" {
		t.Fatalf("server_token not trimmed: %q", state.ServerToken)
	}
	if state.AgentToken != state.ServerToken {
		t.Fatalf("agent_token should equal server_token in v1, got %q vs %q",
			state.AgentToken, state.ServerToken)
	}
}

func TestShellServerApplier_Cleanup_TolerantOfMissing(t *testing.T) {
	a, _, _ := serverApplierWithTmpPaths(t)
	if err := a.Cleanup(context.Background()); err != nil {
		t.Fatalf("expected Cleanup to tolerate missing uninstall script, got %v", err)
	}
}

func TestShellServerApplier_Cleanup_ExecsScriptWhenPresent(t *testing.T) {
	a, exec, _ := serverApplierWithTmpPaths(t)
	if err := os.MkdirAll(filepath.Dir(a.Paths.UninstallScriptPath), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(a.Paths.UninstallScriptPath, []byte("#!/bin/sh\nexit 0"), 0o755); err != nil {
		t.Fatalf("write script: %v", err)
	}

	if err := a.Cleanup(context.Background()); err != nil {
		t.Fatalf("Cleanup: %v", err)
	}
	if len(exec.calls) != 1 || exec.calls[0].name != a.Paths.UninstallScriptPath {
		t.Fatalf("expected exec of uninstall script, got %+v", exec.calls)
	}
}

// ──────────────────────────────────────────────────────────────────
// ShellAgentApplier tests
// ──────────────────────────────────────────────────────────────────

func TestShellAgentApplier_InstallShellsToAgentScript(t *testing.T) {
	a, exec, _ := agentApplierWithTmpPaths(t)
	if err := a.InstallK3sAgent(context.Background()); err != nil {
		t.Fatalf("InstallK3sAgent: %v", err)
	}
	if !strings.Contains(strings.Join(exec.calls[0].args, " "), "INSTALL_K3S_EXEC=agent") {
		t.Fatalf("expected agent install script, got %v", exec.calls[0].args)
	}
}

func TestShellAgentApplier_HasJoinConfig_FalseWhenAbsent(t *testing.T) {
	a, _, _ := agentApplierWithTmpPaths(t)
	got, err := a.HasJoinConfig(context.Background())
	if err != nil {
		t.Fatalf("HasJoinConfig: %v", err)
	}
	if got {
		t.Fatal("expected HasJoinConfig=false on empty tmpdir")
	}
}

func TestShellAgentApplier_WriteJoinConfig_RendersValidEnv(t *testing.T) {
	a, _, _ := agentApplierWithTmpPaths(t)
	cfg := AgentJoinConfig{
		APIEndpoint: "https://[fd00::1]:6443",
		AgentToken:  "K10agent-tok",
	}
	if err := a.WriteJoinConfig(context.Background(), cfg); err != nil {
		t.Fatalf("WriteJoinConfig: %v", err)
	}
	body, err := os.ReadFile(a.Paths.AgentEnvFilePath)
	if err != nil {
		t.Fatalf("read env file: %v", err)
	}
	bs := string(body)
	if !strings.Contains(bs, `K3S_URL=https://[fd00::1]:6443`) {
		t.Fatalf("expected K3S_URL line, got %q", bs)
	}
	if !strings.Contains(bs, `K3S_TOKEN=K10agent-tok`) {
		t.Fatalf("expected K3S_TOKEN line, got %q", bs)
	}
	// Sanity check: should be a valid systemd drop-in [Service] block.
	if !strings.HasPrefix(bs, "[Service]") {
		t.Fatalf("expected [Service] header, got %q", bs)
	}
}

func TestShellAgentApplier_WriteJoinConfig_RejectsEmpty(t *testing.T) {
	a, _, _ := agentApplierWithTmpPaths(t)
	err := a.WriteJoinConfig(context.Background(), AgentJoinConfig{})
	if err == nil {
		t.Fatal("expected error for empty AgentJoinConfig")
	}
}

func TestShellAgentApplier_HasJoinConfig_TrueAfterWrite(t *testing.T) {
	a, _, _ := agentApplierWithTmpPaths(t)
	if err := a.WriteJoinConfig(context.Background(), AgentJoinConfig{
		APIEndpoint: "https://[fd00::1]:6443", AgentToken: "tok",
	}); err != nil {
		t.Fatalf("WriteJoinConfig: %v", err)
	}
	got, err := a.HasJoinConfig(context.Background())
	if err != nil {
		t.Fatalf("HasJoinConfig: %v", err)
	}
	if !got {
		t.Fatal("expected HasJoinConfig=true after write")
	}
}

func TestShellAgentApplier_StartUsesAgentUnit(t *testing.T) {
	a, exec, _ := agentApplierWithTmpPaths(t)
	if err := a.Start(context.Background()); err != nil {
		t.Fatalf("Start: %v", err)
	}
	if exec.calls[0].args[1] != "k3s-agent.service" {
		t.Fatalf("expected k3s-agent.service unit, got %q", exec.calls[0].args[1])
	}
}

func TestShellAgentApplier_Cleanup_RemovesEnvFile(t *testing.T) {
	a, _, _ := agentApplierWithTmpPaths(t)
	if err := a.WriteJoinConfig(context.Background(), AgentJoinConfig{
		APIEndpoint: "https://x", AgentToken: "tok",
	}); err != nil {
		t.Fatalf("WriteJoinConfig: %v", err)
	}
	if err := a.Cleanup(context.Background()); err != nil {
		t.Fatalf("Cleanup: %v", err)
	}
	if _, err := os.Stat(a.Paths.AgentEnvFilePath); !os.IsNotExist(err) {
		t.Fatalf("expected env file removed, got err=%v", err)
	}
}

// ──────────────────────────────────────────────────────────────────
// Phase O4 — CNI plugin selection (BootstrapConfig.CniPlugin →
// install args). Covers the four cases the platform can stamp:
// explicit flannel, empty (= flannel), ovn_kubernetes, and the
// defensive unknown-value path. The unknown-value fallback warning
// is exercised end-to-end in server_manager_test.go; here we only
// verify the BootstrapConfig.InstallArgs() return value, since the
// applier itself is intentionally mechanical (caller owns the
// fallback decision).
// ──────────────────────────────────────────────────────────────────

func TestShellServerApplier_Install_FlannelExplicit_NoExtraArgs(t *testing.T) {
	a, exec, _ := serverApplierWithTmpPaths(t)
	cfg := BootstrapConfig{CniPlugin: CniPluginFlannel}
	if err := a.InstallK3sServer(context.Background(), cfg); err != nil {
		t.Fatalf("InstallK3sServer: %v", err)
	}
	joined := strings.Join(exec.calls[0].args, " ")
	if strings.Contains(joined, "--flannel-backend") {
		t.Fatalf("flannel explicit must not append --flannel-backend, got %v", exec.calls[0].args)
	}
	if strings.Contains(joined, "--disable-network-policy") {
		t.Fatalf("flannel explicit must not append --disable-network-policy, got %v", exec.calls[0].args)
	}
	if !strings.Contains(joined, "INSTALL_K3S_EXEC=server") {
		t.Fatalf("expected install script invocation, got %v", exec.calls[0].args)
	}
}

func TestShellServerApplier_Install_EmptyCni_NoExtraArgs(t *testing.T) {
	a, exec, _ := serverApplierWithTmpPaths(t)
	cfg := BootstrapConfig{} // CniPlugin == "" → same as flannel
	if err := a.InstallK3sServer(context.Background(), cfg); err != nil {
		t.Fatalf("InstallK3sServer: %v", err)
	}
	joined := strings.Join(exec.calls[0].args, " ")
	if strings.Contains(joined, "--flannel-backend") || strings.Contains(joined, "--disable-network-policy") {
		t.Fatalf("empty CniPlugin must not append CNI args, got %v", exec.calls[0].args)
	}
}

func TestShellServerApplier_Install_OvnKubernetes_AppendsBothFlags(t *testing.T) {
	a, exec, _ := serverApplierWithTmpPaths(t)
	cfg := BootstrapConfig{CniPlugin: CniPluginOvnKubernetes}
	if err := a.InstallK3sServer(context.Background(), cfg); err != nil {
		t.Fatalf("InstallK3sServer: %v", err)
	}
	if len(exec.calls) != 1 {
		t.Fatalf("expected 1 exec call, got %d", len(exec.calls))
	}
	joined := strings.Join(exec.calls[0].args, " ")
	if !strings.Contains(joined, "--flannel-backend=none") {
		t.Fatalf("ovn_kubernetes must append --flannel-backend=none, got %v", exec.calls[0].args)
	}
	if !strings.Contains(joined, "--disable-network-policy") {
		t.Fatalf("ovn_kubernetes must append --disable-network-policy, got %v", exec.calls[0].args)
	}
	if !strings.Contains(joined, "INSTALL_K3S_EXEC=server") {
		t.Fatalf("expected install script invocation preserved, got %v", exec.calls[0].args)
	}
	// Both flags must land AFTER the `sh -s -` delimiter so the
	// install script forwards them to the systemd unit's ExecStart.
	idx := strings.Index(joined, "sh -s -")
	if idx < 0 {
		t.Fatalf("expected `sh -s -` delimiter in install script, got %q", joined)
	}
	if !strings.Contains(joined[idx:], "--flannel-backend=none") ||
		!strings.Contains(joined[idx:], "--disable-network-policy") {
		t.Fatalf("CNI args must appear after `sh -s -` delimiter, got %q", joined)
	}
}

func TestBootstrapConfig_InstallArgs_UnknownReturnsNotOk(t *testing.T) {
	cfg := BootstrapConfig{CniPlugin: "calico"} // not in the allow-list
	args, ok := cfg.InstallArgs()
	if ok {
		t.Fatalf("expected ok=false for unknown CNI %q", cfg.CniPlugin)
	}
	if len(args) != 0 {
		t.Fatalf("expected nil/empty args on unknown CNI, got %v", args)
	}
	// Sanity-check the known good values still succeed so the
	// allow-list isn't accidentally inverted.
	if _, ok := (BootstrapConfig{CniPlugin: CniPluginFlannel}).InstallArgs(); !ok {
		t.Fatal("flannel InstallArgs() should return ok=true")
	}
	if _, ok := (BootstrapConfig{CniPlugin: CniPluginOvnKubernetes}).InstallArgs(); !ok {
		t.Fatal("ovn_kubernetes InstallArgs() should return ok=true")
	}
	if _, ok := (BootstrapConfig{}).InstallArgs(); !ok {
		t.Fatal("empty CniPlugin InstallArgs() should return ok=true")
	}
}
