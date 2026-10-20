package identity

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

// CmdlineStrategy reads identity from kernel command-line parameters. The
// platform's iPXE script + cloud-init userdata both inject identity values
// here as `powernode.<key>=<value>` pairs:
//
//	powernode.instance_uuid=<uuid>
//	powernode.bootstrap_token=<token>
//	powernode.platform_url=https://platform.example.com
//	powernode.ca_fingerprint=sha256:<64 hex>
//	powernode.ca_pem_url=https://platform.example.com/api/v1/system/netboot/ca.pem
//
// ca_pem_url is fetched only when a well-formed ca_fingerprint pin is also on
// the cmdline, and the bytes are accepted only if a certificate in them matches
// that pin (checkPEMMatchesPin): the pin authenticates the content, so the
// transport need not be authenticated. A mismatch is terminal
// (ErrProvisionRefused). The inline powernode.ca_pem (a PEM cannot survive
// iPXE imgargs / the kernel cmdline, since it has newlines) is still read but
// DEPRECATED, same one-release window as the other legacy sources (see
// provision.go).
//
// Reference: Golden Eclipse plan M3 iPXE chainload flow.
type CmdlineStrategy struct {
	// Path defaults to /proc/cmdline; overridable for tests.
	Path string
	// Client fetches powernode.ca_pem_url. Injectable for tests; nil means a
	// short-timeout default client.
	Client *http.Client
	// FetchBackoff is the initial delay between ca_pem_url attempts (doubled
	// each retry); zero means defaultFetchBackoff. Injectable for tests.
	FetchBackoff time.Duration
}

const (
	// The initramfs network may not be up when the cmdline is first read.
	defaultFetchAttempts = 4
	defaultFetchBackoff  = 500 * time.Millisecond
)

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

	pin, err := legacyPin(params["powernode.ca_fingerprint"])
	if err != nil {
		return nil, err
	}
	caPEM := params["powernode.ca_pem"]
	if caURL := params["powernode.ca_pem_url"]; caURL != "" {
		if pin == "" {
			return nil, refuse("ca_pem_url without a ca_fingerprint pin: refusing to fetch an unauthenticated trust anchor")
		}
		fetched, err := s.fetchCA(ctx, caURL, pin)
		if err != nil {
			return nil, err
		}
		caPEM = fetched
	}
	return &Identity{
		InstanceUUID:   uuid,
		BootstrapToken: params["powernode.bootstrap_token"],
		PlatformURL:    params["powernode.platform_url"],
		CABundlePEM:    caPEM,
		CAFingerprint:  pin,
		CloudProvider:  "kernel-cmdline",
	}, nil
}

// fetchCA downloads the CA PEM (capped at provisionMaxCAPEM) and returns it
// only if it matches pin. Transport failures are retried with backoff within
// ctx (the network may not be up yet); if the fetch still fails the result is
// a TERMINAL refusal: the cmdline asserted a pin, so falling through to a weaker
// source (metadata, a stick, console) would let an L2 attacker who blocks this
// GET enrol the node elsewhere. Content problems are terminal immediately.
func (s *CmdlineStrategy) fetchCA(ctx context.Context, rawURL, pin string) (string, error) {
	u, err := url.Parse(rawURL)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" {
		return "", refuse("ca_pem_url must be an http(s) URL")
	}
	client := s.Client
	if client == nil {
		client = &http.Client{Timeout: 15 * time.Second}
	}
	backoff := s.FetchBackoff
	if backoff <= 0 {
		backoff = defaultFetchBackoff
	}
	var lastErr error
	for attempt := 0; attempt < defaultFetchAttempts; attempt++ {
		if attempt > 0 {
			select {
			case <-ctx.Done():
				return "", refuse("fetch ca_pem_url: %v (last error: %v)", ctx.Err(), lastErr)
			case <-time.After(backoff):
			}
			backoff *= 2
		}
		body, retryable, err := fetchOnce(ctx, client, rawURL)
		if err == nil {
			if len(body) > provisionMaxCAPEM || !printable(string(body), true) {
				return "", refuse("ca_pem_url body too large or not printable")
			}
			if err := checkPEMMatchesPin(body, pin); err != nil {
				return "", refuse("ca_pem_url: %v", err)
			}
			return string(body), nil
		}
		lastErr = err
		if !retryable {
			break
		}
	}
	return "", refuse("fetch ca_pem_url failed, refusing to fall back to an unpinned source: %v", lastErr)
}

// fetchOnce performs one GET. retryable is true for transport/status/read errors.
func fetchOnce(ctx context.Context, client *http.Client, rawURL string) ([]byte, bool, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, false, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, true, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, true, fmt.Errorf("status %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, provisionMaxCAPEM+1))
	if err != nil {
		return nil, true, err
	}
	return body, false, nil
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
		out     []string
		buf     strings.Builder
		inQuote byte
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
