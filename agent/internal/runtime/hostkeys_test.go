package runtime

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/transport"
)

// IMP-190834701b0a — the agent reports its SSH host PUBLIC keys so the
// platform can verify it is connecting to THIS host, not whatever answers at a
// reused address. The reader must never open a private key file.
//
// Every key-shaped fixture is built at runtime: gitleaks does not allowlist
// _test.go files and push protection scans every commit, so no key-shaped
// literal may appear in source, public or not.

// testHostKeyBlob builds an OpenSSH wire-format public key blob: uint32 length
// + algorithm name, then uint32 length + random key bytes.
func testHostKeyBlob(t *testing.T, keyType string, n int) []byte {
	t.Helper()
	body := make([]byte, n)
	if _, err := rand.Read(body); err != nil {
		t.Fatalf("rand: %v", err)
	}
	var blob []byte
	blob = binary.BigEndian.AppendUint32(blob, uint32(len(keyType)))
	blob = append(blob, keyType...)
	blob = binary.BigEndian.AppendUint32(blob, uint32(n))
	return append(blob, body...)
}

func testHostKeyLine(t *testing.T, keyType string, n int) (line, key string) {
	t.Helper()
	key = base64.StdEncoding.EncodeToString(testHostKeyBlob(t, keyType, n))
	return keyType + " " + key + " root@fixture-host\n", key
}

// privateKeyArmor is assembled at runtime so no PEM header literal sits in
// source.
func privateKeyArmor() string {
	marker := strings.Join([]string{"OPENSSH", "PRIVATE", "KEY"}, " ")
	return "-----BEGIN " + marker + "-----\nAAAA\n-----END " + marker + "-----\n"
}

// recordOpens swaps the open seam for one that records every path, and
// restores it when the test ends.
func recordOpens(t *testing.T) *[]string {
	t.Helper()
	var opened []string
	orig := hostKeyOpen
	hostKeyOpen = func(path string) (*os.File, error) {
		opened = append(opened, path)
		return orig(path)
	}
	t.Cleanup(func() { hostKeyOpen = orig })
	return &opened
}

func TestReadHostKeys_OnlyOpensPubFiles(t *testing.T) {
	dir := t.TempDir()
	edLine, edKey := testHostKeyLine(t, "ssh-ed25519", 32)
	rsaLine, rsaKey := testHostKeyLine(t, "ssh-rsa", 64)
	writeFile(t, filepath.Join(dir, "ssh_host_ed25519_key"), privateKeyArmor())
	writeFile(t, filepath.Join(dir, "ssh_host_ed25519_key.pub"), edLine)
	writeFile(t, filepath.Join(dir, "ssh_host_rsa_key"), privateKeyArmor())
	writeFile(t, filepath.Join(dir, "ssh_host_rsa_key.pub"), rsaLine)
	// A .pub name that is really a symlink to a private key must not be
	// followed.
	writeFile(t, filepath.Join(dir, "ssh_host_ecdsa_key"), privateKeyArmor())
	if err := os.Symlink(filepath.Join(dir, "ssh_host_ecdsa_key"), filepath.Join(dir, "ssh_host_ecdsa_key.pub")); err != nil {
		t.Fatalf("symlink: %v", err)
	}
	opened := recordOpens(t)

	keys, errs := ReadHostKeys(dir)

	for _, p := range *opened {
		if !strings.HasSuffix(p, ".pub") {
			t.Errorf("opened a non-.pub file: %s", p)
		}
		if strings.HasSuffix(p, "ssh_host_ecdsa_key.pub") {
			t.Errorf("opened a symlinked .pub: %s", p)
		}
	}
	if len(*opened) != 2 {
		t.Errorf("opened %d files, want exactly the 2 regular .pub files: %v", len(*opened), *opened)
	}
	if len(keys) != 2 || keys[0].Type != "ssh-ed25519" || keys[0].Key != edKey || keys[1].Type != "ssh-rsa" || keys[1].Key != rsaKey {
		t.Fatalf("keys = %+v, want ed25519 then rsa", keys)
	}
	if len(errs) != 1 {
		t.Errorf("the symlinked .pub must be reported as refused, got %v", errs)
	}
}

func TestReadHostKeys_RefusesPrivateKeyContentInPub(t *testing.T) {
	dir := t.TempDir()
	armor := privateKeyArmor()
	writeFile(t, filepath.Join(dir, "ssh_host_ed25519_key.pub"), armor)

	keys, errs := ReadHostKeys(dir)

	if len(keys) != 0 {
		t.Fatalf("private-key content must never be reported, got %+v", keys)
	}
	if len(errs) != 1 || !errors.Is(errs[0], errPrivateKeyShaped) {
		t.Fatalf("want errPrivateKeyShaped, got %v", errs)
	}
	if strings.Contains(errs[0].Error(), "AAAA") || strings.Contains(errs[0].Error(), "BEGIN") {
		t.Errorf("the error must never echo file content: %q", errs[0].Error())
	}
}

func TestParseHostKeyLine_Format(t *testing.T) {
	good, goodKey := testHostKeyLine(t, "ssh-ed25519", 32)
	_, rsaKey := testHostKeyLine(t, "ssh-rsa", 64)

	if k, err := parseHostKeyLine([]byte(good)); err != nil || k.Type != "ssh-ed25519" || k.Key != goodKey {
		t.Fatalf("a valid line must parse: %+v, %v", k, err)
	}
	if _, err := parseHostKeyLine([]byte("ssh-ed25519 " + goodKey)); err != nil {
		t.Errorf("a line with no comment and no trailing newline is valid: %v", err)
	}

	bad := map[string]string{
		"empty":                "",
		"type only":            "ssh-ed25519\n",
		"unknown type":         "ssh-dss " + goodKey + "\n",
		"not base64":           "ssh-ed25519 not*base64\n",
		"embedded mismatch":    "ssh-ed25519 " + rsaKey + "\n",
		"second line":          good + "ssh-ed25519 " + goodKey + "\n",
		"carriage return":      "ssh-ed25519 " + goodKey + "\r@cert-authority * x\n",
		"control char comment": "ssh-ed25519 " + goodKey + " root\x1b[2J\n",
		"nul":                  "ssh-ed25519 " + goodKey + "\x00\n",
	}
	for name, line := range bad {
		if k, err := parseHostKeyLine([]byte(line)); err == nil {
			t.Errorf("%s: must be refused, got %+v", name, k)
		}
	}
}

func TestReadHostKeys_SizeCap(t *testing.T) {
	dir := t.TempDir()
	// A file past the byte cap is refused without being parsed.
	line, _ := testHostKeyLine(t, "ssh-rsa", hostKeyMaxFileBytes)
	writeFile(t, filepath.Join(dir, "ssh_host_rsa_key.pub"), line)

	keys, errs := ReadHostKeys(dir)
	if len(keys) != 0 || len(errs) != 1 {
		t.Fatalf("an oversized file must be refused: keys=%+v errs=%v", keys, errs)
	}

	// A key whose base64 exceeds the key cap is refused even inside the file
	// cap.
	blob := testHostKeyBlob(t, "ssh-rsa", hostKeyMaxKeyChars)
	big := "ssh-rsa " + base64.StdEncoding.EncodeToString(blob)
	if len(big) > hostKeyMaxFileBytes {
		t.Fatalf("fixture too large for the key-cap case: %d", len(big))
	}
	if _, err := parseHostKeyLine([]byte(big)); err == nil {
		t.Errorf("a key over hostKeyMaxKeyChars must be refused")
	}
}

func TestReadHostKeys_MissingDirIsNotMeasured(t *testing.T) {
	keys, errs := ReadHostKeys(filepath.Join(t.TempDir(), "absent"))
	if keys != nil || len(errs) != 0 {
		t.Fatalf("no host keys must be nil (omitted on the wire), got %+v %v", keys, errs)
	}
}

func TestBuildHeartbeat_CarriesSSHHostKeys(t *testing.T) {
	dir := t.TempDir()
	line, key := testHostKeyLine(t, "ssh-ed25519", 32)
	writeFile(t, filepath.Join(dir, "ssh_host_ed25519_key.pub"), line)
	svc := testService(t)
	svc.hostKeyDir = dir

	payload := svc.buildHeartbeat("boot-1", nil)

	if len(payload.SSHHostKeys) != 1 || payload.SSHHostKeys[0].Key != key {
		t.Fatalf("heartbeat must carry the host key, got %+v", payload.SSHHostKeys)
	}
}

func TestHeartbeater_Send_CarriesSSHHostKeysOnTheWire(t *testing.T) {
	_, key := testHostKeyLine(t, "ssh-ed25519", 32)
	var got map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewDecoder(r.Body).Decode(&got)
		_, _ = w.Write([]byte(`{"success":true,"data":{"acknowledged":true}}`))
	}))
	defer srv.Close()

	h := &Heartbeater{
		Client: &transport.Client{Client: srv.Client(), PlatformURL: srv.URL},
		BuildPayload: func() HeartbeatPayload {
			return HeartbeatPayload{BootID: "b", AgentVersion: "v",
				SSHHostKeys: []HostKey{{Type: "ssh-ed25519", Key: key}}}
		},
	}
	if _, err := h.Send(context.Background()); err != nil {
		t.Fatalf("Send: %v", err)
	}

	entries, ok := got["ssh_host_keys"].([]any)
	if !ok || len(entries) != 1 {
		t.Fatalf("ssh_host_keys must ride the heartbeat, got %v", got["ssh_host_keys"])
	}
	entry := entries[0].(map[string]any)
	if entry["type"] != "ssh-ed25519" || entry["key"] != key || len(entry) != 2 {
		t.Errorf("wire entry = %v, want exactly {type, key}", entry)
	}

	// Absent keys are omitted, never an empty-but-present list.
	h.BuildPayload = func() HeartbeatPayload { return HeartbeatPayload{BootID: "b", AgentVersion: "v"} }
	got = nil
	if _, err := h.Send(context.Background()); err != nil {
		t.Fatalf("Send: %v", err)
	}
	if _, present := got["ssh_host_keys"]; present {
		t.Errorf("no host keys must be omitted from the wire, got %v", got["ssh_host_keys"])
	}
}
