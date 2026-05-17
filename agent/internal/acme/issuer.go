package acme

import (
	"crypto/x509"
	"encoding/pem"
	"errors"
	"fmt"
	"os"
	"time"

	"github.com/go-acme/lego/v4/certcrypto"
	"github.com/go-acme/lego/v4/certificate"
	"github.com/go-acme/lego/v4/challenge"
	"github.com/go-acme/lego/v4/lego"
	"github.com/go-acme/lego/v4/providers/dns/cloudflare"
	"github.com/go-acme/lego/v4/registration"
)

// IssueParams is everything the issuer needs to obtain a cert. All
// fields are populated by the Rails caller (Acme::LegoClient) from
// Vault + database state.
type IssueParams struct {
	Domain        string
	SANs          []string
	Email         string
	ACMEServer    string // ACME directory URL (LE prod or staging)
	Issuer        string // "letsencrypt-prod" | "letsencrypt-staging" — passed through to result
	DNSProvider   string // "cloudflare" (other providers stubbed in v1)
	AccountKeyPEM string // optional; empty = generate new

	// Provider-specific config — read from env so the secret value
	// never appears in argv / process listings. Each entry is the
	// NAME of an env var to read; the CLI parses argv flags into
	// these names but the actual value lives in the env.
	CloudflareAPITokenEnv string // e.g. "CLOUDFLARE_DNS_API_TOKEN"
}

// Issue runs the full ACME ceremony — registration (if needed), DNS-01
// challenge, polling, and key/cert assembly. Returns an IssueResult
// suitable for JSON-encoding back to the Rails caller.
func Issue(params IssueParams) (*IssueResult, error) {
	if params.Domain == "" {
		return nil, errors.New("acme: Domain required")
	}
	if params.Email == "" {
		return nil, errors.New("acme: Email required")
	}
	if params.ACMEServer == "" {
		params.ACMEServer = lego.LEDirectoryProduction
	}

	user, err := NewOrLoadUser(params.Email, params.AccountKeyPEM)
	if err != nil {
		return nil, err
	}

	cfg := lego.NewConfig(user)
	cfg.CADirURL = params.ACMEServer
	cfg.Certificate.KeyType = certcrypto.RSA2048

	client, err := lego.NewClient(cfg)
	if err != nil {
		return nil, fmt.Errorf("acme: build client: %w", err)
	}

	provider, err := buildDNSProvider(params)
	if err != nil {
		return nil, err
	}
	if err := client.Challenge.SetDNS01Provider(provider); err != nil {
		return nil, fmt.Errorf("acme: set DNS-01 provider: %w", err)
	}

	// Register if the account key is brand-new (no Registration on user
	// yet). Lego is idempotent here — re-registering an existing key
	// returns the same account.
	reg, err := client.Registration.Register(registration.RegisterOptions{
		TermsOfServiceAgreed: true,
	})
	if err != nil {
		return nil, fmt.Errorf("acme: register account: %w", err)
	}
	user.Registration = reg

	request := certificate.ObtainRequest{
		Domains: append([]string{params.Domain}, params.SANs...),
		Bundle:  true, // include the issuer chain alongside the leaf
	}
	resource, err := client.Certificate.Obtain(request)
	if err != nil {
		return nil, fmt.Errorf("acme: obtain cert: %w", err)
	}

	expiresAt, _ := parseExpiry(resource.Certificate)
	accountPEM, err := user.AccountKeyPEM()
	if err != nil {
		return nil, fmt.Errorf("acme: serialize account key: %w", err)
	}

	return &IssueResult{
		OK:            true,
		Domain:        params.Domain,
		SANs:          params.SANs,
		CertPEM:       string(resource.Certificate),
		KeyPEM:        string(resource.PrivateKey),
		ChainPEM:      string(resource.IssuerCertificate),
		AccountKeyPEM: accountPEM,
		IssuedAt:      time.Now().UTC(),
		ExpiresAt:     expiresAt,
		Issuer:        params.Issuer,
		ACMEServer:    params.ACMEServer,
	}, nil
}

// buildDNSProvider dispatches on the DNSProvider slug. v1 wires
// Cloudflare; the rest return a clear "not yet wired" error.
func buildDNSProvider(params IssueParams) (challenge.Provider, error) {
	switch params.DNSProvider {
	case "cloudflare":
		token := os.Getenv(params.CloudflareAPITokenEnv)
		if token == "" {
			return nil, fmt.Errorf("acme: env %s is empty (Cloudflare token)", params.CloudflareAPITokenEnv)
		}
		cfg := cloudflare.NewDefaultConfig()
		cfg.AuthToken = token
		return cloudflare.NewDNSProviderConfig(cfg)
	case "":
		return nil, errors.New("acme: DNSProvider required")
	default:
		return nil, fmt.Errorf("acme: DNS provider %q not yet wired in powernode-acme v1 (Cloudflare only)", params.DNSProvider)
	}
}

func parseExpiry(certPEM []byte) (time.Time, error) {
	block, _ := pem.Decode(certPEM)
	if block == nil {
		return time.Time{}, errors.New("decode cert PEM")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return time.Time{}, err
	}
	return cert.NotAfter, nil
}

// Renew obtains a fresh certificate reusing the existing ACME account
// key (AccountKeyPEM is required). Lego doesn't expose a distinct
// "renew" — renewal is just a fresh Obtain against the same domain
// with the same account, which makes LE issue a new cert before the
// old one expires.
//
// The account_key_pem is critical: without it Lego registers a new
// LE account each renewal, which (a) burns LE's account-create rate
// limit and (b) orphans the previous registration. The Rails caller
// pulls the account key from Vault and passes it here.
func Renew(params IssueParams) (*IssueResult, error) {
	if params.AccountKeyPEM == "" {
		return nil, errors.New("acme: AccountKeyPEM required for renewal — pass the original account key from Vault")
	}
	return Issue(params)
}

// RevokeParams is everything needed to revoke an issued cert. The
// cert PEM identifies which cert to revoke; the account_key_pem
// authenticates the revocation request (only the original issuing
// account — or someone holding the cert's private key — can revoke).
//
// Reason codes per RFC 5280 §5.3.1:
//
//	0  unspecified            (default)
//	1  keyCompromise
//	2  cACompromise
//	3  affiliationChanged
//	4  superseded
//	5  cessationOfOperation
//	6  certificateHold
//	8  removeFromCRL
//	9  privilegeWithdrawn
//	10 aACompromise
type RevokeParams struct {
	CertPEM       string
	AccountKeyPEM string
	Email         string
	ACMEServer    string
	Issuer        string
	Reason        uint // RFC 5280 reason code; 0 = unspecified
}

// Revoke marks an issued certificate as revoked at the ACME server.
// Lego handles the protocol (POSTs a signed revocation request to the
// CA's revocation endpoint); we just hand it the cert + the account
// it was issued under.
func Revoke(params RevokeParams) (*RevokeResult, error) {
	if params.CertPEM == "" {
		return nil, errors.New("acme: CertPEM required")
	}
	if params.AccountKeyPEM == "" {
		return nil, errors.New("acme: AccountKeyPEM required (only the issuing account can revoke)")
	}
	if params.Email == "" {
		return nil, errors.New("acme: Email required")
	}
	if params.ACMEServer == "" {
		params.ACMEServer = lego.LEDirectoryProduction
	}

	user, err := NewOrLoadUser(params.Email, params.AccountKeyPEM)
	if err != nil {
		return nil, err
	}

	cfg := lego.NewConfig(user)
	cfg.CADirURL = params.ACMEServer

	client, err := lego.NewClient(cfg)
	if err != nil {
		return nil, fmt.Errorf("acme: build client: %w", err)
	}

	// The revocation request is signed with the account key — we don't
	// need to re-register, just construct the client. (If the account
	// has lapsed at the CA, the call will fail with a clear error.)
	reason := params.Reason
	err = client.Certificate.RevokeWithReason([]byte(params.CertPEM), &reason)
	if err != nil {
		return nil, fmt.Errorf("acme: revoke: %w", err)
	}
	return &RevokeResult{OK: true}, nil
}
