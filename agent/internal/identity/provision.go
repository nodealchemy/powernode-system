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
	"strconv"
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

// ErrProvisionRefused marks a refusal that is TERMINAL: a powernode-provision
// v1 document (or a pin) was present but invalid. The Resolver must stop and
// refuse to enrol rather than fall through to a weaker source.
var ErrProvisionRefused = errors.New("provision refused")

func refuse(format string, a ...any) error {
	return fmt.Errorf("%w: "+format, append([]any{ErrProvisionRefused}, a...)...)
}

// provisionFields are the exact, case-sensitive keys of v1.
var provisionFields = map[string]bool{
	"version": true, "server": true, "instance_id": true, "key": true,
	"ca_fingerprint": true, "ca_pem": true, "issued_at": true, "expires_at": true, "purpose": true,
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

// serverRe is the shared server-URL rule (mirrored in the Ruby renderer and
// the JSON Schema): https, host (DNS name or [IPv6]), optional :port, optional
// printable path. The port range is checked in code.
var serverRe = regexp.MustCompile(`^https://([A-Za-z0-9.-]+|\[[0-9A-Fa-f:.]+\])(:[0-9]{1,5})?(/[\x21-\x7e]*)?$`)

func checkServerURL(s string) error {
	if len(s) > provisionMaxURL {
		return errors.New("server: too long")
	}
	m := serverRe.FindStringSubmatch(s)
	if m == nil {
		return errors.New("server: must be a plain https URL (host, optional port and path, no credentials, no spaces)")
	}
	if p := strings.TrimPrefix(m[2], ":"); p != "" {
		n, _ := strconv.Atoi(p)
		if n < 1 || n > 65535 {
			return errors.New("server: port out of range")
		}
	}
	return nil
}

// decodeStrict walks the top-level object token by token so that duplicate
// keys, case-variant keys, nulls, nested values and a non-literal-1 version
// are rejected (encoding/json would silently take the last duplicate and match
// keys case-insensitively). Error text never contains a value.
func decodeStrict(raw []byte) (map[string]string, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if tok, err := dec.Token(); err != nil || tok != json.Delim('{') {
		return nil, refuse("document must be a JSON object")
	}
	vals := map[string]string{}
	for dec.More() {
		kt, err := dec.Token()
		if err != nil {
			return nil, refuse("invalid JSON")
		}
		key, ok := kt.(string)
		if !ok {
			return nil, refuse("invalid JSON")
		}
		if !provisionFields[key] {
			return nil, refuse("unknown field %q", key)
		}
		if _, dup := vals[key]; dup {
			return nil, refuse("duplicate field %q", key)
		}
		vt, err := dec.Token()
		if err != nil {
			return nil, refuse("invalid JSON")
		}
		switch v := vt.(type) {
		case string:
			if key == "version" {
				return nil, refuse("version must be the integer 1")
			}
			vals[key] = v
		case json.Number:
			if key != "version" || v.String() != "1" {
				return nil, refuse("field %q has the wrong type or value", key)
			}
			vals[key] = "1"
		default: // null, bool, nested object/array
			return nil, refuse("field %q has the wrong type", key)
		}
	}
	if _, err := dec.Token(); err != nil { // closing brace
		return nil, refuse("invalid JSON")
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return nil, refuse("trailing data")
	}
	return vals, nil
}

// ParseProvisionDocument strictly parses a powernode-provision v1 document.
// ca_fingerprint is required: a document without a pin is refused. Every error
// wraps ErrProvisionRefused and never contains the key.
func ParseProvisionDocument(raw []byte) (*Identity, error) {
	if len(raw) > provisionMaxDocBytes {
		return nil, refuse("document too large")
	}
	v, err := decodeStrict(raw)
	if err != nil {
		return nil, err
	}
	if v["version"] != "1" {
		return nil, refuse("version must be 1")
	}
	for _, name := range []string{"server", "instance_id", "key", "ca_fingerprint", "issued_at", "expires_at", "purpose"} {
		if v[name] == "" {
			return nil, refuse("%s is required", name)
		}
	}
	if err := checkServerURL(v["server"]); err != nil {
		return nil, refuse("%v", err)
	}
	if !uuidRe.MatchString(v["instance_id"]) {
		return nil, refuse("instance_id must be a uuid")
	}
	if len(v["key"]) > provisionMaxKey || !printable(v["key"], false) || strings.ContainsAny(v["key"], " \t") {
		return nil, refuse("key malformed")
	}
	if !ValidFingerprint(v["ca_fingerprint"]) {
		return nil, refuse(`ca_fingerprint must be "sha256:<64 lowercase hex>"`)
	}
	if !purposeRe.MatchString(v["purpose"]) {
		return nil, refuse("purpose malformed")
	}
	issued, err1 := time.Parse(time.RFC3339, v["issued_at"])
	expires, err2 := time.Parse(time.RFC3339, v["expires_at"])
	if err1 != nil || err2 != nil {
		return nil, refuse("issued_at/expires_at must be RFC 3339")
	}
	if !expires.After(issued) {
		return nil, refuse("expires_at must be after issued_at")
	}
	// Expiry is deliberately NOT checked against the local clock: a device
	// booting without RTC/NTP would reject every valid document. The server
	// enforces token expiry.

	id := &Identity{
		InstanceUUID:   v["instance_id"],
		BootstrapToken: v["key"],
		PlatformURL:    v["server"],
		CAFingerprint:  v["ca_fingerprint"],
	}
	if ca := v["ca_pem"]; ca != "" {
		if len(ca) > provisionMaxCAPEM || !printable(ca, true) {
			return nil, refuse("ca_pem too large or not printable")
		}
		if err := checkPEMMatchesPin([]byte(ca), v["ca_fingerprint"]); err != nil {
			return nil, refuse("ca_pem: %v", err)
		}
		id.CABundlePEM = ca
	}
	return id, nil
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

func selfSignedCA(c *x509.Certificate) bool {
	return c.IsCA && bytes.Equal(c.RawIssuer, c.RawSubject) && c.CheckSignatureFrom(c) == nil
}

// PinnedTLSConfig builds the enrolment/claim/post-enrolment TLS config with the
// system roots as the base when caPEM is empty. See PinnedTLSConfigWithBase.
func PinnedTLSConfig(caPEM []byte, pin, platformURL string) (*tls.Config, error) {
	return PinnedTLSConfigWithBase(caPEM, pin, platformURL, nil)
}

// PinnedTLSConfigWithBase builds the TLS config. caPEM may be empty (base, or
// the system roots when base is nil, is the trust store); pin may be empty only
// for the deprecated legacy sources that never carried one.
//
// Chain building (pinned): self-signed CA certificates in caPEM are the trust
// anchors, every other certificate in caPEM is an intermediate (so a leaf-only
// server still validates). If caPEM holds no self-signed CA (e.g. a persisted
// bundle that is just the matched pin cert) its certificates are all anchors,
// as Go does natively. Peer-sent intermediates are usable too.
//
// When pin is set it is ALWAYS enforced: the verified chain must contain a
// certificate whose DER sha256 equals it, or the handshake fails. Verification
// runs in VerifyConnection (InsecureSkipVerify only disables Go's built-in pass
// so a custom Intermediates pool can be used; hostname, validity and key usage
// are still verified by x509.Verify there).
func PinnedTLSConfigWithBase(caPEM []byte, pin, platformURL string, base *x509.CertPool) (*tls.Config, error) {
	if pin == "" {
		return unpinnedTLSConfig(caPEM, base)
	}
	v, err := NewPinVerifier(caPEM, pin, platformURL, base)
	if err != nil {
		return nil, err
	}
	return v.TLSConfig(), nil
}

func unpinnedTLSConfig(caPEM []byte, base *x509.CertPool) (*tls.Config, error) {
	// Legacy, unpinned: Go's native verification with the bundle as roots.
	cfg := &tls.Config{MinVersion: tls.VersionTLS13}
	if len(caPEM) > 0 {
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(caPEM) {
			return nil, errors.New("CA bundle contains no parseable certificates")
		}
		cfg.RootCAs = pool
	} else if base != nil {
		cfg.RootCAs = base
	}
	return cfg, nil
}

// PinVerifier verifies a server's presented chain against the trust store and
// returns the chain certificate that matches the pin.
type PinVerifier struct {
	roots, inters *x509.CertPool
	host, pin     string
}

// NewPinVerifier builds a verifier. See PinnedTLSConfigWithBase for the chain
// building rules.
func NewPinVerifier(caPEM []byte, pin, platformURL string, base *x509.CertPool) (*PinVerifier, error) {
	if !ValidFingerprint(pin) {
		return nil, errors.New("ca_fingerprint malformed")
	}
	// The name to verify is the platform URL's host (an IP literal or DNS
	// name): ConnectionState.ServerName is empty for IP hosts.
	u, err := url.Parse(platformURL)
	if err != nil || u.Hostname() == "" {
		return nil, errors.New("pinned TLS needs the platform URL host to verify")
	}
	v := &PinVerifier{roots: base, inters: x509.NewCertPool(), host: u.Hostname(), pin: pin}
	if len(caPEM) > 0 {
		certs, err := parsePEMCerts(caPEM)
		if err != nil {
			return nil, errors.New("CA bundle contains no parseable certificates")
		}
		var anchors, others []*x509.Certificate
		for _, c := range certs {
			if selfSignedCA(c) {
				anchors = append(anchors, c)
			} else {
				others = append(others, c)
			}
		}
		if len(anchors) == 0 {
			anchors, others = others, nil
		}
		v.roots = x509.NewCertPool()
		for _, c := range anchors {
			v.roots.AddCert(c)
		}
		for _, c := range others {
			v.inters.AddCert(c)
		}
	}
	return v, nil
}

// Verify builds and verifies a chain from the peer certificates (hostname,
// validity, server-auth usage) and returns the chain certificate whose DER
// sha256 equals the pin.
func (v *PinVerifier) Verify(peers []*x509.Certificate) (*x509.Certificate, error) {
	if len(peers) == 0 {
		return nil, errors.New("no peer certificate to verify")
	}
	opts := x509.VerifyOptions{
		Roots: v.roots, DNSName: v.host, Intermediates: v.inters.Clone(),
		KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	for _, c := range peers[1:] {
		opts.Intermediates.AddCert(c)
	}
	chains, err := peers[0].Verify(opts)
	if err != nil {
		return nil, err
	}
	for _, chain := range chains {
		for _, c := range chain {
			if CertFingerprint(c) == v.pin {
				return c, nil
			}
		}
	}
	return nil, errors.New("platform certificate chain does not match the pinned ca_fingerprint")
}

// TLSConfig returns a TLS 1.3 client config that enforces the verifier.
// InsecureSkipVerify only disables Go's built-in pass so a custom
// Intermediates pool can be used; Verify does the real verification.
func (v *PinVerifier) TLSConfig() *tls.Config {
	return &tls.Config{
		MinVersion:         tls.VersionTLS13,
		ServerName:         v.host,
		InsecureSkipVerify: true, //nolint:gosec // verified in VerifyConnection
		VerifyConnection: func(cs tls.ConnectionState) error {
			_, err := v.Verify(cs.PeerCertificates)
			return err
		},
	}
}

// legacyPin validates an optional pin carried by a legacy source.
func legacyPin(v string) (string, error) {
	if v == "" {
		return "", nil
	}
	if !ValidFingerprint(v) {
		return "", refuse("ca_fingerprint malformed")
	}
	return v, nil
}
