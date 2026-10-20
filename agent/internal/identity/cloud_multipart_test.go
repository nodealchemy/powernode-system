package identity

import (
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
