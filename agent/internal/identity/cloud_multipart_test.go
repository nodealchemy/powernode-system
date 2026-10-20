package identity

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func multipartSeed(doc, script string) string {
	return strings.Join([]string{
		"MIME-Version: 1.0",
		"Content-Type: multipart/mixed; boundary=\"b-1\"",
		"",
		"--b-1",
		"Content-Type: application/x-powernode-provision+json; charset=\"utf-8\"",
		"",
		doc,
		"--b-1",
		"Content-Type: text/cloud-config; charset=\"utf-8\"",
		"",
		script,
		"--b-1--",
		"",
	}, "\n")
}

func TestParseUserDataMultipartSelectsTheProvisionPart(t *testing.T) {
	pki := newTestPKI(t)
	doc := v1Doc(pki, nil)
	id, err := parseUserData(multipartSeed(doc, "#cloud-config\nruncmd: [ls]"))
	if err != nil {
		t.Fatalf("parseUserData: %v", err)
	}
	if id == nil || id.InstanceUUID == "" || id.BootstrapToken == "" || id.CAFingerprint == "" {
		t.Fatalf("v1 part not parsed: %+v", id)
	}
}

func TestParseUserDataMultipartWithoutProvisionPartIsNotFound(t *testing.T) {
	raw := "MIME-Version: 1.0\nContent-Type: multipart/mixed; boundary=\"b-1\"\n\n--b-1\nContent-Type: text/cloud-config\n\n#cloud-config\n--b-1--\n"
	if _, err := parseUserData(raw); err != ErrNotFound {
		t.Fatalf("want ErrNotFound, got %v", err)
	}
}

func TestParseUserDataMultipartBadV1PartIsTerminal(t *testing.T) {
	pki := newTestPKI(t)
	doc := v1Doc(pki, func(d map[string]any) { delete(d, "ca_fingerprint") })
	if _, err := parseUserData(multipartSeed(doc, "#cloud-config")); err == nil {
		t.Fatal("a pinless v1 part must be refused")
	}
}

func TestParseUserDataMultipartRefusesTwoProvisionParts(t *testing.T) {
	pki := newTestPKI(t)
	doc := v1Doc(pki, nil)
	raw := multipartSeed(doc, "#cloud-config")
	raw = strings.Replace(raw, "--b-1--", "--b-1\nContent-Type: application/x-powernode-provision+json\n\n"+doc+"\n--b-1--", 1)
	if _, err := parseUserData(raw); err == nil {
		t.Fatal("two provision parts must be refused")
	}
}

func TestParseUserDataMultipartRefusesLegacyShapeInProvisionPart(t *testing.T) {
	legacy := `{"instance_uuid":"u","bootstrap_token":"not-a-real-enrol-key","platform_url":"https://p.example.test"}`
	if _, err := parseUserData(multipartSeed(legacy, "#cloud-config")); err == nil {
		t.Fatal("a legacy JSON shape inside a provision part must be refused")
	}
	if _, err := parseUserData(multipartSeed("ID=u\nKEY=not-a-real-enrol-key", "#cloud-config")); err == nil {
		t.Fatal("KEY=VALUE inside a provision part must be refused")
	}
}

func TestParseUserDataMultipartCapsPartAndEnvelope(t *testing.T) {
	big := "{" + strings.Repeat(" ", provisionMaxDocBytes+10) + "}"
	if _, err := parseUserData(multipartSeed(big, "#cloud-config")); err == nil {
		t.Fatal("an oversized provision part must be refused")
	}
	if _, err := parseUserData(multipartSeed("{}", strings.Repeat("x", provisionMultipartMaxBytes))); err == nil {
		t.Fatal("an oversized envelope must be refused")
	}
}

func TestHttpDoDoesNotTruncateLargeDocuments(t *testing.T) {
	body := strings.Repeat("a", 100*1024)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte(body)) }))
	defer srv.Close()
	got, err := httpDo(context.Background(), http.MethodGet, srv.URL, nil)
	if err != nil || len(got) != len(body) {
		t.Fatalf("len=%d err=%v", len(got), err)
	}
}
