package enroll

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// EnrolledIdentity is what the agent has after a successful enrollment:
// a private key (held in memory + on disk), the platform-issued cert + CA
// chain, and metadata identifying the instance.
type EnrolledIdentity struct {
	Keypair       *Keypair
	CertPEM       []byte
	CAChainPEM    []byte
	CABundlePEM   []byte // platform's TLS verification chain (from identity)
	InstanceID    string
	MTLSSubject   string
	NotAfter      time.Time
	CertificateID string
	// InstanceToken is the legacy-path JWT the platform issues alongside the
	// mTLS cert. Used as Authorization: Bearer in environments where the
	// reverse proxy isn't doing mTLS termination yet (dev / pre-M0.P).
	InstanceToken string
}

// Client speaks to the platform's /node_api/enroll endpoint.
//
//	c := &Client{PlatformURL: "https://platform.example.com", CABundlePEM: caPEM}
//	enrolled, err := c.Enroll(ctx, EnrollRequest{...})
type Client struct {
	// PlatformURL is the base URL of the Powernode control plane.
	// Required.
	PlatformURL string
	// CABundlePEM is the PEM-encoded CA chain the platform's TLS cert
	// chains up to. Required (we never accept self-signed or unverified
	// platform certs during enrollment — that's the whole point of
	// embedding this in cloud-init / iPXE).
	CABundlePEM []byte
	// AgentVersion is reported back to the platform so operators can
	// correlate boot events with agent releases.
	AgentVersion string
	// HTTPClient is overridable for tests; nil means build-on-demand
	// using the supplied CABundlePEM.
	HTTPClient *http.Client
}

// EnrollRequest carries the payload the platform expects.
type EnrollRequest struct {
	BootstrapToken string
	Subject        string // typically the NodeInstance UUID
	DMIUUID        string // optional; from SMBIOS if available
}

// EnrollResponse mirrors the platform's render_success body:
//
//	{ "success": true, "data": { "cert_pem": "...", "ca_chain_pem": "...", ... } }
type EnrollResponse struct {
	Success bool `json:"success"`
	Data    struct {
		CertPEM       string `json:"cert_pem"`
		CAChainPEM    string `json:"ca_chain_pem"`
		InstanceID    string `json:"instance_id"`
		MTLSSubject   string `json:"mtls_subject"`
		NotAfter      string `json:"not_after"`
		CertificateID string `json:"certificate_id"`
		InstanceToken string `json:"instance_token"`
	} `json:"data"`
	Error string `json:"error,omitempty"`
}

// Enroll runs the full bootstrap-token → mTLS cert exchange and returns
// the EnrolledIdentity ready to persist + use.
func (c *Client) Enroll(ctx context.Context, req EnrollRequest) (*EnrolledIdentity, error) {
	if c.PlatformURL == "" {
		return nil, errors.New("enroll.Client: PlatformURL required")
	}
	if len(c.CABundlePEM) == 0 {
		return nil, errors.New("enroll.Client: CABundlePEM required")
	}
	if req.BootstrapToken == "" || req.Subject == "" {
		return nil, errors.New("enroll: BootstrapToken and Subject required")
	}

	// Local key + CSR
	kp, err := GenerateKeypair()
	if err != nil {
		return nil, fmt.Errorf("keygen: %w", err)
	}
	csrPEM, err := BuildCSR(kp, req.Subject)
	if err != nil {
		return nil, fmt.Errorf("csr: %w", err)
	}

	// Build the request body
	body := map[string]string{
		"bootstrap_token": req.BootstrapToken,
		"csr_pem":         string(csrPEM),
		"agent_version":   c.AgentVersion,
	}
	if req.DMIUUID != "" {
		body["dmi_uuid"] = req.DMIUUID
	}
	bodyJSON, err := json.Marshal(body)
	if err != nil {
		return nil, fmt.Errorf("marshal request: %w", err)
	}

	// HTTP client with the supplied CA bundle pinned.
	client := c.HTTPClient
	if client == nil {
		client, err = c.buildHTTPClient()
		if err != nil {
			return nil, err
		}
	}

	url := strings.TrimRight(c.PlatformURL, "/") + "/api/v1/system/node_api/enroll"
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(bodyJSON))
	if err != nil {
		return nil, err
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Accept", "application/json")

	resp, err := client.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("enroll POST: %w", err)
	}
	defer resp.Body.Close()
	respBody, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, fmt.Errorf("read enroll response: %w", err)
	}

	if resp.StatusCode == http.StatusUnauthorized {
		return nil, fmt.Errorf("enroll: bootstrap token rejected (401): %s", string(respBody))
	}
	if resp.StatusCode == 422 || resp.StatusCode == http.StatusUnprocessableEntity {
		return nil, fmt.Errorf("enroll: validation failed (%d): %s", resp.StatusCode, string(respBody))
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("enroll: unexpected status %d: %s", resp.StatusCode, string(respBody))
	}

	var er EnrollResponse
	if err := json.Unmarshal(respBody, &er); err != nil {
		return nil, fmt.Errorf("decode enroll response: %w", err)
	}
	if !er.Success {
		return nil, fmt.Errorf("enroll: platform returned success=false: %s", er.Error)
	}
	if er.Data.CertPEM == "" || er.Data.CAChainPEM == "" {
		return nil, errors.New("enroll: response missing cert_pem or ca_chain_pem")
	}

	notAfter, err := time.Parse(time.RFC3339, er.Data.NotAfter)
	if err != nil {
		// Don't fail enrollment over a parse error — just leave NotAfter zero.
		notAfter = time.Time{}
	}

	return &EnrolledIdentity{
		Keypair:       kp,
		CertPEM:       []byte(er.Data.CertPEM),
		CAChainPEM:    []byte(er.Data.CAChainPEM),
		CABundlePEM:   c.CABundlePEM,
		InstanceID:    er.Data.InstanceID,
		MTLSSubject:   er.Data.MTLSSubject,
		NotAfter:      notAfter,
		CertificateID: er.Data.CertificateID,
		InstanceToken: er.Data.InstanceToken,
	}, nil
}

// buildHTTPClient returns an http.Client whose RootCAs are the supplied
// CABundlePEM. This is the security-critical bit: the agent will refuse
// to talk to a platform that doesn't chain up to the bundled CA.
func (c *Client) buildHTTPClient() (*http.Client, error) {
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(c.CABundlePEM) {
		return nil, errors.New("CABundlePEM contains no parseable certificates")
	}
	return &http.Client{
		Timeout: 30 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{
				RootCAs:    pool,
				MinVersion: tls.VersionTLS13, // platform-wide policy
			},
			ResponseHeaderTimeout: 10 * time.Second,
		},
	}, nil
}
