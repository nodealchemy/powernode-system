package a2a

import (
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// --- test PKI: a CA that issues server/client leaf certs by CN ---

type testCA struct {
	cert *x509.Certificate
	key  *ecdsa.PrivateKey
	pool *x509.CertPool
}

func newTestCA(t *testing.T) *testCA {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "Test A2A CA"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	cert, _ := x509.ParseCertificate(der)
	pool := x509.NewCertPool()
	pool.AddCert(cert)
	return &testCA{cert: cert, key: key, pool: pool}
}

func (ca *testCA) leaf(t *testing.T, cn string, server bool) tls.Certificate {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	eku := x509.ExtKeyUsageClientAuth
	if server {
		eku = x509.ExtKeyUsageServerAuth
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()),
		Subject:      pkix.Name{CommonName: cn},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{eku},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, ca.cert, &key.PublicKey, ca.key)
	if err != nil {
		t.Fatal(err)
	}
	leaf, _ := x509.ParseCertificate(der)
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key, Leaf: leaf}
}

// newA2AEnv wires a live mTLS A2A server (CN=instB, offering ping) + a client
// (CN=instA), and returns the Ed25519 private key the verifier trusts (for
// minting test tokens via signTok).
func newA2AEnv(t *testing.T) (url string, cli *Client, signPriv ed25519.PrivateKey, closeFn func()) {
	t.Helper()
	ca := newTestCA(t)
	serverCert := ca.leaf(t, "instB", true)
	clientCert := ca.leaf(t, "instA", false)

	v, priv := newTrustedVerifier(t, "a2a-cap-acct-test")
	reg := NewRegistry()
	reg.RegisterPing()
	srv := NewServer("instB", v, reg)
	srv.Now = func() time.Time { return time.Unix(1000, 0) }

	ts := httptest.NewUnstartedServer(srv.Handler())
	ts.TLS = ServerTLSConfig(serverCert, ca.pool)
	ts.StartTLS()

	httpClient := &http.Client{Transport: &http.Transport{TLSClientConfig: ClientTLSConfig(clientCert, ca.pool)}}
	return ts.URL, NewClient(httpClient), priv, ts.Close
}

func TestA2A_RoundTrip(t *testing.T) {
	url, cli, priv, closeFn := newA2AEnv(t)
	defer closeFn()

	tok := signTok(t, priv, mkClaims("instA", "instB", "ping", 990, 2000))

	if _, err := cli.Initialize(url, tok); err != nil {
		t.Fatalf("initialize: %v", err)
	}
	tools, err := cli.ListTools(url, tok)
	if err != nil {
		t.Fatalf("tools/list: %v", err)
	}
	if len(tools) != 1 || tools[0].Name != "ping" {
		t.Fatalf("expected [ping], got %+v", tools)
	}

	res, err := cli.CallSkill(url, tok, "ping", map[string]any{"hello": "world"})
	if err != nil {
		t.Fatalf("call ping: %v", err)
	}
	var out map[string]any
	if err := json.Unmarshal(res, &out); err != nil {
		t.Fatal(err)
	}
	if out["pong"] != true {
		t.Fatalf("expected pong:true, got %v", out)
	}
}

func TestA2A_NoTokenDenied(t *testing.T) {
	url, cli, _, closeFn := newA2AEnv(t)
	defer closeFn()
	if _, err := cli.CallSkill(url, nil, "ping", nil); err == nil {
		t.Fatal("expected unauthorized without a capability token")
	}
}

func TestA2A_WrongSkillTokenDenied(t *testing.T) {
	url, cli, priv, closeFn := newA2AEnv(t)
	defer closeFn()
	// Token authorizes "other", but the call invokes "ping".
	tok := signTok(t, priv, mkClaims("instA", "instB", "other", 990, 2000))
	if _, err := cli.CallSkill(url, tok, "ping", nil); err == nil {
		t.Fatal("expected denial: token skill != invoked skill")
	}
}

func TestA2A_WrongAudienceDenied(t *testing.T) {
	url, cli, priv, closeFn := newA2AEnv(t)
	defer closeFn()
	// Token aud=instZ, but the server self id is instB.
	tok := signTok(t, priv, mkClaims("instA", "instZ", "ping", 990, 2000))
	if _, err := cli.CallSkill(url, tok, "ping", nil); err == nil {
		t.Fatal("expected denial: token aud != server self id")
	}
}
