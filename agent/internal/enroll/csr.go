// Package enroll handles the bootstrap-token → mTLS cert exchange against
// the platform's /api/v1/system/node_api/enroll endpoint.
//
// Flow:
//  1. Generate an Ed25519 keypair locally (private key never leaves the node)
//  2. Build a self-signed CSR with CN = expected mtls_subject
//  3. POST { bootstrap_token, csr_pem, agent_version, dmi_uuid } to /enroll
//  4. Verify platform's TLS cert against the supplied CA bundle (from identity)
//  5. On success, persist cert + chain + private key to /persist/var/lib/powernode/pki/
//
// Reference: Golden Eclipse plan M2.C; M0.O EnrollmentController contract.
package enroll

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"fmt"
)

// Keypair is a freshly generated Ed25519 identity. The private key MUST
// never be transmitted; only the CSR (which carries the public key + a
// signature) goes over the wire.
type Keypair struct {
	Private ed25519.PrivateKey
	Public  ed25519.PublicKey
}

// PrivatePEM returns the PEM-encoded private key (PKCS#8). Used by
// callers persisting the key to disk.
func (k *Keypair) PrivatePEM() ([]byte, error) {
	der, err := x509.MarshalPKCS8PrivateKey(k.Private)
	if err != nil {
		return nil, fmt.Errorf("marshal private key: %w", err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), nil
}

// GenerateKeypair returns a fresh Ed25519 keypair using crypto/rand.
func GenerateKeypair() (*Keypair, error) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("generate ed25519: %w", err)
	}
	return &Keypair{Private: priv, Public: pub}, nil
}

// BuildCSR returns a PEM-encoded X.509 certificate request signed by the
// keypair. CN is set to the supplied subject (typically the NodeInstance
// UUID, which is what the platform's IntervalCaService uses as the cert
// subject).
func BuildCSR(kp *Keypair, subject string) ([]byte, error) {
	if kp == nil || kp.Private == nil {
		return nil, errors.New("BuildCSR: nil keypair")
	}
	if subject == "" {
		return nil, errors.New("BuildCSR: empty subject")
	}

	tmpl := x509.CertificateRequest{
		Subject: pkix.Name{CommonName: subject},
		// Ed25519 doesn't take a hash algorithm; SignatureAlgorithm is
		// inferred from the private key type by x509.CreateCertificateRequest.
	}
	der, err := x509.CreateCertificateRequest(rand.Reader, &tmpl, kp.Private)
	if err != nil {
		return nil, fmt.Errorf("create CSR: %w", err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE REQUEST", Bytes: der}), nil
}
