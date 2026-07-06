package runtime

import (
	"context"
	"testing"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/enroll"
)

// TestBootstrap_AdoptsOnDiskCertBeforeResolver proves the post-switch_root
// fix: when a valid enrolled cert + meta.json (carrying the platform URL)
// already exist on disk, bootstrap adopts them WITHOUT running the discovery
// resolver — even when started with no --platform-url flag.
//
// The guard is an already-cancelled context. Step 0 (the on-disk fast path)
// never consults ctx, so it still returns a client; the pre-fix code called
// identity.DefaultResolver().Resolve(ctx) first, which honors the cancelled
// ctx and would fail here. So a green result is specific evidence that the
// cert-adoption path ran before (and instead of) the claim-capable resolver.
func TestBootstrap_AdoptsOnDiskCertBeforeResolver(t *testing.T) {
	dir := t.TempDir()
	paths := enroll.PathsUnder(dir)

	certPEM, keyPEM := mintCert(t, "node-under-test",
		time.Now().Add(-time.Hour), time.Now().Add(time.Hour))

	const wantURL = "https://platform.adopt.test"
	writeFile(t, paths.Key, string(keyPEM))
	writeFile(t, paths.Cert, string(certPEM))
	writeFile(t, paths.CABundle, string(certPEM)) // any parseable cert satisfies the CA pool
	writeFile(t, paths.Meta, `{"instance_id":"inst-adopt","platform_url":"`+wantURL+`"}`)

	// PlatformURL deliberately empty — it must come from the persisted meta.json.
	s := New(Config{PKIDir: dir})

	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	client, err := s.bootstrap(ctx, paths)
	if err != nil {
		t.Fatalf("bootstrap should adopt the on-disk cert without the resolver, got: %v", err)
	}
	if client.PlatformURL != wantURL {
		t.Errorf("client.PlatformURL = %q, want %q (from meta.json)", client.PlatformURL, wantURL)
	}
	if s.cfg.PlatformURL != wantURL {
		t.Errorf("s.cfg.PlatformURL = %q, want %q (adopted URL should be recorded)", s.cfg.PlatformURL, wantURL)
	}
}
