package acme

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"fmt"

	"github.com/go-acme/lego/v4/registration"
)

// User implements lego's registration.User interface. The account key
// is the long-lived ECDSA key that identifies this operator with the
// ACME directory; the registration is the resulting account record
// returned from the directory after RegistrationLoad / Register.
type User struct {
	Email        string
	Registration *registration.Resource
	key          crypto.PrivateKey
}

func (u *User) GetEmail() string                        { return u.Email }
func (u *User) GetRegistration() *registration.Resource { return u.Registration }
func (u *User) GetPrivateKey() crypto.PrivateKey        { return u.key }

// NewOrLoadUser materializes the lego user. When accountKeyPEM is empty
// a fresh ECDSA P-256 key is generated; otherwise the supplied PEM is
// parsed and reused (the v1 design assumes Rails stores the account
// key in Vault after first issuance and supplies it back on every
// subsequent operation so the directory registration is stable).
func NewOrLoadUser(email, accountKeyPEM string) (*User, error) {
	if email == "" {
		return nil, errors.New("acme: email required for ACME user")
	}

	key, err := loadOrGenerateAccountKey(accountKeyPEM)
	if err != nil {
		return nil, err
	}
	return &User{Email: email, key: key}, nil
}

// AccountKeyPEM returns the user's account key as a PKCS#8 PEM block —
// used to round-trip the key back to Rails for Vault storage.
func (u *User) AccountKeyPEM() (string, error) {
	der, err := x509.MarshalPKCS8PrivateKey(u.key)
	if err != nil {
		return "", fmt.Errorf("marshal account key: %w", err)
	}
	block := &pem.Block{Type: "PRIVATE KEY", Bytes: der}
	return string(pem.EncodeToMemory(block)), nil
}

func loadOrGenerateAccountKey(pemStr string) (crypto.PrivateKey, error) {
	if pemStr == "" {
		key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			return nil, fmt.Errorf("generate account key: %w", err)
		}
		return key, nil
	}

	block, _ := pem.Decode([]byte(pemStr))
	if block == nil {
		return nil, errors.New("acme: account key PEM has no decodable block")
	}

	// Accept either PKCS#8 (modern) or sec1 EC (legacy openssl).
	if key, err := x509.ParsePKCS8PrivateKey(block.Bytes); err == nil {
		return key, nil
	}
	if key, err := x509.ParseECPrivateKey(block.Bytes); err == nil {
		return key, nil
	}
	return nil, errors.New("acme: account key PEM is not PKCS#8 or SEC1")
}
