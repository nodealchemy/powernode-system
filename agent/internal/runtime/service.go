package runtime

import (
	"context"
	"crypto/rand"
	"crypto/x509"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/dockerd"
	"github.com/nodealchemy/powernode-system/agent/internal/enroll"
	"github.com/nodealchemy/powernode-system/agent/internal/identity"
	"github.com/nodealchemy/powernode-system/agent/internal/k3sd"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/oci"
	"github.com/nodealchemy/powernode-system/agent/internal/runtime/tasks"
	"github.com/nodealchemy/powernode-system/agent/internal/runtime/tasks/handlers"
	"github.com/nodealchemy/powernode-system/agent/internal/sdwan"
	"github.com/nodealchemy/powernode-system/agent/internal/transport"
	"github.com/nodealchemy/powernode-system/agent/internal/verify"
)

// pemDecode + x509ParseCertificate are package-level aliases so the
// `readCertCN` helper isn't a magnet for accidental re-imports of
// pem/x509 elsewhere — keeps the import surface obvious.
var pemDecode = pem.Decode

func x509ParseCertificate(der []byte) (*x509.Certificate, error) {
	return x509.ParseCertificate(der)
}

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

	// Apply operator-supplied hostname from fw-cfg. Best-effort: read-only
	// rootfs (overlayfs lower) means /etc/hostname can't be persisted, so
	// we use hostnamectl --transient (lasts the boot lifetime; agent re-
	// applies on each boot). Skipped silently if instance_name is absent
	// (e.g. running on a non-libvirt provider that hasn't been retrofitted).
	if err := s.applyHostnameFromFwCfg(); err != nil {
		s.cfg.OnError("hostname_apply", err)
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

	// Phase B docker daemon reconciler — same shape as SDWAN. Inherits
	// the heartbeat's cadence, mTLS auth, and OnError surface. Sourcing
	// the overlay address from sdwanMgr means we don't need a second
	// /config/sdwan fetch — the docker tick reuses what SDWAN already
	// has in memory. Empty address on first boot is expected; the
	// docker manager defers daemon startup transitions until SDWAN
	// populates it (errWaitingOverlay is a soft signal).
	dockerMgr := dockerd.NewManager(
		dockerd.NewClient(client),
		dockerd.NewHTTPModulesClient(client),
		dockerd.NewShellApplier(),
		client.InstanceID,
		"", // populated by SetOverlayAddress() each tick
		s.cfg.OnError,
	)

	// Phase 2 K3s reconcilers — server + agent run side-by-side. At
	// most one of them will see its module assigned per-instance
	// (k3s-server vs k3s-agent are mutually exclusive in practice),
	// so the inactive manager just no-ops. Sharing the modules
	// client + transport keeps tick overhead minimal. Reuses
	// dockerd.HTTPModulesClient via Go's structural typing — no
	// cross-package coupling beyond the ModulesAPI shape.
	k3sModules := dockerd.NewHTTPModulesClient(client)
	k3sClient := k3sd.NewClient(client)
	k3sServerMgr := k3sd.NewServerManager(
		k3sClient, k3sModules, k3sd.NewShellServerApplier(),
		client.InstanceID, s.cfg.OnError,
	)
	k3sAgentMgr := k3sd.NewAgentManager(
		k3sClient, k3sModules, k3sd.NewShellAgentApplier(),
		client.InstanceID, s.cfg.OnError,
	)

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
			// Order matters: SDWAN must reconcile FIRST so the docker
			// reconciler sees a fresh overlay address. The address is
			// snapshotted into dockerMgr each tick so multi-network
			// rebalancing (Phase 2 K8s) just falls out.
			dockerMgr.SetOverlayAddress(sdwanMgr.FirstOverlayAddress())
			dockerMgr.Reconcile(ctx)
			// Phase 2 K3s — both managers run each tick; the one
			// whose module isn't assigned no-ops in its first switch
			// branch. Order doesn't matter for correctness; we run
			// server before agent so a co-located deployment (rare)
			// gets a slightly better convergence shape.
			k3sServerMgr.Reconcile(ctx)
			k3sAgentMgr.Reconcile(ctx)
		},
	}

	// Phase 1 module reconciler — runs in its own goroutine on its own
	// cadence (60s ±10% jitter, separate from the heartbeat loop). Pulls
	// modules, diffs vs state.json, attaches/detaches with cosign + fs-
	// verity verification. Wired with verify.AlwaysOK as a Phase 1
	// development default so the agent boots without a real cosign
	// signing key; production deployments will swap in a real
	// CosignVerifier once the M1 publish pipeline ships signatures.
	reconciler, err := NewReconciler(ReconcilerConfig{
		ModulesClient:  client,
		ManifestClient: client,
		ManifestRoot:   manifest.DefaultRoot,
		Puller: &oci.Puller{
			Transport:   client,
			HTTPClient:  client.Client,
			PlatformURL: client.PlatformURL,
			Cache:       "/persist/cache/modules",
			AuthHeader:  bearerHeader(client.InstanceToken),
		},
		Verifier:    verify.AlwaysOK{},
		MountRunner: mount.ExecRunner{},
		Layout:      mount.DefaultLayout(),
		StatePath:   s.cfg.StatePath,
		Interval:    60 * time.Second,
		OnError:     s.cfg.OnError,
	})
	if err != nil {
		return fmt.Errorf("build reconciler: %w", err)
	}

	var wg sync.WaitGroup
	spawn := func(name string, fn func()) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			defer func() {
				if r := recover(); r != nil {
					s.cfg.OnError(name+"_panic", fmt.Errorf("panic: %v", r))
				}
			}()
			fn()
		}()
	}

	// Phase 1 cert rotation goroutine. Refreshes the agent's mTLS cert
	// before NotAfter via POST /enroll/refresh authenticated by the
	// existing cert. Subject is read from the on-disk cert's CN — the
	// platform's IntervalCaService will preserve subject/CN across
	// rotations so the same NodeInstance remains addressable.
	//
	// Wraps the bootstrap client in a SwappableClient so the rotator
	// can publish a fresh transport after a successful refresh
	// without coordinating with the heartbeat / reconciler loops.
	swap := transport.NewSwappableClient(client)
	subject := readCertCN(paths.Cert)
	rotator, err := NewCertRotator(&CertRotator{
		PKIPaths:     paths,
		PlatformURL:  client.PlatformURL,
		Transport:    swap,
		Subject:      subject,
		AgentVersion: s.cfg.AgentVersion,
		OnError:      s.cfg.OnError,
	})
	if err != nil {
		// A bad rotator config is not fatal — the agent can run
		// indefinitely on the existing cert until NotAfter. Log and
		// proceed without the rotation goroutine.
		s.cfg.OnError("cert_rotation_init", err)
		rotator = nil
	}

	spawn("heartbeat", func() {
		heartbeat.Run(ctx, s.cfg.HeartbeatInterval, func(err error) {
			s.cfg.OnError("heartbeat", err)
		})
	})
	spawn("reconciler", func() {
		reconciler.Run(ctx)
	})
	if rotator != nil {
		spawn("cert_rotation", func() {
			rotator.Run(ctx)
		})
	}

	// Phase 1 task lease loop. Polls /status/tasks every ~20s,
	// dispatches each new task to a TaskHandler, persists inflight
	// state for crash recovery. Concurrency=1 (matches legacy ipn —
	// most node ops mutate state, parallelism risks deadlock matrices).
	taskRegistry := tasks.NewRegistry()
	handlers.RegisterDefaults(taskRegistry, tasks.Dependencies{
		Transport:    swap,
		MountRunner:  mount.ExecRunner{},
		Reconciler:   reconciler,
		AgentVersion: s.cfg.AgentVersion,
	})
	taskLoop, err := tasks.NewLoop(tasks.LoopConfig{
		Client:      tasks.NewClient(swap),
		Registry:    taskRegistry,
		Concurrency: 1,
		OnError:     s.cfg.OnError,
	})
	if err != nil {
		s.cfg.OnError("task_lease_init", err)
	} else {
		spawn("task_lease", func() {
			taskLoop.Run(ctx)
		})
	}

	wg.Wait()
	return nil
}

// readCertCN parses the leaf cert at path and returns its CN. Returns
// the empty string when the cert can't be read or parsed — the caller
// (cert rotator) treats empty CN as a fatal init error.
func readCertCN(path string) string {
	body, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	block, _ := pemDecode(body)
	if block == nil {
		return ""
	}
	cert, err := x509ParseCertificate(block.Bytes)
	if err != nil {
		return ""
	}
	return cert.Subject.CommonName
}

// bearerHeader wraps a token for HTTP Authorization. Returns empty
// when token is empty so the OCI puller doesn't send a stray header.
func bearerHeader(token string) string {
	if token == "" {
		return ""
	}
	return "Bearer " + token
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

// fetchAuthorizedKeys is the Service-bound wrapper around the
// top-level FetchAuthorizedKeys function. The function lives in
// authorized_keys.go so the sync CLI can call it without instantiating
// a Service struct; this method preserves the existing call shape from
// Run() and the heartbeat PostSend hook.
func (s *Service) fetchAuthorizedKeys(ctx context.Context, client *transport.Client) error {
	return FetchAuthorizedKeys(ctx, AuthorizedKeysOptions{
		Client: client,
		OnWarn: s.cfg.OnError,
	})
}

// applyHostnameFromFwCfg reads instance_name from virtio-fw-cfg and applies
// it as the host's transient hostname (`hostnamectl set-hostname --transient`).
// We use --transient because the modules root is overlayfs-mounted with the
// lower layer read-only, so writing /etc/hostname directly fails. Calling
// this on every agent boot keeps the hostname stable across reboots without
// needing a writable upper-layer hostname file.
//
// Returns nil silently when the fw-cfg entry is absent (older provisioning
// runs, non-libvirt providers, or instance.name was empty server-side).
func (s *Service) applyHostnameFromFwCfg() error {
	const fwcfgPath = "/sys/firmware/qemu_fw_cfg/by_name/opt/com.powernode/instance_name/raw"
	raw, err := os.ReadFile(fwcfgPath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil // not a libvirt boot OR pre-instance_name fw-cfg seed
		}
		return fmt.Errorf("read instance_name fw-cfg: %w", err)
	}
	name := strings.TrimSpace(string(raw))
	if name == "" {
		return nil
	}
	// `hostnamectl set-hostname --transient` is best-effort. On a writable
	// rootfs (e.g. cloud images), drop --transient to make it persistent;
	// here we always use --transient because the platform's overlay-rootfs
	// node images don't have a writable /etc.
	cmd := exec.CommandContext(context.Background(), "hostnamectl", "set-hostname", "--transient", name)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("hostnamectl set-hostname %q: %w (%s)", name, err, strings.TrimSpace(string(out)))
	}
	return nil
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
