package fsutil

import (
	"os"
	"path/filepath"
	"testing"
)

func TestAtomicWriteCreatesFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	data := []byte(`{"key":"value"}`)

	if err := AtomicWrite(path, data, 0o644); err != nil {
		t.Fatalf("AtomicWrite: %v", err)
	}

	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if string(got) != string(data) {
		t.Errorf("content mismatch: got %q want %q", got, data)
	}

	st, err := os.Stat(path)
	if err != nil {
		t.Fatalf("Stat: %v", err)
	}
	if st.Mode().Perm() != 0o644 {
		t.Errorf("mode: got %v want 0644", st.Mode().Perm())
	}
}

func TestAtomicWriteOverwritesExisting(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "data.txt")

	if err := os.WriteFile(path, []byte("original"), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if err := AtomicWrite(path, []byte("replaced"), 0o600); err != nil {
		t.Fatalf("AtomicWrite: %v", err)
	}

	got, _ := os.ReadFile(path)
	if string(got) != "replaced" {
		t.Errorf("content not replaced: got %q", got)
	}
	st, _ := os.Stat(path)
	if st.Mode().Perm() != 0o600 {
		t.Errorf("mode not updated: got %v", st.Mode().Perm())
	}
}

func TestAtomicWriteSecretMode(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "secret.key")

	if err := AtomicWrite(path, []byte("PRIVATE KEY"), 0o600); err != nil {
		t.Fatalf("AtomicWrite: %v", err)
	}
	st, _ := os.Stat(path)
	if st.Mode().Perm() != 0o600 {
		t.Fatalf("secret file leaked permissions: got %v want 0600", st.Mode().Perm())
	}
}

func TestAtomicWriteLeavesNoTempOnSuccess(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "ok.txt")
	if err := AtomicWrite(path, []byte("hi"), 0o644); err != nil {
		t.Fatalf("AtomicWrite: %v", err)
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 1 {
		t.Errorf("expected 1 entry, got %d: %v", len(entries), entries)
	}
}

func TestAtomicWriteParentDirMissing(t *testing.T) {
	// AtomicWrite does NOT mkdir — caller's responsibility. Match the
	// behavior of the original dockerd.atomicWrite so callers that
	// assumed mkdir-elsewhere don't break.
	dir := t.TempDir()
	path := filepath.Join(dir, "missing-subdir", "file.txt")
	if err := AtomicWrite(path, []byte("x"), 0o644); err == nil {
		t.Errorf("AtomicWrite should fail when parent dir missing")
	}
}

func TestAtomicWriteJSONRoundTrip(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state.json")

	type record struct {
		Name  string `json:"name"`
		Count int    `json:"count"`
	}
	want := record{Name: "agent", Count: 42}

	if err := AtomicWriteJSON(path, want, 0o600); err != nil {
		t.Fatalf("AtomicWriteJSON: %v", err)
	}

	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if string(body) != `{"name":"agent","count":42}` {
		t.Errorf("unexpected body: %q", body)
	}

	st, _ := os.Stat(path)
	if st.Mode().Perm() != 0o600 {
		t.Errorf("mode: got %v want 0600", st.Mode().Perm())
	}
}

func TestAtomicWriteJSONMarshalError(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "bad.json")

	// Channels can't be marshaled — exercise the error path.
	ch := make(chan int)
	if err := AtomicWriteJSON(path, ch, 0o644); err == nil {
		t.Errorf("expected marshal error for channel")
	}

	// File should not exist when marshal fails.
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Errorf("file leaked on marshal error: %v", err)
	}
}
