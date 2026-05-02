package identity

import (
	"bufio"
	"context"
	"errors"
	"os"
	"strings"
)

// LocalIdentityStrategy reads identity from a sourced shell-style config
// file. This is the legacy fallback path
// (~/Drive/Projects/powernode-bootstrap/scripts/ipn_init_identity), retained
// for bare-metal nodes whose boot device carries an /etc/identity.cfg.
//
// File format:
//
//	ID=instance-uuid-here
//	KEY=bootstrap-token-here
//	SERVER=https://platform.example.com
//	CA_PEM_FILE=/etc/powernode-ca.pem
//
// Comments (lines starting with `#`) and blank lines are ignored. Values
// may be wrapped in single or double quotes.
type LocalIdentityStrategy struct {
	Path string
}

func (s *LocalIdentityStrategy) Name() string { return "local-identity-cfg" }

func (s *LocalIdentityStrategy) Discover(ctx context.Context) (*Identity, error) {
	if s.Path == "" {
		return nil, ErrNotFound
	}
	f, err := os.Open(s.Path)
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
		// Optional 'export' prefix
		line = strings.TrimPrefix(line, "export ")
		eq := strings.IndexByte(line, '=')
		if eq < 0 {
			continue
		}
		key := strings.TrimSpace(line[:eq])
		val := strings.TrimSpace(line[eq+1:])
		val = stripQuotes(val)
		kv[key] = val
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}

	uuid := kv["ID"]
	if uuid == "" {
		return nil, ErrNotFound
	}

	id := &Identity{
		InstanceUUID:   uuid,
		BootstrapToken: kv["KEY"],
		PlatformURL:    kv["SERVER"],
		CloudProvider:  "local-identity-cfg",
	}
	if pemFile := kv["CA_PEM_FILE"]; pemFile != "" {
		if data, err := os.ReadFile(pemFile); err == nil {
			id.CABundlePEM = string(data)
		}
	}
	return id, nil
}

func stripQuotes(s string) string {
	if len(s) < 2 {
		return s
	}
	first := s[0]
	last := s[len(s)-1]
	if (first == '"' || first == '\'') && first == last {
		return s[1 : len(s)-1]
	}
	return s
}
