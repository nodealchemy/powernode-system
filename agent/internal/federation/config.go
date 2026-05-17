package federation

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
)

// Config is the federation spawn payload read from virtio-fw-cfg.
// The five fields below are populated by the parent's
// LocalQemu::CloudSeed when the parent spawned this child.
type Config struct {
	// ParentURL is the reachable HTTPS URL of the parent platform's
	// federation_api. The child POSTs the acceptance handshake here.
	ParentURL string `json:"parent_url"`
	// AcceptanceToken is the single-use bearer the parent issued. The
	// child includes it in the accept POST.
	AcceptanceToken string `json:"acceptance_token"`
	// SpawnMode is one of "managed_child", "autonomous_peer", or
	// "cluster_member" — the child uses this to know how to configure
	// itself post-handshake (whether to expect cluster_pg credentials,
	// whether parent operator-scope is implicit, etc.).
	SpawnMode string `json:"spawn_mode"`
	// ParentPeerID is the parent-side FederationPeer.id this handshake
	// targets. Surfaced only for log correlation.
	ParentPeerID string `json:"parent_peer_id"`
	// ContractVersion is the social-contract version the parent
	// advertises. The child must support it to complete the handshake.
	ContractVersion string `json:"contract_version"`
}

// ErrNotConfigured is returned by LoadConfig when no federation
// payload is present in fw-cfg — this is the legitimate steady-state
// for a child that wasn't spawned by a parent (e.g. an operator-
// driven manual provision). The agent treats it as a no-op.
var ErrNotConfigured = errors.New("federation: no spawn payload in fw-cfg")

// FwCfgRoot is the default path the child agent reads fw-cfg entries
// from. Overridable via the Config{Root} field on LoadConfig for
// tests + non-standard layouts.
const FwCfgRoot = "/sys/firmware/qemu_fw_cfg/by_name/opt/com.powernode"

// LoadConfig reads the federation spawn payload from fw-cfg under
// root (defaults to FwCfgRoot). Returns ErrNotConfigured when no
// parent_url is present — the legitimate steady-state for a child
// that wasn't spawned by a parent.
func LoadConfig(root string) (*Config, error) {
	if root == "" {
		root = FwCfgRoot
	}

	parentURL, err := readFwCfg(root, "parent_url")
	if err != nil {
		return nil, err
	}
	if parentURL == "" {
		return nil, ErrNotConfigured
	}

	cfg := &Config{ParentURL: parentURL}

	// All other fields are mandatory once parent_url is set —
	// missing them means the parent's seed was incomplete.
	cfg.AcceptanceToken, err = readFwCfg(root, "acceptance_token")
	if err != nil {
		return nil, err
	}
	if cfg.AcceptanceToken == "" {
		return nil, errors.New("federation: parent_url set but acceptance_token missing")
	}

	cfg.SpawnMode, _ = readFwCfg(root, "spawn_mode")
	cfg.ParentPeerID, _ = readFwCfg(root, "parent_peer_id")
	cfg.ContractVersion, _ = readFwCfg(root, "contract_version")
	if cfg.ContractVersion == "" {
		cfg.ContractVersion = "v1"
	}

	return cfg, nil
}

// readFwCfg reads a single fw-cfg blob from its raw file. Empty
// string return on os.ErrNotExist (treated as "key not present"
// rather than an error so callers can check for missing optional
// fields without err-chain handling).
func readFwCfg(root, key string) (string, error) {
	path := filepath.Join(root, key, "raw")
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return "", nil
		}
		return "", err
	}
	return strings.TrimSpace(string(data)), nil
}
