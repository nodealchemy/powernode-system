package identity

import (
	"context"
	"errors"
	"os"
	"strings"
)

// CmdlineStrategy reads identity from kernel command-line parameters. The
// platform's iPXE script + cloud-init userdata both inject identity values
// here as `powernode.<key>=<value>` pairs:
//
//	powernode.instance_uuid=<uuid>
//	powernode.bootstrap_token=<token>
//	powernode.platform_url=https://platform.example.com
//	powernode.ca_pem_url=https://platform.example.com/.well-known/powernode-ca.pem
//
// Reference: Golden Eclipse plan M3 iPXE chainload flow.
type CmdlineStrategy struct {
	// Path defaults to /proc/cmdline; overridable for tests.
	Path string
}

func (s *CmdlineStrategy) Name() string { return "kernel-cmdline" }

func (s *CmdlineStrategy) Discover(ctx context.Context) (*Identity, error) {
	path := s.Path
	if path == "" {
		path = "/proc/cmdline"
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, ErrNotFound
		}
		return nil, err
	}

	params := parseCmdline(string(raw))
	uuid := params["powernode.instance_uuid"]
	if uuid == "" {
		return nil, ErrNotFound
	}

	return &Identity{
		InstanceUUID:   uuid,
		BootstrapToken: params["powernode.bootstrap_token"],
		PlatformURL:    params["powernode.platform_url"],
		CABundlePEM:    params["powernode.ca_pem"],
		CloudProvider:  "kernel-cmdline",
	}, nil
}

// parseCmdline parses /proc/cmdline-style space-separated key=value pairs.
// Values may be quoted (single or double); quotes are stripped. Unquoted
// values continue to the next whitespace.
func parseCmdline(raw string) map[string]string {
	out := map[string]string{}
	tokens := tokenize(strings.TrimSpace(raw))
	for _, t := range tokens {
		eq := strings.IndexByte(t, '=')
		if eq < 0 {
			out[t] = ""
			continue
		}
		key := t[:eq]
		val := t[eq+1:]
		if len(val) >= 2 {
			first := val[0]
			last := val[len(val)-1]
			if (first == '"' || first == '\'') && first == last {
				val = val[1 : len(val)-1]
			}
		}
		out[key] = val
	}
	return out
}

// tokenize splits on whitespace, respecting single-/double-quoted runs.
func tokenize(s string) []string {
	var (
		out      []string
		buf      strings.Builder
		inQuote  byte
	)
	flush := func() {
		if buf.Len() > 0 {
			out = append(out, buf.String())
			buf.Reset()
		}
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case inQuote != 0:
			buf.WriteByte(c)
			if c == inQuote {
				inQuote = 0
			}
		case c == '"' || c == '\'':
			inQuote = c
			buf.WriteByte(c)
		case c == ' ' || c == '\t' || c == '\n':
			flush()
		default:
			buf.WriteByte(c)
		}
	}
	flush()
	return out
}
