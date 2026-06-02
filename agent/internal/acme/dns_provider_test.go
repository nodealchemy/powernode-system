package acme

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"strings"
	"testing"
)

// Verifies buildDNSProvider wires every provider Rails (Acme::LegoClient) can
// dispatch, reading the same standard lego env vars build_provider_env exports.
// Construction is network-free, so these prove the env wiring without issuing.
func TestBuildDNSProvider_StandardEnvProviders(t *testing.T) {
	cases := []struct {
		name string
		env  map[string]string
	}{
		{"digitalocean", map[string]string{"DO_AUTH_TOKEN": "tok"}},
		{"hetzner", map[string]string{"HETZNER_API_KEY": "tok"}},
		{"route53", map[string]string{
			"AWS_ACCESS_KEY_ID":     "akid",
			"AWS_SECRET_ACCESS_KEY": "secret",
			"AWS_REGION":            "us-east-1",
		}},
		{"porkbun", map[string]string{"PORKBUN_API_KEY": "k", "PORKBUN_SECRET_API_KEY": "s"}},
		{"ovh", map[string]string{
			"OVH_APPLICATION_KEY":    "ak",
			"OVH_APPLICATION_SECRET": "as",
			"OVH_CONSUMER_KEY":       "ck",
			"OVH_ENDPOINT":           "ovh-eu",
		}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			for k, v := range tc.env {
				t.Setenv(k, v)
			}
			p, err := buildDNSProvider(IssueParams{DNSProvider: tc.name})
			if err != nil {
				t.Fatalf("buildDNSProvider(%q) returned error: %v", tc.name, err)
			}
			if p == nil {
				t.Fatalf("buildDNSProvider(%q) returned a nil provider", tc.name)
			}
		})
	}
}

func TestBuildDNSProvider_Gcloud(t *testing.T) {
	t.Setenv("GCE_PROJECT", "test-project")
	t.Setenv("GCE_SERVICE_ACCOUNT", testServiceAccountJSON(t))

	p, err := buildDNSProvider(IssueParams{DNSProvider: "gcloud"})
	if err != nil {
		t.Fatalf("buildDNSProvider(gcloud) returned error: %v", err)
	}
	if p == nil {
		t.Fatal("buildDNSProvider(gcloud) returned a nil provider")
	}
}

func TestBuildDNSProvider_Cloudflare(t *testing.T) {
	t.Setenv("CF_TOKEN", "cf-secret")
	p, err := buildDNSProvider(IssueParams{DNSProvider: "cloudflare", CloudflareAPITokenEnv: "CF_TOKEN"})
	if err != nil || p == nil {
		t.Fatalf("buildDNSProvider(cloudflare): provider=%v err=%v", p, err)
	}
}

func TestBuildDNSProvider_UnknownAndEmpty(t *testing.T) {
	if _, err := buildDNSProvider(IssueParams{DNSProvider: ""}); err == nil {
		t.Fatal("empty DNSProvider should error")
	}

	_, err := buildDNSProvider(IssueParams{DNSProvider: "route66"})
	if err == nil || !strings.Contains(err.Error(), "not supported") {
		t.Fatalf("unknown provider should error with 'not supported', got: %v", err)
	}
}

// testServiceAccountJSON builds a well-formed GCP service-account JSON with a
// freshly generated key, so lego's gcloud provider parses it at construction.
func testServiceAccountJSON(t *testing.T) string {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})

	sa := map[string]string{
		"type":           "service_account",
		"project_id":     "test-project",
		"private_key_id": "test-key-id",
		"private_key":    string(keyPEM),
		"client_email":   "test@test-project.iam.gserviceaccount.com",
		"client_id":      "123456789",
		"token_uri":      "https://oauth2.googleapis.com/token",
	}
	b, err := json.Marshal(sa)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}
