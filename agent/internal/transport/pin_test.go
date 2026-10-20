package transport

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/enroll"
)

// A pin-only enrolment leaves ca-bundle.crt = the matched cert and ca-pin.
// LoadFromPKIDir must load (no brick) AND keep enforcing the pin on every
// reconnect: a server whose chain does not contain the pinned cert is refused
// even though the bundle itself would verify it.
func TestLoadFromPKIDir_EnforcesPersistedPin(t *testing.T) {
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer srv.Close()
	srvPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: srv.Certificate().Raw})
	sum := sha256.Sum256(srv.Certificate().Raw)
	goodPin := "sha256:" + hex.EncodeToString(sum[:])

	write := func(pin string) enroll.PKIPaths {
		paths := enroll.PathsUnder(t.TempDir())
		certPEM, keyPEM := selfSignedClientPair(t)
		must(t, os.WriteFile(paths.Cert, certPEM, 0o644))
		must(t, os.WriteFile(paths.Key, keyPEM, 0o600))
		must(t, os.WriteFile(paths.CABundle, srvPEM, 0o644))
		if pin != "" {
			must(t, os.WriteFile(paths.CAPin, []byte(pin+"\n"), 0o644))
		}
		return paths
	}

	c, err := LoadFromPKIDir(srv.URL, write(goodPin))
	if err != nil {
		t.Fatalf("pin-only enrolled node bricked: %v", err)
	}
	resp, err := c.Client.Get(srv.URL)
	if err != nil {
		t.Fatalf("matching pin refused after enrolment: %v", err)
	}
	resp.Body.Close()

	c, err = LoadFromPKIDir(srv.URL, write("sha256:"+strings.Repeat("0", 64)))
	if err != nil {
		t.Fatal(err)
	}
	if resp, err := c.Client.Get(srv.URL); err == nil {
		resp.Body.Close()
		t.Fatal("mismatched pin accepted after enrolment")
	}
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func selfSignedClientPair(t *testing.T) (certPEM, keyPEM []byte) {
	t.Helper()
	k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tpl := &x509.Certificate{
		SerialNumber: big.NewInt(7), Subject: pkix.Name{CommonName: "node"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &k.PublicKey, k)
	must(t, err)
	kd, _ := x509.MarshalECPrivateKey(k)
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}),
		pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: kd})
}
