package identity

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"mime/multipart"
	"net/http"
	"net/textproto"
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
	if isMIMEMultipart(raw) {
		// Platform-composed user-data: the v1 document is one part, the
		// operator/template init script another. Select the JSON part.
		part, err := extractProvisionPart(raw)
		if err != nil {
			return nil, err
		}
		if part == "" {
			return nil, ErrNotFound
		}
		// The provision part MUST be a strict v1 document: no legacy shape, no
		// KEY=VALUE, no downgrade. Any refusal is terminal.
		return ParseProvisionDocument([]byte(part))
	}
	if strings.HasPrefix(raw, "{") {
		if isLegacyJSON(raw) {
			return parseUserDataJSON(raw)
		}
		// Anything else that starts with "{" - a v1 document, a "Version"/
		// "VERSION" variant, or a syntax error - is judged by the strict parser
		// and its refusal is TERMINAL (never downgraded to a legacy shape).
		return ParseProvisionDocument([]byte(raw))
	}
	// DEPRECATED (one image release): legacy KEY=VALUE / cmdline forms.
	id, err := parseUserDataKV(raw)
	return id, err
}

func parseUserDataJSON(raw string) (*Identity, error) {
	var doc struct {
		InstanceUUID   string `json:"instance_uuid"`
		BootstrapToken string `json:"bootstrap_token"`
		PlatformURL    string `json:"platform_url"`
		CABundlePEM    string `json:"ca_pem"`
		CAFingerprint  string `json:"ca_fingerprint"`
	}
	if err := json.Unmarshal([]byte(raw), &doc); err != nil {
		return nil, fmt.Errorf("user-data JSON parse: %w", err)
	}
	if doc.InstanceUUID == "" {
		return nil, ErrNotFound
	}
	pin, err := legacyPin(doc.CAFingerprint)
	if err != nil {
		return nil, err
	}
	return &Identity{
		InstanceUUID:   doc.InstanceUUID,
		BootstrapToken: doc.BootstrapToken,
		PlatformURL:    doc.PlatformURL,
		CABundlePEM:    doc.CABundlePEM,
		CAFingerprint:  pin,
	}, nil
}

// isLegacyJSON reports whether raw is a well-formed JSON object with NO key
// that equals "version" in any letter case. Only such objects may use the
// deprecated unversioned shape; everything else goes to the strict parser.
func isLegacyJSON(raw string) bool {
	var probe map[string]json.RawMessage
	if json.Unmarshal([]byte(raw), &probe) != nil {
		return false
	}
	for k := range probe {
		if strings.EqualFold(k, "version") {
			return false
		}
	}
	return true
}

func parseUserDataKV(raw string) (*Identity, error) {
	// Try kernel-cmdline form first (`powernode.instance_uuid=...`),
	// fall back to legacy ID=/KEY=/SERVER=.
	cm := parseCmdline(raw)
	if cm["powernode.instance_uuid"] != "" {
		pin, err := legacyPin(cm["powernode.ca_fingerprint"])
		if err != nil {
			return nil, err
		}
		return &Identity{
			InstanceUUID:   cm["powernode.instance_uuid"],
			BootstrapToken: cm["powernode.bootstrap_token"],
			PlatformURL:    cm["powernode.platform_url"],
			CABundlePEM:    cm["powernode.ca_pem"],
			CAFingerprint:  pin,
		}, nil
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
		return nil, nil
	}
	pin, err := legacyPin(kv["CA_FINGERPRINT"])
	if err != nil {
		return nil, err
	}
	return &Identity{
		InstanceUUID:   kv["ID"],
		BootstrapToken: kv["KEY"],
		PlatformURL:    kv["SERVER"],
		CABundlePEM:    kv["CA_PEM"],
		CAFingerprint:  pin,
	}, nil
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
	// Large enough for a full v1 document (provisionMaxDocBytes) or a multipart
	// envelope around one. An oversized body is an error, never silently
	// truncated into a half document (which would be a terminal refusal).
	body, err := io.ReadAll(io.LimitReader(resp.Body, provisionMultipartMaxBytes+1))
	if err != nil {
		return "", err
	}
	if len(body) > provisionMultipartMaxBytes {
		return "", fmt.Errorf("metadata response larger than %d bytes", provisionMultipartMaxBytes)
	}
	return string(body), nil
}

// errBadStatus marks a non-200 metadata response. Strategies map this to
// ErrNotFound so the resolver moves on to the next cloud.
var errBadStatus = errors.New("metadata service returned non-200")

// provisionPartType is the MIME type of the provisioning-document part in
// platform-composed multipart user-data (System::EnrollmentSeed::JSON_PART_TYPE).
const provisionPartType = "application/x-powernode-provision+json"

func isMIMEMultipart(raw string) bool {
	head := strings.ToLower(raw)
	if len(head) > 256 {
		head = head[:256]
	}
	return strings.HasPrefix(head, "mime-version:") || strings.HasPrefix(head, "content-type: multipart/")
}

// extractProvisionPart returns the body of the provisionPartType part of a
// multipart user-data blob, or "" when there is none (a cloud-init-only blob).
// A malformed multipart envelope is an error, never a silent fall-through.
func extractProvisionPart(raw string) (string, error) {
	if len(raw) > provisionMultipartMaxBytes {
		return "", fmt.Errorf("user-data multipart: larger than %d bytes", provisionMultipartMaxBytes)
	}
	br := bufio.NewReader(strings.NewReader(raw))
	hdr, err := textproto.NewReader(br).ReadMIMEHeader()
	if err != nil && err != io.EOF {
		return "", fmt.Errorf("user-data multipart header: %w", err)
	}
	if len(hdr) > provisionMaxPartHeaders || len(hdr.Get("Content-Type")) > provisionMaxHeaderValue {
		return "", fmt.Errorf("user-data multipart: oversized header block")
	}
	mt, params, err := mime.ParseMediaType(hdr.Get("Content-Type"))
	if err != nil || !strings.HasPrefix(mt, "multipart/") || params["boundary"] == "" {
		return "", fmt.Errorf("user-data multipart: bad Content-Type")
	}
	mr := multipart.NewReader(br, params["boundary"])
	found := ""
	count := 0
	for {
		p, err := mr.NextPart()
		if err == io.EOF {
			return found, nil
		}
		if err != nil {
			return "", fmt.Errorf("user-data multipart: %w", err)
		}
		if len(p.Header) > provisionMaxPartHeaders || len(p.Header.Get("Content-Type")) > provisionMaxHeaderValue {
			return "", fmt.Errorf("user-data multipart: oversized part header")
		}
		pt, _, _ := mime.ParseMediaType(p.Header.Get("Content-Type"))
		if pt != provisionPartType {
			continue
		}
		count++
		if count > 1 {
			return "", fmt.Errorf("user-data multipart: more than one provision part")
		}
		body, err := io.ReadAll(io.LimitReader(p, provisionMaxDocBytes+1))
		if err != nil {
			return "", fmt.Errorf("user-data multipart part: %w", err)
		}
		if len(body) > provisionMaxDocBytes {
			return "", fmt.Errorf("user-data multipart: provision part larger than %d bytes", provisionMaxDocBytes)
		}
		found = strings.TrimSpace(string(body))
		if found == "" {
			return "", fmt.Errorf("user-data multipart: empty provision part")
		}
	}
}

const (
	provisionMultipartMaxBytes = 512 * 1024
	provisionMaxPartHeaders    = 16
	provisionMaxHeaderValue    = 1024
)
