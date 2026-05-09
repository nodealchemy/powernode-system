package runtime

import (
	"context"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/enroll"
	"github.com/nodealchemy/powernode-system/agent/internal/transport"
)

// defaultRefreshAt is the fraction of cert lifetime past which the
// rotator triggers a refresh. 0.75 = refresh at 75% of cert lifetime
// — gives a 25% safety margin for the platform endpoint to be
// reachable + the new cert to take effect before NotAfter.
const defaultRefreshAt = 0.75

// defaultCheckInterval is how often the rotation loop wakes up to
// reconsider. 6 hours is short enough that even pathologically short
// lifetimes (e.g., 24h test certs) get caught well before expiry.
const defaultCheckInterval = 6 * time.Hour

// rotationEndpoint is the platform action that re-issues a cert
// authenticated by the existing mTLS cert. Bootstrap tokens are
// single-use and cannot be reused for refresh.
const rotationEndpoint = "/api/v1/system/node_api/enroll/refresh"

// CertRotator watches the agent's mTLS cert lifetime and refreshes
// it before expiry. The refreshed cert authenticates via the
// EXISTING cert, not a bootstrap token (bootstrap tokens are
// single-use). On success, the new cert is atomically written to
// disk and SwappableClient.Swap is called so all subsequent
// requests use the fresh material.
//
// In-flight requests on the old transport complete cleanly: both
// old and new certs verify against the same CA chain until the
// old's NotAfter, so there's no failure window.
type CertRotator struct {
	// PKIPaths describes where on disk the cert/key/chain live.
	PKIPaths enroll.PKIPaths
	// PlatformURL is the base URL for the rotation endpoint.
	PlatformURL string
	// Transport is the SwappableClient holding the current mTLS-
	// configured *transport.Client. The rotator uses it to authenticate
	// the refresh call AND to publish the new client after rotation.
	Transport *transport.SwappableClient
	// Subject is the CN of the new CSR. Typically the NodeInstance UUID
	// (matches what the platform's IntervalCaService set on the
	// initial enrollment cert).
	Subject string
	// AgentVersion is reported in the rotation request body.
	AgentVersion string
	// RefreshAt is the fraction of cert lifetime past which to rotate.
	// 0 = use defaultRefreshAt (0.75).
	RefreshAt float64
	// CheckInterval is the gap between rotation checks. 0 = use
	// defaultCheckInterval (6h).
	CheckInterval time.Duration
	// OnError surfaces non-fatal rotation errors to the service-level
	// observer. Errors don't stop the loop — a network blip just
	// means we retry next interval.
	OnError func(stage string, err error)
	// Now is overrideable for tests; nil = time.Now.
	Now func() time.Time
	// BuildTransport is overrideable for tests so they don't need to
	// mint a fully-CA-signed cert chain matching the rotator's locally-
	// generated keypair. Default = transport.LoadFromPKIDir.
	BuildTransport func(platformURL string, paths enroll.PKIPaths) (*transport.Client, error)
}

// NewCertRotator validates required fields and returns a rotator with
// defaults filled in.
func NewCertRotator(r *CertRotator) (*CertRotator, error) {
	if r == nil {
		return nil, errors.New("NewCertRotator: nil receiver")
	}
	if r.PKIPaths.Cert == "" {
		return nil, errors.New("NewCertRotator: PKIPaths.Cert required")
	}
	if r.PlatformURL == "" {
		return nil, errors.New("NewCertRotator: PlatformURL required")
	}
	if r.Transport == nil {
		return nil, errors.New("NewCertRotator: Transport required")
	}
	if r.Subject == "" {
		return nil, errors.New("NewCertRotator: Subject required")
	}
	if r.RefreshAt <= 0 || r.RefreshAt >= 1 {
		r.RefreshAt = defaultRefreshAt
	}
	if r.CheckInterval == 0 {
		r.CheckInterval = defaultCheckInterval
	}
	if r.OnError == nil {
		r.OnError = func(string, error) {}
	}
	if r.Now == nil {
		r.Now = time.Now
	}
	if r.BuildTransport == nil {
		r.BuildTransport = transport.LoadFromPKIDir
	}
	return r, nil
}

// Run blocks until ctx is canceled. Each tick: check cert expiry; if
// past RefreshAt fraction of lifetime, rotate. Errors stay in
// OnError; the loop never crashes.
func (r *CertRotator) Run(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}
		if err := r.checkAndRotate(ctx); err != nil {
			r.OnError("cert_rotation", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(r.CheckInterval):
		}
	}
}

// CheckAndRotate is the synchronous entry point — tests + an
// admin-triggered "rotate now" CLI command can call this directly.
func (r *CertRotator) CheckAndRotate(ctx context.Context) error {
	return r.checkAndRotate(ctx)
}

// checkAndRotate reads the current cert, decides whether to rotate,
// and runs the rotation if needed. Returns nil when no rotation is
// needed OR when rotation succeeded; non-nil error on any failure.
func (r *CertRotator) checkAndRotate(ctx context.Context) error {
	cert, err := r.readLeafCert()
	if err != nil {
		return fmt.Errorf("read cert: %w", err)
	}
	if r.Now().Before(refreshDeadline(cert, r.RefreshAt)) {
		return nil
	}
	return r.rotate(ctx)
}

// rotate generates a fresh keypair, posts the CSR to /enroll/refresh
// (authenticated by the EXISTING mTLS cert), persists the new
// material, and swaps the transport.
func (r *CertRotator) rotate(ctx context.Context) error {
	kp, err := enroll.GenerateKeypair()
	if err != nil {
		return fmt.Errorf("genkey: %w", err)
	}
	csrPEM, err := enroll.BuildCSR(kp, r.Subject)
	if err != nil {
		return fmt.Errorf("build CSR: %w", err)
	}

	body, err := json.Marshal(map[string]string{
		"csr_pem":       string(csrPEM),
		"agent_version": r.AgentVersion,
	})
	if err != nil {
		return fmt.Errorf("marshal body: %w", err)
	}

	resp, err := r.Transport.PostJSON(rotationEndpoint, body)
	if err != nil {
		return fmt.Errorf("post %s: %w", rotationEndpoint, err)
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("rotation status %d: %s", resp.StatusCode, strings.TrimSpace(string(respBody)))
	}

	var er enroll.EnrollResponse
	if err := json.Unmarshal(respBody, &er); err != nil {
		return fmt.Errorf("decode response: %w", err)
	}
	if !er.Success {
		return fmt.Errorf("rotation: success=false: %s", er.Error)
	}
	if er.Data.CertPEM == "" {
		return errors.New("rotation: response missing cert_pem")
	}

	// Build the persisted identity. Reuse the existing CA bundle
	// (from disk) rather than expecting the rotation response to
	// re-include it — the bundle doesn't change during a rotation.
	caBundle, _ := os.ReadFile(r.PKIPaths.CABundle)

	notAfter, _ := time.Parse(time.RFC3339, er.Data.NotAfter)
	id := &enroll.EnrolledIdentity{
		Keypair:       kp,
		CertPEM:       []byte(er.Data.CertPEM),
		CAChainPEM:    []byte(er.Data.CAChainPEM),
		CABundlePEM:   caBundle,
		InstanceID:    er.Data.InstanceID,
		MTLSSubject:   er.Data.MTLSSubject,
		NotAfter:      notAfter,
		CertificateID: er.Data.CertificateID,
		InstanceToken: er.Data.InstanceToken,
	}
	if err := enroll.Save(id, r.PKIPaths); err != nil {
		return fmt.Errorf("save rotated identity: %w", err)
	}

	// Build a fresh transport.Client backed by the new PKI material
	// and atomically publish it via the SwappableClient. In-flight
	// requests on the old client complete cleanly because the old
	// cert remains valid until its NotAfter.
	newClient, err := r.BuildTransport(r.PlatformURL, r.PKIPaths)
	if err != nil {
		return fmt.Errorf("load new transport: %w", err)
	}
	r.Transport.Swap(newClient)

	_ = ctx // ctx reserved for future cancelable PostJSON
	return nil
}

// readLeafCert reads + parses the leaf cert at PKIPaths.Cert.
func (r *CertRotator) readLeafCert() (*x509.Certificate, error) {
	body, err := os.ReadFile(r.PKIPaths.Cert)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", r.PKIPaths.Cert, err)
	}
	block, _ := pem.Decode(body)
	if block == nil {
		return nil, fmt.Errorf("no PEM block in %s", r.PKIPaths.Cert)
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse cert: %w", err)
	}
	return cert, nil
}

// refreshDeadline is when, in absolute time, rotation should kick
// in: NotBefore + lifetime * refreshAt.
func refreshDeadline(cert *x509.Certificate, refreshAt float64) time.Time {
	lifetime := cert.NotAfter.Sub(cert.NotBefore)
	return cert.NotBefore.Add(time.Duration(float64(lifetime) * refreshAt))
}
