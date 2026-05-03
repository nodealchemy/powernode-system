package identity

import (
	"bufio"
	"context"
	"errors"
	"os"
	"strings"
)

// BootIdentityStrategy reads identity from a file in the FAT32 boot
// partition. This is the physical-device enrollment path:
//
//   - Operator flashes a generic Powernode disk image onto an SD card
//     / USB stick. The image's boot partition contains an identity.cfg
//     placeholder with the platform URL + CA PEM file, but no bootstrap
//     token (the device hasn't been claimed yet).
//   - Agent boots, this strategy reads identity.cfg, returns the
//     PlatformURL + CABundlePEM. The downstream ClaimStrategy completes
//     the loop by polling /node_api/claim until an operator confirms.
//
// File format mirrors LocalIdentityStrategy (shell-style KEY=VALUE):
//
//	# pre-flash placeholder; agent will fill in token via claim flow
//	ID=
//	KEY=
//	SERVER=https://platform.example.com
//	CA_PEM_FILE=/boot/powernode-ca.pem
//
// The strategy succeeds (returns a partial Identity, no error) even
// when ID + KEY are empty, as long as SERVER is set — the resolver
// chain interprets this as "boot config present, claim flow needed."
//
// Plan: docs/plans/wondrous-yawning-anchor.md §4.
type BootIdentityStrategy struct {
	// Path to the identity config file. Defaults to /boot/identity.cfg
	// when empty. The dracut hook (init-powernode.sh) mounts the FAT32
	// boot partition to /boot before invoking the agent.
	Path string
}

func (s *BootIdentityStrategy) Name() string { return "boot-identity-cfg" }

func (s *BootIdentityStrategy) Discover(ctx context.Context) (*Identity, error) {
	path := s.Path
	if path == "" {
		path = "/boot/identity.cfg"
	}

	f, err := os.Open(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	defer f.Close()

	kv := map[string]string{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if i := strings.IndexByte(line, '='); i > 0 {
			k := strings.TrimSpace(line[:i])
			v := strings.TrimSpace(line[i+1:])
			v = strings.Trim(v, `"'`)
			kv[k] = v
		}
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}

	// SERVER is the only required field — without it we can't even
	// reach the claim endpoint, so signal "not found" to the resolver.
	server := kv["SERVER"]
	if server == "" {
		return nil, ErrNotFound
	}

	id := &Identity{
		InstanceUUID:   kv["ID"],
		BootstrapToken: kv["KEY"],
		PlatformURL:    server,
	}

	// CA can be inline or referenced via CA_PEM_FILE. Inline takes
	// precedence; file fallback is the more common case (cmdline.txt
	// has a length budget, but the FAT partition has plenty of room
	// for a separate ca.pem alongside identity.cfg).
	if inline := kv["CA_PEM"]; inline != "" {
		id.CABundlePEM = inline
	} else if caFile := kv["CA_PEM_FILE"]; caFile != "" {
		if data, err := os.ReadFile(caFile); err == nil {
			id.CABundlePEM = string(data)
		}
	}

	return id, nil
}
