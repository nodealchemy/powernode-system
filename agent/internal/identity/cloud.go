package identity

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// MetadataClient abstracts a cloud's metadata service. Implementations must
// be cheap and fail-fast when the agent isn't actually running on that
// cloud (the resolver will try multiple clients in sequence; slow probes
// would multiply boot latency).
type MetadataClient interface {
	Name() string
	// Detect returns true if the metadata service is reachable. Should
	// time out within ~1s on a non-matching cloud.
	Detect(ctx context.Context) bool
	// UserData fetches the powernode-identity payload from the cloud's
	// user-data endpoint. Format is the same as /etc/identity.cfg or
	// kernel cmdline (key=value lines, optionally wrapped in JSON).
	UserData(ctx context.Context) (string, error)
}

// CloudStrategy adapts a MetadataClient to the Strategy interface. The
// resolver runs the client's Detect() first to short-circuit non-matches
// fast, then fetches + parses user data.
type CloudStrategy struct {
	Client MetadataClient
}

func (s *CloudStrategy) Name() string {
	if s.Client == nil {
		return "cloud-unknown"
	}
	return "cloud-" + s.Client.Name()
}

func (s *CloudStrategy) Discover(ctx context.Context) (*Identity, error) {
	if s.Client == nil || !s.Client.Detect(ctx) {
		return nil, ErrNotFound
	}
	data, err := s.Client.UserData(ctx)
	if err != nil {
		return nil, err
	}
	id, err := parseUserData(data)
	if err != nil {
		return nil, err
	}
	if id == nil || id.InstanceUUID == "" {
		return nil, ErrNotFound
	}
	id.CloudProvider = s.Client.Name()
	return id, nil
}

// parseUserData accepts either:
//  1. Shell-style: ID=... KEY=... SERVER=...        (legacy identity.cfg)
//  2. Kernel-style: powernode.instance_uuid=...     (cmdline-shaped)
//  3. JSON: {"instance_uuid": "...", "bootstrap_token": "...", ...}
//
// All three normalize to the same Identity fields.
func parseUserData(raw string) (*Identity, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, ErrNotFound
	}
	if strings.HasPrefix(raw, "{") {
		return parseUserDataJSON(raw)
	}
	return parseUserDataKV(raw), nil
}

func parseUserDataJSON(raw string) (*Identity, error) {
	var doc struct {
		InstanceUUID   string `json:"instance_uuid"`
		BootstrapToken string `json:"bootstrap_token"`
		PlatformURL    string `json:"platform_url"`
		CABundlePEM    string `json:"ca_pem"`
	}
	if err := json.Unmarshal([]byte(raw), &doc); err != nil {
		return nil, fmt.Errorf("user-data JSON parse: %w", err)
	}
	if doc.InstanceUUID == "" {
		return nil, ErrNotFound
	}
	return &Identity{
		InstanceUUID:   doc.InstanceUUID,
		BootstrapToken: doc.BootstrapToken,
		PlatformURL:    doc.PlatformURL,
		CABundlePEM:    doc.CABundlePEM,
	}, nil
}

func parseUserDataKV(raw string) *Identity {
	// Try kernel-cmdline form first (`powernode.instance_uuid=...`),
	// fall back to legacy ID=/KEY=/SERVER=.
	cm := parseCmdline(raw)
	if cm["powernode.instance_uuid"] != "" {
		return &Identity{
			InstanceUUID:   cm["powernode.instance_uuid"],
			BootstrapToken: cm["powernode.bootstrap_token"],
			PlatformURL:    cm["powernode.platform_url"],
			CABundlePEM:    cm["powernode.ca_pem"],
		}
	}

	// Legacy shell-style: parse ID=, KEY=, SERVER= per-line.
	kv := map[string]string{}
	for _, line := range strings.Split(raw, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimPrefix(line, "export ")
		eq := strings.IndexByte(line, '=')
		if eq < 0 {
			continue
		}
		kv[strings.TrimSpace(line[:eq])] = stripQuotes(strings.TrimSpace(line[eq+1:]))
	}
	if kv["ID"] == "" {
		return nil
	}
	return &Identity{
		InstanceUUID:   kv["ID"],
		BootstrapToken: kv["KEY"],
		PlatformURL:    kv["SERVER"],
		CABundlePEM:    kv["CA_PEM"],
	}
}

// httpDo is the shared transport for cloud metadata calls. Aggressive
// timeouts so a probe against a wrong cloud fails fast.
func httpDo(ctx context.Context, method, url string, headers map[string]string) (string, error) {
	client := &http.Client{Timeout: 1500 * time.Millisecond}
	req, err := http.NewRequestWithContext(ctx, method, url, http.NoBody)
	if err != nil {
		return "", err
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("metadata service returned %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	if err != nil {
		return "", err
	}
	return string(body), nil
}

// errBadStatus marks a non-200 metadata response. Strategies map this to
// ErrNotFound so the resolver moves on to the next cloud.
var errBadStatus = errors.New("metadata service returned non-200")
