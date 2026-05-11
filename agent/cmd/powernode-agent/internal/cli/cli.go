package cli

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/enroll"
	"github.com/nodealchemy/powernode-system/agent/internal/fleetevent"
	"github.com/nodealchemy/powernode-system/agent/internal/identity"
	"github.com/nodealchemy/powernode-system/agent/internal/transport"
)

// Context bundles the shared resources every CLI command may need:
// the mTLS transport client, a fleet event emitter, the resolved
// PlatformURL, and the start time for duration metrics.
//
// Built once via BuildContext (typically in PersistentPreRunE) and
// stashed in the cobra context so individual command implementations
// don't repeat the construction logic.
type Context struct {
	Transport *transport.Client
	Emitter   *fleetevent.Emitter
	Platform  string
	StartedAt time.Time
}

// BuildContext loads the mTLS material from PKIDir + PlatformURL and
// returns a fully-wired Context. PlatformURL takes precedence over
// any identity-discovered URL — commands run by an operator pin the
// URL via flag rather than re-discovering identity each invocation.
//
// When platformURL is empty, falls back to identity discovery
// (virtio-fw-cfg, kernel cmdline, cloud-init, local identity.cfg)
// via identity.DefaultResolver — same path runtime.Service uses
// during bootstrap. This lets operator CLI commands (`update`, `sync`,
// `attach`, `exec`, etc.) work on a provisioned node without the
// operator having to know or type --platform-url.
//
// pkiDir defaults to enroll.PKIDir when empty.
func BuildContext(platformURL, pkiDir string) (*Context, error) {
	if platformURL == "" {
		ident, err := identity.DefaultResolver().Resolve(context.Background())
		if err != nil {
			return nil, fmt.Errorf("BuildContext: platform-url not set and identity discovery failed: %w (pass --platform-url or run on a provisioned node)", err)
		}
		if ident == nil || ident.PlatformURL == "" {
			return nil, errors.New("BuildContext: platform-url not set and identity discovery returned no PlatformURL (pass --platform-url or check fw-cfg/identity.cfg)")
		}
		platformURL = ident.PlatformURL
	}
	if pkiDir == "" {
		pkiDir = enroll.PKIDir
	}
	paths := enroll.PathsUnder(pkiDir)
	client, err := transport.LoadFromPKIDir(platformURL, paths)
	if err != nil {
		return nil, fmt.Errorf("load mTLS client: %w", err)
	}
	return &Context{
		Transport: client,
		Emitter:   fleetevent.New(client),
		Platform:  platformURL,
		StartedAt: time.Now(),
	}, nil
}
