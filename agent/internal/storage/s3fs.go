package storage

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// MountObject covers the cloud object-storage recipes — s3fs, gcsfuse, and
// rclone (Azure Blob). Egress uses the node's native interface, not SDWAN.
//
// It fetches the per-instance credential, writes the recipe-specific config
// file (s3fs ~/.passwd-s3fs / gcsfuse key.json / rclone .conf) with mode 0600
// onto tmpfs, appends the matching mount-helper option, and starts a systemd
// .mount unit whose fs-type is the FUSE driver (fuse.s3fs / gcsfuse / rclone).
//
// Schemas MUST stay in sync with the providers' node_mount_recipe +
// issue_node_credential (s3_storage / gcs_storage / azure_storage).
func MountObject(ctx context.Context, runner mount.Runner, client httpGetter, task *MountTask) error {
	if err := os.MkdirAll(task.MountPath, 0o755); err != nil {
		return fmt.Errorf("mkdir mount path %s: %w", task.MountPath, err)
	}

	payload, _, err := FetchCredential(client, task.Credential.URL)
	if err != nil {
		return fmt.Errorf("fetch object credential: %w", err)
	}

	plan, err := objectMountPlan(payload, task)
	if err != nil {
		return err
	}

	if err := os.MkdirAll(MountCredsDir, 0o700); err != nil {
		return fmt.Errorf("mkdir %s: %w", MountCredsDir, err)
	}
	for _, f := range plan.files {
		if err := os.WriteFile(f.path, []byte(f.contents), f.mode); err != nil {
			return fmt.Errorf("write object config %s: %w", f.path, err)
		}
	}

	// task.Options already carries the platform-combined recipe options
	// (_netdev, allow_other, …); append only the mount-helper-specific extras.
	task.Options = append(task.Options, plan.options...)
	task.SystemdType = plan.fsType
	task.SystemdWhat = plan.what

	if err := WriteMountUnit(ctx, runner, task); err != nil {
		return err
	}
	return StartMountUnit(ctx, runner, task.UnitName)
}

// objectFile is a transient credential/config file to stage on tmpfs (0600).
type objectFile struct {
	path     string
	mode     os.FileMode
	contents string
}

// objectPlan is the pure, testable derivation of how to mount an object recipe:
// the systemd fs-type + What, the extra mount options, and the config files.
type objectPlan struct {
	fsType  string
	what    string
	options []string
	files   []objectFile
}

func objectMountPlan(payload *CredentialPayload, task *MountTask) (*objectPlan, error) {
	credID := task.Credential.ID

	switch task.Recipe.Type {
	case "s3fs":
		if payload.AccessKeyID == "" || payload.SecretAccessKey == "" {
			return nil, fmt.Errorf("s3fs credential missing access_key_id/secret_access_key")
		}
		passwd := filepath.Join(MountCredsDir, credID+".passwd-s3fs")
		// s3fs ~/.passwd-s3fs format is "ACCESS_KEY:SECRET_KEY". (Temporary STS
		// session tokens are not expressible in the passwd file; the static-key
		// path leaves SessionToken empty — token-based mounts are a follow-up.)
		contents := payload.AccessKeyID + ":" + payload.SecretAccessKey + "\n"
		return &objectPlan{
			fsType:  "fuse.s3fs",
			what:    task.Recipe.Source, // bucket[/prefix]
			options: []string{"passwd_file=" + passwd},
			files:   []objectFile{{path: passwd, mode: 0o600, contents: contents}},
		}, nil

	case "gcsfuse":
		if payload.CredentialsJSON == "" {
			return nil, fmt.Errorf("gcsfuse credential missing credentials_json")
		}
		key := filepath.Join(MountCredsDir, credID+".gcs.json")
		return &objectPlan{
			fsType:  "gcsfuse",
			what:    task.Recipe.Source, // bucket
			options: []string{"key_file=" + key},
			files:   []objectFile{{path: key, mode: 0o600, contents: payload.CredentialsJSON}},
		}, nil

	case "rclone":
		if payload.AccountName == "" || payload.AccountKey == "" {
			return nil, fmt.Errorf("rclone credential missing account_name/account_key")
		}
		conf := filepath.Join(MountCredsDir, credID+".rclone.conf")
		const remote = "powernode"
		// Recipe source is "<account>/<container>"; rclone's What is "<remote>:<container>".
		container := task.Recipe.Source
		if idx := strings.IndexByte(container, '/'); idx >= 0 {
			container = container[idx+1:]
		}
		contents := fmt.Sprintf("[%s]\ntype = azureblob\naccount = %s\nkey = %s\n",
			remote, payload.AccountName, payload.AccountKey)
		return &objectPlan{
			fsType:  "rclone",
			what:    remote + ":" + container,
			options: []string{"config=" + conf},
			files:   []objectFile{{path: conf, mode: 0o600, contents: contents}},
		}, nil

	default:
		return nil, fmt.Errorf("unsupported object recipe type: %s", task.Recipe.Type)
	}
}
