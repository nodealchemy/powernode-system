package identity

// powernode-provision document v1: the one versioned JSON document every
// channel (USB file, cloud-init/NoCloud/config-drive, provider metadata, PXE
// pickup) carries. Schema: extensions/system/docs/schemas/powernode-provision-v1.schema.json,
// docs: extensions/system/docs/PROVISION_DOCUMENT.md. The server renderer is
// System::ProvisioningDocument.
//
// DEPRECATION: the legacy shell KEY=VALUE identity.cfg, the kernel-cmdline
// form, fw-cfg entries and the unversioned JSON shape (instance_uuid /
// bootstrap_token / ...) remain accepted on READ for ONE image release after
// this lands, then are removed. New writers must emit v1 JSON only.

import (
	"bytes"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/url"
	"regexp"
	"strings"
	"time"
)

const (
	provisionMaxDocBytes = 128 * 1024
	provisionMaxCAPEM    = 64 * 1024
	provisionMaxURL      = 2048
	provisionMaxKey      = 512
	provisionMaxPurpose  = 64
)

var (
	fingerprintRe = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)
	uuidRe        = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)
	purposeRe     = regexp.MustCompile(`^[a-z0-9_.-]{1,64}$`)
)

// provisionDoc uses pointers so a missing field is distinguishable from an
// empty one. Unknown keys are rejected by DisallowUnknownFields.
type provisionDoc struct {
	Version       *int    `json:"version"`
	Server        *string `json:"server"`
	InstanceID    *string `json:"instance_id"`
	Key           *string `json:"key"`
	CAFingerprint *string `json:"ca_fingerprint"`
	CAPEM         *string `json:"ca_pem"`
	IssuedAt      *string `json:"issued_at"`
	ExpiresAt     *string `json:"expires_at"`
	Purpose       *string `json:"purpose"`
}

// ValidFingerprint reports whether s is a well-formed "sha256:<64 lowercase hex>" pin.
func ValidFingerprint(s string) bool { return fingerprintRe.MatchString(s) }

// CertFingerprint is the pin form of one certificate: sha256 over its DER.
func CertFingerprint(c *x509.Certificate) string {
	sum := sha256.Sum256(c.Raw)
	return "sha256:" + hex.EncodeToString(sum[:])
}

func parsePEMCerts(data []byte) ([]*x509.Certificate, error) {
	var certs []*x509.Certificate
	for {
		var b *pem.Block
		b, data = pem.Decode(data)
		if b == nil {
			break
		}
		if b.Type != "CERTIFICATE" {
			continue
		}
		c, err := x509.ParseCertificate(b.Bytes)
		if err != nil {
			return nil, fmt.Errorf("unparseable certificate: %w", err)
		}
		certs = append(certs, c)
	}
	if len(certs) == 0 {
		return nil, errors.New("no certificates found")
	}
	return certs, nil
}

func printable(s string, allowWhitespace bool) bool {
	for _, r := range s {
		if allowWhitespace && (r == '\n' || r == '\r' || r == '\t') {
			continue
		}
		if r < 0x20 || r > 0x7e {
			return false
		}
	}
	return true
}

func checkServerURL(s string) error {
	if len(s) == 0 || len(s) > provisionMaxURL || !printable(s, false) {
		return errors.New("server: empty, too long or not printable")
	}
	u, err := url.Parse(s)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil {
		return errors.New("server: must be an https URL with a host and no credentials")
	}
	return nil
}

// ParseProvisionDocument strictly parses a powernode-provision v1 document.
// ca_fingerprint is required: a document without a pin is refused. Errors
// never contain the key.
func ParseProvisionDocument(raw []byte) (*Identity, error) {
	if len(raw) > provisionMaxDocBytes {
		return nil, errors.New("provision document: too large")
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	var d provisionDoc
	if err := dec.Decode(&d); err != nil {
		return nil, fmt.Errorf("provision document: %w", sanitizeJSONErr(err))
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return nil, errors.New("provision document: trailing data")
	}

	if d.Version == nil || *d.Version != 1 {
		return nil, errors.New("provision document: version must be 1")
	}
	for name, p := range map[string]*string{
		"server": d.Server, "instance_id": d.InstanceID, "key": d.Key,
		"ca_fingerprint": d.CAFingerprint, "issued_at": d.IssuedAt,
		"expires_at": d.ExpiresAt, "purpose": d.Purpose,
	} {
		if p == nil || *p == "" {
			return nil, fmt.Errorf("provision document: %s is required", name)
		}
	}
	if err := checkServerURL(*d.Server); err != nil {
		return nil, fmt.Errorf("provision document: %w", err)
	}
	if !uuidRe.MatchString(*d.InstanceID) {
		return nil, errors.New("provision document: instance_id must be a uuid")
	}
	if len(*d.Key) > provisionMaxKey || !printable(*d.Key, false) || strings.ContainsAny(*d.Key, " \t") {
		return nil, errors.New("provision document: key malformed")
	}
	if !ValidFingerprint(*d.CAFingerprint) {
		return nil, errors.New(`provision document: ca_fingerprint must be "sha256:<64 lowercase hex>"`)
	}
	if !purposeRe.MatchString(*d.Purpose) {
		return nil, errors.New("provision document: purpose malformed")
	}
	issued, err1 := time.Parse(time.RFC3339, *d.IssuedAt)
	expires, err2 := time.Parse(time.RFC3339, *d.ExpiresAt)
	if err1 != nil || err2 != nil {
		return nil, errors.New("provision document: issued_at/expires_at must be ISO8601")
	}
	if !expires.After(issued) {
		return nil, errors.New("provision document: expires_at must be after issued_at")
	}
	// Expiry is deliberately NOT checked against the local clock: a device
	// booting without RTC/NTP would reject every valid document. The server
	// enforces token expiry.

	id := &Identity{
		InstanceUUID:   *d.InstanceID,
		BootstrapToken: *d.Key,
		PlatformURL:    *d.Server,
		CAFingerprint:  *d.CAFingerprint,
	}
	if d.CAPEM != nil && *d.CAPEM != "" {
		if len(*d.CAPEM) > provisionMaxCAPEM || !printable(*d.CAPEM, true) {
			return nil, errors.New("provision document: ca_pem too large or not printable")
		}
		if err := checkPEMMatchesPin([]byte(*d.CAPEM), *d.CAFingerprint); err != nil {
			return nil, fmt.Errorf("provision document: ca_pem: %w", err)
		}
		id.CABundlePEM = *d.CAPEM
	}
	return id, nil
}

// sanitizeJSONErr keeps decoder errors but guarantees no field value is echoed.
func sanitizeJSONErr(err error) error {
	var ute *json.UnmarshalTypeError
	if errors.As(err, &ute) {
		return fmt.Errorf("field %q has the wrong type", ute.Field)
	}
	var se *json.SyntaxError
	if errors.As(err, &se) {
		return errors.New("invalid JSON")
	}
	// DisallowUnknownFields: `json: unknown field "x"` - the name only.
	if strings.HasPrefix(err.Error(), "json: unknown field") {
		return err
	}
	return errors.New("invalid JSON")
}

func checkPEMMatchesPin(caPEM []byte, pin string) error {
	certs, err := parsePEMCerts(caPEM)
	if err != nil {
		return err
	}
	for _, c := range certs {
		if CertFingerprint(c) == pin {
			return nil
		}
	}
	return errors.New("no certificate matches ca_fingerprint")
}

// PinnedTLSConfig builds the enrolment/claim TLS config. caPEM may be empty
// (system roots are used); pin may be empty only for the deprecated legacy
// sources that never carried one. When pin is set it is ALWAYS enforced: the
// verified chain must contain a certificate whose DER sha256 equals it, or the
// handshake fails.
func PinnedTLSConfig(caPEM []byte, pin string) (*tls.Config, error) {
	cfg := &tls.Config{MinVersion: tls.VersionTLS13}
	if len(caPEM) > 0 {
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(caPEM) {
			return nil, errors.New("CA bundle contains no parseable certificates")
		}
		cfg.RootCAs = pool
	}
	if pin == "" {
		return cfg, nil
	}
	if !ValidFingerprint(pin) {
		return nil, errors.New("ca_fingerprint malformed")
	}
	cfg.VerifyConnection = func(cs tls.ConnectionState) error {
		for _, chain := range cs.VerifiedChains {
			for _, c := range chain {
				if CertFingerprint(c) == pin {
					return nil
				}
			}
		}
		return errors.New("platform certificate chain does not match the pinned ca_fingerprint")
	}
	return cfg, nil
}

// legacyPin validates an optional pin carried by a legacy source.
func legacyPin(v string) (string, error) {
	if v == "" {
		return "", nil
	}
	if !ValidFingerprint(v) {
		return "", errors.New("ca_fingerprint malformed")
	}
	return v, nil
}
