package storage

import (
	"context"
	"encoding/base64"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// stubGetter implements httpGetter, returning a canned key envelope.
type stubGetter struct {
	body string
	err  error
}

func (s stubGetter) GetJSON(_ string) (*http.Response, error) {
	if s.err != nil {
		return nil, s.err
	}
	return &http.Response{
		StatusCode: 200,
		Body:       io.NopCloser(strings.NewReader(s.body)),
	}, nil
}

func keyEnvelope(rawKey string) string {
	return fmt.Sprintf(`{"success":true,"data":{"key_material":%q,"algorithm":"fscrypt-v2"}}`,
		base64.StdEncoding.EncodeToString([]byte(rawKey)))
}

func fscryptTask() *MountTask {
	return &MountTask{
		AssignmentID: "assign-abcdef0123456789",
		MountPath:    "/mnt/data",
		Encryption:   EncryptionSpec{Mode: "fscrypt", KeyURL: "/key"},
	}
}

func TestSetupEncryption_NoneIsNoOp(t *testing.T) {
	r := &mount.RecorderRunner{}
	task := &MountTask{Encryption: EncryptionSpec{Mode: "none"}}
	if err := SetupEncryption(context.Background(), r, stubGetter{}, task); err != nil {
		t.Fatalf("none mode should be a no-op, got %v", err)
	}
	if len(r.Invocations) != 0 {
		t.Fatalf("none mode should issue no commands, got %v", r.Invocations)
	}
}

func TestSetupFscrypt_AppliesPolicy(t *testing.T) {
	keyDir = t.TempDir() // redirect transient keyfile off /run for CI
	r := &mount.RecorderRunner{}
	getter := stubGetter{body: keyEnvelope("super-secret-key-material")}

	if err := SetupEncryption(context.Background(), r, getter, fscryptTask()); err != nil {
		t.Fatalf("expected success, got %v", err)
	}

	var sawSetup, sawEncrypt bool
	for _, inv := range r.Invocations {
		if inv.Name != "fscrypt" {
			continue
		}
		switch {
		case len(inv.Args) > 0 && inv.Args[0] == "setup":
			sawSetup = true
		case len(inv.Args) > 0 && inv.Args[0] == "encrypt":
			sawEncrypt = true
			joined := strings.Join(inv.Args, " ")
			if !strings.Contains(joined, "/mnt/data") || !strings.Contains(joined, "--source=raw_key") {
				t.Errorf("encrypt missing target/source: %v", inv.Args)
			}
		}
	}
	if !sawSetup || !sawEncrypt {
		t.Errorf("expected fscrypt setup AND encrypt; setup=%v encrypt=%v", sawSetup, sawEncrypt)
	}
}

// Fail-closed: an empty key must error, never silently succeed (F6-02).
func TestSetupFscrypt_EmptyKeyFailsClosed(t *testing.T) {
	r := &mount.RecorderRunner{}
	getter := stubGetter{body: `{"success":true,"data":{"key_material":""}}`}
	if err := SetupEncryption(context.Background(), r, getter, fscryptTask()); err == nil {
		t.Fatal("empty key must fail closed, got nil")
	}
}

// Fail-closed: a missing key_url must error.
func TestSetupFscrypt_MissingKeyURLFailsClosed(t *testing.T) {
	r := &mount.RecorderRunner{}
	task := fscryptTask()
	task.Encryption.KeyURL = ""
	if err := SetupEncryption(context.Background(), r, stubGetter{}, task); err == nil {
		t.Fatal("missing key_url must fail closed, got nil")
	}
}

// Fail-closed: when `fscrypt setup` fails on an unsupported filesystem (e.g.
// a network mount), the whole setup must error so the mount task fails rather
// than serving plaintext under an "encrypted" label. The setup command is
// fully deterministic, so we can stub its failure exactly.
func TestSetupFscrypt_UnsupportedFilesystemFailsClosed(t *testing.T) {
	keyDir = t.TempDir()
	r := &mount.RecorderRunner{
		StubErr: map[string]error{
			"fscrypt setup --quiet /mnt/data": fmt.Errorf("filesystem does not support encryption"),
		},
	}
	getter := stubGetter{body: keyEnvelope("k")}
	if err := SetupEncryption(context.Background(), r, getter, fscryptTask()); err == nil {
		t.Fatal("fscrypt on an unsupported filesystem must fail closed, got nil")
	}
}

// Idempotency: an already-encrypted target is detected and skipped.
func TestSetupFscrypt_AlreadyEncryptedIsIdempotent(t *testing.T) {
	r := &mount.RecorderRunner{
		StubOutput: map[string][]byte{
			"fscrypt status /mnt/data": []byte("Encrypted: Yes"),
		},
	}
	getter := stubGetter{body: keyEnvelope("k")}
	if err := SetupEncryption(context.Background(), r, getter, fscryptTask()); err != nil {
		t.Fatalf("already-encrypted should be a no-op success, got %v", err)
	}
	for _, inv := range r.Invocations {
		if inv.Name == "fscrypt" && len(inv.Args) > 0 && inv.Args[0] == "encrypt" {
			t.Error("must not re-run fscrypt encrypt on an already-encrypted target")
		}
	}
}

// luks / client_side_aes are explicit errors, not silent no-ops.
func TestSetupEncryption_UnimplementedModesFailClosed(t *testing.T) {
	for _, mode := range []string{"luks", "client_side_aes", "bogus"} {
		r := &mount.RecorderRunner{}
		task := &MountTask{MountPath: "/mnt/data", Encryption: EncryptionSpec{Mode: mode}}
		if err := SetupEncryption(context.Background(), r, stubGetter{}, task); err == nil {
			t.Errorf("mode %q must return an error, got nil", mode)
		}
	}
}
