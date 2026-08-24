package runtime

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
)

// AssignedModule is the typed view of one entry returned by
// GET /api/v1/system/node_api/modules. The reconciler uses these
// to drive its desired-state computation.
type AssignedModule struct {
	ID                string `json:"id"`
	Name              string `json:"name"`
	Priority          int    `json:"priority"`
	EffectivePriority int    `json:"effective_priority"`
	HasDataFile       bool   `json:"has_data_file"`
	Variety           string `json:"variety"`
}

// ModulesClient is the minimal subset *transport.Client must satisfy
// for the reconciler to fetch the assigned-modules list.
type ModulesClient interface {
	GetJSON(path string) (*http.Response, error)
}

// AssignmentMeta carries the envelope-level fields (beyond the module list) the
// agent needs from GET /api/v1/system/node_api/modules: the platform-assigned
// hostname (node.name) plus boot-LKG config the backend derives from
// SiteSettings. All the LKG fields are 0/"" when unset — the agent then falls to
// its compile-time defaults / kernel-cmdline overrides. Stamping the app-health
// probe config here (not just compiling it in) lets us later strengthen the
// promotion gate (e.g. a composed-API check instead of /up) by changing a
// SiteSetting, with NO new agent binary.
type AssignmentMeta struct {
	Hostname                     string
	StalenessThresholdSeconds    int64
	AppHealthURL                 string
	AppHealthRequiredConsecutive int
	AppHealthPollIntervalSeconds int
	// ProtectedEgressHosts are hostnames the reconciler's egress enforcement
	// must always allow, regardless of any individual module's own
	// egress_allow (see security.ApplyEgressAllowlistWithProtected). Backend-
	// configured (account settings / SiteSetting), not hardcoded — refetched
	// on every poll so a config change or DNS change takes effect on the
	// next reconcile tick without an agent restart.
	ProtectedEgressHosts []string
	// PrivilegedModuleIDs is the operator-controlled allowlist of module
	// identifiers permitted to run with security.privileged=true (which
	// disables ALL on-node confinement). A module's manifest can only REQUEST
	// privileged; this list, delivered by the control plane from an
	// admin-gated account setting / SiteSetting (never from the module
	// manifest), is the GRANT. Matched against a module's id AND name. Empty =
	// deny: a module that requests privileged without appearing here has its
	// attach REFUSED (IMP-01a02f70-20b1). Refetched every poll like
	// ProtectedEgressHosts, so an operator approval takes effect on the next
	// tick with no agent restart.
	PrivilegedModuleIDs []string
}

// FetchAssignedModules returns the rich-shape module list the
// reconciler needs (id + priority + variety + has_data_file flag)
// plus the envelope AssignmentMeta.
//
// The platform endpoint `/api/v1/system/node_api/modules` returns
// `serialize_module` per row — this decoder picks out the fields
// the reconciler cares about and ignores the rest.
func FetchAssignedModules(ctx context.Context, c ModulesClient) ([]AssignedModule, AssignmentMeta, error) {
	if c == nil {
		return nil, AssignmentMeta{}, errors.New("FetchAssignedModules: nil client")
	}
	resp, err := c.GetJSON("/api/v1/system/node_api/modules")
	if err != nil {
		return nil, AssignmentMeta{}, fmt.Errorf("get modules: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, AssignmentMeta{}, fmt.Errorf("modules status %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}

	var env struct {
		Success bool   `json:"success"`
		Error   string `json:"error,omitempty"`
		Data    struct {
			Modules                   []AssignedModule `json:"modules"`
			Hostname                  string           `json:"hostname,omitempty"`
			LKGStalenessThresholdSecs int64            `json:"lkg_staleness_threshold_seconds,omitempty"`
			LKGAppHealthURL           string           `json:"lkg_app_health_url,omitempty"`
			LKGAppHealthRequiredN     int              `json:"lkg_app_health_required_consecutive,omitempty"`
			LKGAppHealthPollSecs      int              `json:"lkg_app_health_poll_interval_seconds,omitempty"`
			ProtectedEgressHosts      []string         `json:"protected_egress_hosts,omitempty"`
			PrivilegedModuleIDs       []string         `json:"privileged_module_ids,omitempty"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, AssignmentMeta{}, fmt.Errorf("decode modules: %w", err)
	}
	if !env.Success {
		return nil, AssignmentMeta{}, fmt.Errorf("platform returned success=false: %s", env.Error)
	}
	// Persist the platform-assigned hostname (node.name) so desiredHostname()
	// can apply it even on nodes with no fw-cfg instance_name blob. This runs on
	// BOTH the pre-pivot compose fetch and the post-pivot reconcile fetch, and
	// happens before the same pass calls ApplyHostname — so the sysroot
	// /etc/hostname is correct before switch_root + DHCP. Best-effort; empty is
	// a no-op.
	persistAssignedHostname(env.Data.Hostname)
	_ = ctx // ctx reserved for future cancellation hook in the GetJSON impl
	return env.Data.Modules, AssignmentMeta{
		Hostname:                     env.Data.Hostname,
		StalenessThresholdSeconds:    env.Data.LKGStalenessThresholdSecs,
		AppHealthURL:                 env.Data.LKGAppHealthURL,
		AppHealthRequiredConsecutive: env.Data.LKGAppHealthRequiredN,
		AppHealthPollIntervalSeconds: env.Data.LKGAppHealthPollSecs,
		ProtectedEgressHosts:         env.Data.ProtectedEgressHosts,
		PrivilegedModuleIDs:          env.Data.PrivilegedModuleIDs,
	}, nil
}
