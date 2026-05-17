package acme

import "time"

// IssueResult is the structured output the CLI emits as JSON for Rails
// to consume. On success, all four PEM fields are populated and the
// timestamp pair is meaningful. On failure, OK is false and Error
// carries a human-readable reason; PEM fields are empty.
//
// The shape mirrors the contract documented on
// Acme::LegoClient#issue's Hash return on the Rails side — Rails
// parses this JSON and writes the PEM material to Vault keyed by
// AcmeCertificate.id.
type IssueResult struct {
	OK             bool      `json:"ok"`
	Error          string    `json:"error,omitempty"`
	Domain         string    `json:"domain,omitempty"`
	SANs           []string  `json:"sans,omitempty"`
	CertPEM        string    `json:"cert_pem,omitempty"`
	KeyPEM         string    `json:"key_pem,omitempty"`
	ChainPEM       string    `json:"chain_pem,omitempty"`
	AccountKeyPEM  string    `json:"account_key_pem,omitempty"`
	IssuedAt       time.Time `json:"issued_at,omitempty"`
	ExpiresAt      time.Time `json:"expires_at,omitempty"`
	Issuer         string    `json:"issuer,omitempty"`
	ACMEServer     string    `json:"acme_server,omitempty"`
}

// RenewResult is identical in shape — kept as a separate type so future
// renew-only fields (e.g., serial bump tracking) can be added without
// breaking IssueResult consumers.
type RenewResult IssueResult

// RevokeResult is a lean success/error pair — revocation has no
// material to return.
type RevokeResult struct {
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
}
