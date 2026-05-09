package cli

import (
	"errors"
	"fmt"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/enroll"
	"github.com/nodealchemy/powernode-system/agent/internal/fleetevent"
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
// any identity-discovered URL (commands run by an operator pin the
// URL via flag rather than re-discovering identity each invocation).
//
// pkiDir defaults to enroll.PKIDir when empty.
func BuildContext(platformURL, pkiDir string) (*Context, error) {
	if platformURL == "" {
		return nil, errors.New("BuildContext: platform-url is required (set --platform-url or run identity discovery first)")
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
