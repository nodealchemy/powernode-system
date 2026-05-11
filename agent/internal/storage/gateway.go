package storage

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// ProvisionGateway sets up a Shape 2 gateway powernode:
//
//   1. mkdir -p ReExportPath
//   2. mount upstream NFS at ReExportPath (plaintext in v1; v2 wraps with stunnel/tlshd)
//   3. write a systemd .mount unit so the upstream mount survives reboot
//   4. write the re-export line to /etc/exports
//   5. exportfs -ra to apply
//   6. ensure nfs-kernel-server is active
//
// Per-client ACLs land separately via the storage.exports.apply task.
// This task only owns the re-export base.
func ProvisionGateway(ctx context.Context, runner mount.Runner, task *GatewayProvisionTask) error {
	if err := os.MkdirAll(task.ReExportPath, 0o755); err != nil {
		return fmt.Errorf("mkdir %s: %w", task.ReExportPath, err)
	}

	if err := writeGatewayMountUnit(task); err != nil {
		return err
	}
	if err := runner.Run(ctx, "systemctl", "daemon-reload"); err != nil {
		return fmt.Errorf("systemctl daemon-reload: %w", err)
	}
	if err := runner.Run(ctx, "systemctl", "start", task.GatewayUnitName); err != nil {
		return fmt.Errorf("systemctl start %s: %w", task.GatewayUnitName, err)
	}

	if err := writeReExportLine(task); err != nil {
		return err
	}
	if err := runner.Run(ctx, "exportfs", "-ra"); err != nil {
		return fmt.Errorf("exportfs -ra: %w", err)
	}
	// Ensure service running (no-op if already active).
	_ = runner.Run(ctx, "systemctl", "restart", "nfs-kernel-server")
	return nil
}

// DeprovisionGateway reverses ProvisionGateway.
func DeprovisionGateway(ctx context.Context, runner mount.Runner, task *GatewayDeprovisionTask) error {
	if err := removeReExportLine(task.StorageID, task.ReExportPath); err != nil {
		return err
	}
	_ = runner.Run(ctx, "exportfs", "-ra")

	_ = runner.Run(ctx, "systemctl", "stop", task.GatewayUnitName)
	path := filepath.Join(SystemdUnitDir, task.GatewayUnitName)
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("remove gateway unit: %w", err)
	}
	return runner.Run(ctx, "systemctl", "daemon-reload")
}

func writeGatewayMountUnit(task *GatewayProvisionTask) error {
	opts := strings.Join(task.UpstreamMountOptions, ",")
	if opts == "" {
		opts = "vers=4.2,proto=tcp,hard"
	}
	unit := fmt.Sprintf(`[Unit]
Description=Powernode gateway upstream mount for storage %s

[Mount]
What=%s:%s
Where=%s
Type=nfs4
Options=%s

[Install]
WantedBy=multi-user.target
`, task.StorageID, task.UpstreamSourceHost, task.UpstreamExportPath, task.ReExportPath, opts)

	path := filepath.Join(SystemdUnitDir, task.GatewayUnitName)
	if err := os.WriteFile(path, []byte(unit), 0o644); err != nil {
		return fmt.Errorf("write gateway unit %s: %w", path, err)
	}
	return nil
}

// reExportMarker is what we grep for in /etc/exports to find our
// managed line. Storage ID makes it unique per gateway.
func reExportMarker(storageID string) string {
	return fmt.Sprintf("# powernode-storage-gateway %s", storageID)
}

func writeReExportLine(task *GatewayProvisionTask) error {
	exportsPath := "/etc/exports"
	contents, err := os.ReadFile(exportsPath)
	if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("read %s: %w", exportsPath, err)
	}

	marker := reExportMarker(task.StorageID)
	// Drop any existing entry for this storage so we don't accumulate.
	filtered := dropMarkerBlock(string(contents), marker)

	block := fmt.Sprintf("%s\n%s *(rw,fsid=%s,no_subtree_check,no_root_squash,sec=sys,insecure)\n",
		marker, task.ReExportPath, task.FSID,
	)
	return os.WriteFile(exportsPath, []byte(filtered+block), 0o644)
}

func removeReExportLine(storageID, _ string) error {
	exportsPath := "/etc/exports"
	contents, err := os.ReadFile(exportsPath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("read %s: %w", exportsPath, err)
	}
	marker := reExportMarker(storageID)
	filtered := dropMarkerBlock(string(contents), marker)
	return os.WriteFile(exportsPath, []byte(filtered), 0o644)
}

// dropMarkerBlock removes the marker line + the next non-blank line
// (our two-line block). Conservative: leaves everything else alone.
func dropMarkerBlock(contents, marker string) string {
	lines := strings.Split(contents, "\n")
	out := make([]string, 0, len(lines))
	skip := 0
	for _, line := range lines {
		if skip > 0 {
			skip--
			continue
		}
		if strings.HasPrefix(strings.TrimSpace(line), marker) {
			skip = 1
			continue
		}
		out = append(out, line)
	}
	return strings.Join(out, "\n")
}
