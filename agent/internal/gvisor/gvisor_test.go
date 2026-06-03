package gvisor

import (
	"context"
	"crypto/sha512"
	"encoding/hex"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

type fakeRunner struct {
	version string
	fail    bool
}

func (f fakeRunner) Run(_ context.Context, _ string, _ ...string) error { return nil }
func (f fakeRunner) Output(_ context.Context, _ string, _ ...string) ([]byte, error) {
	if f.fail {
		return nil, errors.New("runsc not found")
	}
	return []byte(f.version), nil
}

func TestMergeRuntimes(t *testing.T) {
	cfg := map[string]any{}
	if !MergeRuntimes(cfg, "/usr/local/bin/runsc") {
		t.Fatal("expected change on empty cfg")
	}
	rt := cfg["runtimes"].(map[string]any)
	if rt["runsc"].(map[string]any)["path"] != "/usr/local/bin/runsc" {
		t.Fatalf("runsc not registered: %v", rt)
	}
	// idempotent
	if MergeRuntimes(cfg, "/usr/local/bin/runsc") {
		t.Fatal("expected no change on re-merge")
	}
	// preserves other runtimes
	cfg2 := map[string]any{"runtimes": map[string]any{"kata": map[string]any{"path": "/x"}}}
	if !MergeRuntimes(cfg2, "") {
		t.Fatal("expected change adding runsc alongside kata")
	}
	rt2 := cfg2["runtimes"].(map[string]any)
	if _, ok := rt2["kata"]; !ok {
		t.Fatal("clobbered the existing kata runtime")
	}
	if _, ok := rt2["runsc"]; !ok {
		t.Fatal("runsc missing after merge")
	}
}

func TestDetect(t *testing.T) {
	cfg := map[string]any{"runtimes": map[string]any{"runsc": map[string]any{"path": "/usr/local/bin/runsc"}}}
	st := Detect(context.Background(), fakeRunner{version: "runsc version release-20240101.0\n  spec: 1.1.0\n"}, "", cfg)
	if !st.Available() || !st.BinaryPresent || !st.Registered {
		t.Fatalf("expected available, got %+v", st)
	}
	if st.Version != "runsc version release-20240101.0" {
		t.Fatalf("version: %q", st.Version)
	}

	st2 := Detect(context.Background(), fakeRunner{fail: true}, "", map[string]any{})
	if st2.Available() || st2.BinaryPresent || st2.Registered {
		t.Fatalf("expected unavailable, got %+v", st2)
	}
}

func TestInstall(t *testing.T) {
	runscBytes := []byte("#!/bin/true\nfake runsc binary\n")
	sum := sha512.Sum512(runscBytes)
	sumLine := hex.EncodeToString(sum[:]) + "  runsc\n"

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch filepath.Base(r.URL.Path) {
		case "runsc":
			_, _ = w.Write(runscBytes)
		case "runsc.sha512":
			_, _ = w.Write([]byte(sumLine))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()

	binPath := filepath.Join(t.TempDir(), "runsc")
	if err := Install(context.Background(), InstallOptions{BinaryPath: binPath, ReleaseBase: srv.URL, Arch: "amd64"}); err != nil {
		t.Fatalf("install: %v", err)
	}
	got, _ := os.ReadFile(binPath)
	if string(got) != string(runscBytes) {
		t.Fatal("installed bytes mismatch")
	}
	fi, _ := os.Stat(binPath)
	if fi.Mode().Perm()&0o100 == 0 {
		t.Fatalf("runsc not executable: %v", fi.Mode())
	}
}

func TestInstall_ChecksumMismatch(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if filepath.Base(r.URL.Path) == "runsc.sha512" {
			_, _ = w.Write([]byte("deadbeef  runsc\n"))
			return
		}
		_, _ = w.Write([]byte("real-but-unmatched-bytes"))
	}))
	defer srv.Close()

	err := Install(context.Background(), InstallOptions{BinaryPath: filepath.Join(t.TempDir(), "runsc"), ReleaseBase: srv.URL, Arch: "amd64"})
	if err == nil {
		t.Fatal("expected a checksum mismatch error")
	}
	if _, statErr := os.Stat(filepath.Join(t.TempDir(), "runsc")); statErr == nil {
		t.Fatal("binary must not be written on checksum failure")
	}
}

func TestEnsureInstalled_SkipsWhenPresent(t *testing.T) {
	installed, err := EnsureInstalled(context.Background(), fakeRunner{version: "runsc version x"}, InstallOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if installed {
		t.Fatal("should not install when runsc already runnable")
	}
}

func TestArchToken(t *testing.T) {
	if archToken("amd64") != "x86_64" {
		t.Fatal("amd64 -> x86_64")
	}
	if archToken("arm64") != "aarch64" {
		t.Fatal("arm64 -> aarch64")
	}
}
