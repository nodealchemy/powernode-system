package identity

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
)

// FwCfgStrategy reads identity from QEMU's virtio-fw-cfg pseudo-filesystem
// at /sys/firmware/qemu_fw_cfg/by_name/. Powernode's libvirt provider
// (System::Providers::LocalQemuProvider in the platform extension) injects
// each identity value under the path:
//
//	/sys/firmware/qemu_fw_cfg/by_name/opt/com.powernode/instance_uuid/raw
//	/sys/firmware/qemu_fw_cfg/by_name/opt/com.powernode/bootstrap_token/raw
//	/sys/firmware/qemu_fw_cfg/by_name/opt/com.powernode/platform_url/raw
//	/sys/firmware/qemu_fw_cfg/by_name/opt/com.powernode/ca_pem/raw
//
// The `com.powernode` prefix is QEMU's reverse-DNS convention for opt-namespace
// fw-cfg entries. The platform's CloudSeed writes them under this path.
//
// This is the cleanest first-boot identity transport for QEMU/KVM (no
// network required, no metadata service, no boot-disk formatting).
//
// Reference: Golden Eclipse plan M4 — local_qemu provider seed assembly.
type FwCfgStrategy struct {
	// Root defaults to the standard fw_cfg path; overridable for tests.
	Root string
}

func (s *FwCfgStrategy) Name() string { return "virtio-fw-cfg" }

func (s *FwCfgStrategy) Discover(ctx context.Context) (*Identity, error) {
	root := s.Root
	if root == "" {
		root = "/sys/firmware/qemu_fw_cfg/by_name/opt/com.powernode"
	}

	uuid, err := readFwCfg(root, "instance_uuid")
	if err != nil {
		return nil, err
	}
	if uuid == "" {
		return nil, ErrNotFound
	}

	id := &Identity{
		InstanceUUID:  uuid,
		CloudProvider: "libvirt-fw-cfg",
	}
	id.BootstrapToken, _ = readFwCfg(root, "bootstrap_token")
	id.PlatformURL, _ = readFwCfg(root, "platform_url")
	id.CABundlePEM, _ = readFwCfg(root, "ca_pem")
	return id, nil
}

func readFwCfg(root, key string) (string, error) {
	path := filepath.Join(root, key, "raw")
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return "", ErrNotFound
		}
		return "", err
	}
	return strings.TrimSpace(string(data)), nil
}
