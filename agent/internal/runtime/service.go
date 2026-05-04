package runtime

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"runtime"
	"sync"
	"time"

	"github.com/powernode/platform/extensions/system/agent/internal/enroll"
	"github.com/powernode/platform/extensions/system/agent/internal/identity"
	"github.com/powernode/platform/extensions/system/agent/internal/mount"
	"github.com/powernode/platform/extensions/system/agent/internal/sdwan"
	"github.com/powernode/platform/extensions/system/agent/internal/transport"
)

// Config bundles the parameters that drive a long-lived service run.
type Config struct {
	PlatformURL       string
	AgentVersion      string
	HeartbeatInterval time.Duration
	PKIDir            string  // defaults to enroll.PKIDir
	StatePath         string  // defaults to mount.StatePath
	OnError           func(string, error)
}

// Service is the top-level long-running agent loop. Run blocks until
// ctx is canceled, then returns the first error any goroutine surfaced.
type Service struct {
	cfg Config
}

func New(cfg Config) *Service {
	if cfg.HeartbeatInterval <= 0 {
		cfg.HeartbeatInterval = 30 * time.Second
	}
	if cfg.PKIDir == "" {
		cfg.PKIDir = enroll.PKIDir
	}
	if cfg.StatePath == "" {
		cfg.StatePath = mount.StatePath
	}
	if cfg.OnError == nil {
		cfg.OnError = func(_ string, _ error) {}
	}
	return &Service{cfg: cfg}
}

// Run starts the service goroutines and blocks until ctx is canceled.
// Each goroutine handles its own retries; persistent errors are surfaced
// via cfg.OnError but don't abort the service (this is a long-running
// agent — we want graceful degradation, not crash-on-flake).
func (s *Service) Run(ctx context.Context) error {
	paths := enroll.PathsUnder(s.cfg.PKIDir)
	client, err := s.bootstrap(ctx, paths)
	if err != nil {
		return fmt.Errorf("bootstrap: %w", err)
	}

	// Fetch operator-supplied SSH keys from the platform once, immediately
	// after enrollment. Best-effort: failures don't abort the service since
	// heartbeat is the higher-priority loop. The same fetch runs on every
	// heartbeat tick (see Heartbeater.PostSend) so key rotation propagates
	// without an agent restart.
	if err := s.fetchAuthorizedKeys(ctx, client); err != nil {
		s.cfg.OnError("authorized_keys_initial", err)
	}

	bootID := generateBootID()
	startedAt := time.Now()

	// SDWAN reconciler — runs synchronously inside the heartbeat tick
	// (PostSend hook) so the cadence stays unified with module-digest +
	// authorized_keys propagation. Errors surface via the same OnError
	// channel; failures don't stop the heartbeat.
	sdwanMgr := sdwan.NewManager(client, nil, s.cfg.OnError)

	heartbeat := &Heartbeater{
		Client:    client,
		StartedAt: startedAt,
		BuildPayload: func() HeartbeatPayload {
			return s.buildHeartbeat(bootID, sdwanMgr)
		},
		PostSend: func() {
			if err := s.fetchAuthorizedKeys(ctx, client); err != nil {
				s.cfg.OnError("authorized_keys", err)
			}
			sdwanMgr.Reconcile(ctx)
		},
	}

	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		heartbeat.Run(ctx, s.cfg.HeartbeatInterval, func(err error) {
			s.cfg.OnError("heartbeat", err)
		})
	}()

	// Future goroutines (M2.E.x): task lease, cert rotation, reconcile.
	// Each follows the same shape as heartbeat — owns its loop, surfaces
	// errors via OnError, exits when ctx is canceled.

	wg.Wait()
	return nil
}

// buildHeartbeat snapshots current runtime state into a HeartbeatPayload.
// Reads agent state from disk so the heartbeat reflects what's actually
// mounted right now, not just the agent's last in-memory action.
func (s *Service) buildHeartbeat(bootID string, sdwanMgr *sdwan.Manager) HeartbeatPayload {
	st, err := mount.LoadState(s.cfg.StatePath)
	if err != nil {
		s.cfg.OnError("load_state", err)
		st = &mount.State{}
	}
	digests := map[string]string{}
	for _, m := range st.AttachedModules {
		digests[m.ID] = m.Digest
	}
	mountState := "unmounted"
	if st.UnionMounted {
		mountState = "mounted"
	}
	payload := HeartbeatPayload{
		BootID:        bootID,
		AgentVersion:  s.cfg.AgentVersion,
		Architecture:  runtime.GOARCH,
		ModuleDigests: digests,
		MountState:    mountState,
	}
	if sdwanMgr != nil {
		payload.SdwanState = sdwanMgr.HeartbeatStatuses()
	}
	return payload
}

// bootstrap ensures mTLS material exists at PKIDir. On first boot (no
// cert on disk) it discovers identity via the standard Resolver chain
// (kernel cmdline → virtio-fw-cfg → cloud metadata → local identity.cfg),
// trades the bootstrap token for an mTLS cert at /node_api/enroll, and
// persists the result so subsequent invocations skip enrollment.
//
// Order matters: identity discovery happens first so we can resolve the
// platform URL even when no flag was passed. Without a URL,
// transport.LoadFromPKIDir errors out and we can't take the fast path —
// causing a re-enroll attempt that burns the (already-consumed) bootstrap
// token. This is the post-switch_root path: cert exists on the bind-mounted
// /persist but no flag is set in the unit's ExecStart.
//
// Returns a transport.Client ready for mTLS-authenticated platform calls.
func (s *Service) bootstrap(ctx context.Context, paths enroll.PKIPaths) (*transport.Client, error) {
	// 1. Resolve platform URL — flag override first, then identity discovery.
	platformURL := s.cfg.PlatformURL
	var ident *identity.Identity
	if platformURL == "" {
		var err error
		ident, err = identity.DefaultResolver().Resolve(ctx)
		if err == nil && ident != nil && ident.PlatformURL != "" {
			platformURL = ident.PlatformURL
		}
	}

	// 2. Fast path: cert + key already on disk. Skip enroll when present —
	// crucial for post-switch_root boots where /persist survives the pivot.
	if platformURL != "" {
		if c, err := transport.LoadFromPKIDir(platformURL, paths); err == nil {
			s.cfg.PlatformURL = platformURL
			return c, nil
		}
	}

	// 3. Need to enroll. Discover identity if step 1 didn't already.
	if ident == nil {
		var err error
		ident, err = identity.DefaultResolver().Resolve(ctx)
		if err != nil {
			return nil, fmt.Errorf("identity discovery: %w", err)
		}
	}
	if ident.InstanceUUID == "" {
		return nil, errors.New("identity has empty InstanceUUID")
	}
	if ident.BootstrapToken == "" {
		return nil, errors.New("identity has no BootstrapToken (token consumed? cert missing from /persist?)")
	}

	// Re-resolve URL in case step 1 was skipped (flag set) but identity hadn't run yet.
	if platformURL == "" {
		platformURL = ident.PlatformURL
	}
	if platformURL == "" {
		return nil, errors.New("no PlatformURL from --platform-url flag or identity")
	}
	if len(ident.CABundlePEM) == 0 {
		return nil, errors.New("identity has no CABundlePEM (platform CA chain)")
	}

	enrollClient := &enroll.Client{
		PlatformURL:  platformURL,
		CABundlePEM:  []byte(ident.CABundlePEM),
		AgentVersion: s.cfg.AgentVersion,
	}
	enrolled, err := enrollClient.Enroll(ctx, enroll.EnrollRequest{
		BootstrapToken: ident.BootstrapToken,
		Subject:        ident.InstanceUUID,
	})
	if err != nil {
		return nil, fmt.Errorf("enroll: %w", err)
	}
	if err := enroll.Save(enrolled, paths); err != nil {
		return nil, fmt.Errorf("save enrollment: %w", err)
	}

	// Persist resolved URL so heartbeat (which reads s.cfg.PlatformURL via
	// transport.Client.PlatformURL) targets the right host.
	s.cfg.PlatformURL = platformURL

	return transport.LoadFromPKIDir(platformURL, paths)
}

// fetchAuthorizedKeys retrieves operator-supplied SSH keys from the platform's
// /node_api/config/authorized_keys endpoint and writes them to /root/.ssh/
// authorized_keys with the correct mode (0600 file, 0700 dir).
//
// Idempotent: writes only when the on-disk content differs from the platform
// response. Safe to call on every heartbeat tick — propagates key rotation
// without requiring an agent restart.
func (s *Service) fetchAuthorizedKeys(ctx context.Context, client *transport.Client) error {
	resp, err := client.GetJSON("/api/v1/system/node_api/config/authorized_keys")
	if err != nil {
		return fmt.Errorf("GET authorized_keys: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("authorized_keys status %d: %s", resp.StatusCode, string(body))
	}

	var ak struct {
		Success bool `json:"success"`
		Data    struct {
			AuthorizedKeys string `json:"authorized_keys"`
			KeysCount      int    `json:"keys_count"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &ak); err != nil {
		return fmt.Errorf("decode authorized_keys: %w", err)
	}

	const dir = "/root/.ssh"
	const path = "/root/.ssh/authorized_keys"
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("mkdir %s: %w", dir, err)
	}

	desired := ak.Data.AuthorizedKeys
	if desired != "" && desired[len(desired)-1] != '\n' {
		desired += "\n"
	}
	current, _ := os.ReadFile(path)
	if string(current) == desired {
		return nil
	}
	return os.WriteFile(path, []byte(desired), 0o600)
}

// generateBootID returns a fresh 64-bit random hex string used to
// distinguish boots in the heartbeat stream.
func generateBootID() string {
	var b [8]byte
	if _, err := rand.Read(b[:]); err != nil {
		// Fall back to a deterministic-but-unique value rather than
		// crashing the service.
		return fmt.Sprintf("boot-%d", time.Now().UnixNano())
	}
	return "boot-" + hex.EncodeToString(b[:])
}
