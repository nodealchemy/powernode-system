package a2a

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

// TestTwoNodeLiveA2A is the full two-node LIVE A2A capstone: two node identities,
// each with a REAL platform-issued cert (CN = NodeInstance id, signed by the
// platform's internal CA with serverAuth EKU), call each other's a2a.Server over
// real mTLS using REAL platform-minted capability tokens. Bidirectional.
//
// To keep key generation in the consuming process (never via rails runner), the
// test runs in two modes against A2A_2NODE_DIR:
//
//	A2A_2NODE_MODE=gencsr — read instA.id/instB.id, generate 2 EC keypairs +
//	                        CSRs (CN=<id>), write <id>.key + <id>.csr.
//	A2A_2NODE_MODE=run    — load the platform-signed certs + ca + the two tokens
//	                        (tokenAB.json, tokenBA.json), run both a2a servers and
//	                        do A->B and B->A ping over real mTLS.
//
// The bash harness in between: rails (create instances+peers+tokens+ca) -> this
// (gencsr) -> rails (sign CSRs) -> this (run).
func TestTwoNodeLiveA2A(t *testing.T) {
	dir := os.Getenv("A2A_2NODE_DIR")
	mode := os.Getenv("A2A_2NODE_MODE")
	if dir == "" || mode == "" {
		t.Skip("set A2A_2NODE_DIR + A2A_2NODE_MODE=gencsr|run to run the live two-node smoke")
	}
	switch mode {
	case "gencsr":
		genCSRs(t, dir)
	case "run":
		runTwoNode(t, dir)
	default:
		t.Fatalf("unknown A2A_2NODE_MODE %q", mode)
	}
}

func readID(t *testing.T, dir, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		t.Fatalf("read %s: %v", name, err)
	}
	return string(b)
}

// genCSRs generates an EC keypair + CSR per node (CN = the node's instance id).
func genCSRs(t *testing.T, dir string) {
	for _, who := range []string{"instA", "instB"} {
		cn := readID(t, dir, who+".id")
		key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		keyDER, _ := x509.MarshalECPrivateKey(key)
		writePEM(t, filepath.Join(dir, who+".key"), "EC PRIVATE KEY", keyDER)

		csrDER, err := x509.CreateCertificateRequest(rand.Reader,
			&x509.CertificateRequest{Subject: pkix.Name{CommonName: cn}}, key)
		if err != nil {
			t.Fatal(err)
		}
		writePEM(t, filepath.Join(dir, who+".csr"), "CERTIFICATE REQUEST", csrDER)
		t.Logf("generated CSR for %s (CN=%s)", who, cn)
	}
}

func writePEM(t *testing.T, path, typ string, der []byte) {
	t.Helper()
	if err := os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: typ, Bytes: der}), 0o600); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

func loadToken(t *testing.T, path string) (*Token, string, string, string) {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read token %s: %v", path, err)
	}
	var fix struct {
		Envelope  string `json:"envelope"`
		Signature string `json:"signature"`
		PublicKey string `json:"public_key"`
		Handle    string `json:"handle"`
		Sub       string `json:"sub"`
		Aud       string `json:"aud"`
		Skill     string `json:"skill"`
	}
	if err := json.Unmarshal(b, &fix); err != nil {
		t.Fatalf("parse token %s: %v", path, err)
	}
	return &Token{Envelope: fix.Envelope, Signature: fix.Signature}, fix.Handle, fix.PublicKey, fix.Skill
}

// runTwoNode stands up both nodes' a2a servers with their REAL platform certs
// and does A->B and B->A pings over real mTLS with the real tokens.
func runTwoNode(t *testing.T, dir string) {
	caPEM, err := os.ReadFile(filepath.Join(dir, "ca.crt"))
	if err != nil {
		t.Fatalf("read ca: %v", err)
	}
	caPool := x509.NewCertPool()
	if !caPool.AppendCertsFromPEM(caPEM) {
		t.Fatal("no CA certs loaded")
	}

	certA, err := tls.LoadX509KeyPair(filepath.Join(dir, "instA.crt"), filepath.Join(dir, "instA.key"))
	if err != nil {
		t.Fatalf("load instA cert: %v", err)
	}
	certB, err := tls.LoadX509KeyPair(filepath.Join(dir, "instB.crt"), filepath.Join(dir, "instB.key"))
	if err != nil {
		t.Fatalf("load instB cert: %v", err)
	}
	idA := readID(t, dir, "instA.id")
	idB := readID(t, dir, "instB.id")

	tokAB, handle, pub, skill := loadToken(t, filepath.Join(dir, "tokenAB.json"))
	tokBA, handle2, pub2, _ := loadToken(t, filepath.Join(dir, "tokenBA.json"))

	// A->B: B serves, A calls.
	callPeer(t, "A->B", idB, certB, handle, pub, idA, certA, caPool, tokAB, skill)
	// B->A: A serves, B calls.
	callPeer(t, "B->A", idA, certA, handle2, pub2, idB, certB, caPool, tokBA, skill)
}

func callPeer(t *testing.T, label, serverID string, serverCert tls.Certificate,
	keyHandle, keyPub, clientID string, clientCert tls.Certificate, caPool *x509.CertPool,
	tok *Token, skill string) {
	t.Helper()

	v := NewVerifier()
	if err := v.TrustKey(keyHandle, keyPub); err != nil {
		t.Fatalf("[%s] trust key: %v", label, err)
	}
	reg := NewRegistry()
	reg.RegisterPing()
	srv := NewServer(serverID, v, reg)

	ts := httptest.NewUnstartedServer(srv.Handler())
	ts.TLS = ServerTLSConfig(serverCert, caPool)
	ts.StartTLS()
	defer ts.Close()

	cli := NewClient(&http.Client{Transport: &http.Transport{TLSClientConfig: ClientTLSConfig(clientCert, caPool)}})
	res, err := cli.CallSkill(ts.URL, tok, skill, map[string]any{"smoke": label})
	if err != nil {
		t.Fatalf("[%s] call failed: %v", label, err)
	}
	var out map[string]any
	if err := json.Unmarshal(res, &out); err != nil {
		t.Fatalf("[%s] decode: %v", label, err)
	}
	if out["pong"] != true {
		t.Fatalf("[%s] expected pong, got %v", label, out)
	}
	t.Logf("[%s] OK: real platform certs (server CN=%s, client CN=%s) + real token over mTLS -> pong", label, serverID, clientID)
}
