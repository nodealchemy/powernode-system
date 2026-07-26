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
	"runtime"
	"sync"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/a2a"
	"github.com/nodealchemy/powernode-system/agent/internal/dockerd"
	"github.com/nodealchemy/powernode-system/agent/internal/enroll"
	"github.com/nodealchemy/powernode-system/agent/internal/etcidentity"
	"github.com/nodealchemy/powernode-system/agent/internal/etcsudoers"
	"github.com/nodealchemy/powernode-system/agent/internal/identity"
	"github.com/nodealchemy/powernode-system/agent/internal/k3sd"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/migration"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/oci"
	"github.com/nodealchemy/powernode-system/agent/internal/runtime/tasks"
	"github.com/nodealchemy/powernode-system/agent/internal/runtime/tasks/handlers"
	"github.com/nodealchemy/powernode-system/agent/internal/sdwan"
	"github.com/nodealchemy/powernode-system/agent/internal/tcpfwd"
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
	PlatformURL          string
	AgentVersion         string
	HeartbeatInterval    time.Duration
	PKIDir               string   // defaults to enroll.ResolveDefaultPKIDir()
	StatePath            string   // defaults to mount.StatePath
	A2AListenAddr        string   // agent-to-agent MCP server listen addr (empty = disabled)
	A2AInferenceEndpoint string   // local inference runtime (ollama) for the A2A inference.* skills (empty = no inference skills)
	IsolationRuntimes    []string // isolation runtimes to provision on the docker daemon (e.g. ["gvisor"]) — substrate L0
	// AppHealthURL is the composed control-plane health endpoint the boot-LKG
	// capturer probes before promoting the frozen last-known-good (#39). Empty
	// defaults to defaultAppHealthURL (loopback Traefik → hub-backend /up).
	AppHealthURL string
	OnError      func(string, error)
}

// defaultAppHealthURL probes the composed control plane end-to-end over
// loopback: Traefik (:443) → hub-backend Rails /up. Verified on VM104 to return
// 200 anonymously (the /up health route is NOT behind the host-login mTLS gate),
// so no client cert is required — the probe only needs to skip server-name
// verification (the loopback IP won't match the node serving-cert SAN).
const defaultAppHealthURL = "https://127.0.0.1/up"

// Service is the top-level long-running agent loop. Run blocks until
// ctx is canceled, then returns the first error any goroutine surfaced.
type Service struct {
	cfg               Config
	capabilities      *NodeCapabilities
	bootedImageGitSHA string
}

func New(cfg Config) *Service {
	if cfg.HeartbeatInterval <= 0 {
		cfg.HeartbeatInterval = 30 * time.Second
	}
	if cfg.PKIDir == "" {
		cfg.PKIDir = enroll.ResolveDefaultPKIDir()
	}
	if cfg.StatePath == "" {
		cfg.StatePath = mount.StatePath
	}
	if cfg.OnError == nil {
		cfg.OnError = func(_ string, _ error) {}
	}
	// Detect kernel capabilities ONCE at construction. Stable across
	// the agent's lifetime — kernel features don't change without
	// a reboot, which restarts the agent process anyway. The booted disk
	// image's git_sha (campaign 019f505f) is likewise fixed for the life of
	// the boot, so it's read once here rather than per heartbeat.
	return &Service{
		cfg:               cfg,
		capabilities:      DetectCapabilities(),
		bootedImageGitSHA: identity.BootedImageGitSHA(),
	}
}

// Run starts the service goroutines and blocks until ctx is canceled.
// Each goroutine handles its own retries; persistent errors are surfaced
// via cfg.OnError but don't abort the service (this is a long-running
// agent — we want graceful degradation, not crash-on-flake).
func (s *Service) Run(ctx context.Context) error {
	// Break-glass: apply BEFORE bootstrap so it takes effect even when
	// the platform is unreachable, the JWT is expired, or the agent
	// itself is being recovered. Env-flag controlled
	// (POWERNODE_OPERATOR_BREAK_GLASS=1) so production deployments leave
	// it off and rely on module-declared SudoersGrant rows instead.
	// Idempotent: re-running with the same on-disk state is a no-op.
	if err := etcsudoers.ApplyOperatorBreakGlass(etcsudoers.OperatorBreakGlassEnabledFromEnv()); err != nil {
		s.cfg.OnError("operator_break_glass", err)
	}

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

	// AI/MCP workload substrate L2.5/L3 — the agent-to-agent (A2A) MCP server is
	// started below, after sdwanMgr is constructed, so its peer announcement can
	// advertise the node's reachable overlay address.

	bootID := generateBootID()
	startedAt := time.Now()

	// SDWAN reconciler — runs synchronously inside the heartbeat tick
	// (PostSend hook) so the cadence stays unified with module-digest +
	// authorized_keys propagation. Errors surface via the same OnError
	// channel; failures don't stop the heartbeat.
	sdwanMgr := sdwan.NewManager(client, nil, s.cfg.OnError)

	// AI/MCP workload substrate L2.5/L3 — agent-to-agent (A2A) MCP server.
	// Default-OFF: starts only when an operator configures a listen address.
	// Serves peer skill calls over mTLS, gated by platform-minted capability
	// tokens (verified offline against the advertised signing key). Announces
	// its offered skills + reachable overlay address to the platform so peer
	// discovery (discover_peers) can surface it.
	if s.cfg.A2AListenAddr != "" {
		reg := a2a.NewRegistry()
		a2a.RegisterStandardSkills(reg, a2a.StandardSkillOptions{
			Descriptor: func(skills []string) a2a.NodeDescriptor {
				return a2a.NodeDescriptor{
					InstanceID: readCertCN(paths.Cert),
					OS:         runtime.GOOS,
					Arch:       runtime.GOARCH,
					Skills:     skills,
				}
			},
			InferenceEndpoint: s.cfg.A2AInferenceEndpoint,
		})
		go func() {
			if err := a2a.Run(ctx, a2a.RunnerConfig{
				SelfInstanceID: readCertCN(paths.Cert),
				ListenAddr:     s.cfg.A2AListenAddr,
				CertFile:       paths.Cert,
				KeyFile:        paths.Key,
				CABundleFile:   paths.CAChain,
				Registry:       reg,
				Fetcher:        client,
				Announcer:      client,
				AdvertiseAddrs: func() []string { return a2aAdvertiseAddrs(sdwanMgr.FirstOverlayAddress(), s.cfg.A2AListenAddr) },
				OnError:        func(e error) { s.cfg.OnError("a2a", e) },
			}); err != nil {
				s.cfg.OnError("a2a", err)
			}
		}()
	}

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

	// Substrate L0 — provision the isolation runtimes this node needs (e.g.
	// gvisor) before the daemon starts: install runsc + register it in
	// daemon.json. Sources: static Config + the platform's per-node isolation
	// config (node_api/isolation/runtimes), derived from the instance's tier.
	isoCfg := fetchIsolationConfig(client)
	isoRuntimes := append([]string(nil), s.cfg.IsolationRuntimes...)
	isoRuntimes = append(isoRuntimes, isoCfg.Runtimes...)
	if len(isoRuntimes) > 0 {
		dockerMgr.RequestedRuntimes = isoRuntimes
		// F2-01 — the tier's OCI runtime becomes this daemon's default so
		// workload containers actually run under the recorded tier. Applied
		// by the manager only after the runtime registers successfully.
		dockerMgr.DefaultRuntime = isoCfg.DefaultRuntime
		// Composite: gVisor (runsc) self-installs; Kata/Firecracker microVM
		// runtimes validate their install + KVM. Each requested runtime is
		// dispatched to the handler that owns it; an unavailable one is logged
		// and skipped rather than blocking the daemon (substrate L0).
		dockerMgr.Runtimes = dockerd.CompositeRuntimeEnsurer{
			dockerd.GvisorRuntimeEnsurer{Runner: mount.ExecRunner{}},
			dockerd.KataRuntimeEnsurer{Runner: mount.ExecRunner{}},
		}
	}

	// Phase 2 K3s reconcilers — server + agent run side-by-side. At
	// most one of them will see its module assigned per-instance
	// (k3s-server vs k3s-agent are mutually exclusive in practice),
	// so the inactive manager just no-ops. Sharing the modules
	// client + transport keeps tick overhead minimal. Reuses
	// dockerd.HTTPModulesClient via Go's structural typing — no
	// cross-package coupling beyond the ModulesAPI shape.
	k3sModules := dockerd.NewHTTPModulesClient(client)
	k3sClient := k3sd.NewClient(client)
	// Phase O4 follow-up — agent-side BootstrapConfig fetcher. The
	// platform's runtime/k3s_server/config endpoint emits per-host
	// install knobs (cni_plugin today; future fields like cluster-cidr
	// land in the same envelope). The PostSend loop fetches each tick
	// and refreshes ServerManager.Bootstrap before Reconcile so the
	// next K3s install picks up any operator-changed values.
	k3sBootstrap := k3sd.NewHTTPBootstrapConfigClient(client)
	k3sServerMgr := k3sd.NewServerManager(
		k3sClient, k3sModules, k3sd.NewShellServerApplier(),
		client.InstanceID, s.cfg.OnError,
	)
	k3sAgentMgr := k3sd.NewAgentManager(
		k3sClient, k3sModules, k3sd.NewShellAgentApplier(),
		client.InstanceID, s.cfg.OnError,
	)

	// E8.2 — storage migration runner. Polls
	// /api/v1/system/node_api/storage_migrations every PostSend tick;
	// advances each non-terminal migration through the 6-step
	// contract. Idempotent: re-running picks up from server-reported
	// status, so a crashed mid-rsync run resumes naturally.
	migrationRunner := &migration.Runner{
		Client:      client,
		MountRunner: mount.ExecRunner{},
		OnError:     s.cfg.OnError,
	}

	// The boot-image A/B bless used to live here, gated on the first successful
	// heartbeat. That was identity-gated, not health-gated (INV-4): it asked
	// whether the PLATFORM was reachable, not whether THIS image came up. It now
	// runs in its own goroutine below, gated on the node probing its own composed
	// app — see BootConfirmer.
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
			// Phase O4 follow-up — refresh K3s server BootstrapConfig
			// from the platform before this tick's Reconcile. Stale
			// config-on-error behavior matches dockerd's overrides
			// pattern: if fetch fails, keep the previous Bootstrap
			// value rather than blanking it. Lightweight hosts (or
			// hosts with no K3s cluster yet) get a zero-valued
			// BootstrapConfig from the platform's flannel default,
			// which the manager treats as "K3s default install args".
			if cfg, _, err := k3sBootstrap.FetchBootstrapConfig(ctx); err != nil {
				s.cfg.OnError("k3s_bootstrap_fetch", err)
			} else {
				k3sServerMgr.Bootstrap = cfg
			}
			// Phase 2 K3s — both managers run each tick; the one
			// whose module isn't assigned no-ops in its first switch
			// branch. Order doesn't matter for correctness; we run
			// server before agent so a co-located deployment (rare)
			// gets a slightly better convergence shape.
			k3sServerMgr.Reconcile(ctx)
			k3sAgentMgr.Reconcile(ctx)
			// Storage migrations run last in the post-send chain —
			// migrations only fire when an operator has explicitly
			// approved them, and they tolerate slow execution
			// (rsync can run for minutes). Failure surfaces via
			// OnError but doesn't block the next tick.
			if err := migrationRunner.Tick(ctx); err != nil {
				s.cfg.OnError("migration_runner", err)
			}
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
		},
		Verifier:    verify.AlwaysOK{},
		MountRunner: mount.ExecRunner{},
		Layout:      mount.DefaultLayout(),
		StatePath:   s.cfg.StatePath,
		Interval:    60 * time.Second,
		OnError:     s.cfg.OnError,
		// PlatformURL flows down to reconciler.attachModule which adds
		// the host to Policy.ProtectedHosts before applying egress
		// rules — keeps the agent's own control-plane traffic outside
		// the default-drop zone of any restrictive module policy.
		PlatformURL: client.PlatformURL,
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

	// Boot-LKG one-shot capture (#39 Level-1 boot-independence). Promotes THIS
	// boot's breadcrumb (what ComposeForPivot cold-composed) to the frozen
	// last-known-good — but ONLY after the COMPOSED control plane passes an
	// app-level health check (loopback Traefik → hub-backend /up), never on the
	// agent's own liveness. No-op after the first capture (frozen) or on a boot
	// that itself fell back to the LKG. Deliberately its own goroutine reading
	// only the boot breadcrumb — it never touches the live reconcile state, so a
	// module the reconciler hot-mounts post-boot (whose new code only runs after
	// a future reboot) can never be promoted as last-known-good.
	healthURL := s.cfg.AppHealthURL
	if healthURL == "" {
		healthURL = defaultAppHealthURL
	}
	capturer := &LKGCapturer{
		BreadcrumbPath:      BootBreadcrumbPath,
		LKGPath:             BootLKGPath,
		DefaultAppHealthURL: healthURL,
		Hostname:            desiredHostname(),
		CachePath:           mount.DefaultLayout().Resolve().ModuleCachePath,
		OnError:             s.cfg.OnError,
	}
	spawn("lkg_capture", func() {
		if err := capturer.Run(ctx); err != nil {
			s.cfg.OnError("lkg_capture", err)
		}
	})
	// INV-4: bless a pending boot slot on the node's OWN health, not on platform
	// reachability. Its own goroutine (not the heartbeat's PostSend) is the point
	// — a node whose image is healthy must be able to bless even while the
	// platform link is down, and a node that can reach the platform must NOT be
	// blessed until its composed stack actually comes up.
	spawn("boot_confirm", func() {
		confirmer := &BootConfirmer{
			BreadcrumbPath:      BootBreadcrumbPath,
			DefaultAppHealthURL: healthURL,
			Hostname:            desiredHostname(),
			BootedGitSHA:        s.bootedImageGitSHA,
			Runner:              mount.ExecRunner{},
			OnError:             s.cfg.OnError,
		}
		if err := confirmer.Run(ctx); err != nil {
			s.cfg.OnError("boot_confirm", err)
		}
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
		PKIDir:       s.cfg.PKIDir,
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

	// Increment 4 — site-local + tcp-protocol federation subscription
	// forwarder (see tcpfwd.DefaultConfigPath's doc comment for the
	// shared contract with Federation::TcpForwarderConfigWriter).
	// Missing-file-tolerant: a node with no active tcpfwd-eligible
	// subscriptions has no config file yet, which is a legitimate idle
	// steady state, not an error — log nothing and skip starting the
	// daemon. A malformed/invalid config file IS a real misconfiguration
	// and surfaces via OnError like the other *_init failures above.
	// Load-at-start only: internal/tcpfwd has no reload mechanism yet,
	// so picking up new/changed forwards requires an agent restart
	// until that's built.
	if fwdCfg, err := tcpfwd.LoadConfig(tcpfwd.DefaultConfigPath); err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			s.cfg.OnError("tcpfwd_config_load", err)
		}
	} else {
		forwarder := tcpfwd.New(fwdCfg, nil)
		spawn("tcpfwd", func() {
			if err := forwarder.Run(ctx); err != nil {
				s.cfg.OnError("tcpfwd", err)
			}
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
		// Capabilities are detected once and cached on the Service.
		// Stable across heartbeats — kernel features don't change
		// without a reboot, which restarts the agent.
		Capabilities: s.capabilities,
		// Baked-in disk-image git_sha, read once at construction.
		BootedImageGitSHA: s.bootedImageGitSHA,
	}
	if sdwanMgr != nil {
		payload.SdwanState = sdwanMgr.HeartbeatStatuses()
	}
	// Boot-LKG observability (#39). Two reads of tiny /persist files:
	//   1. The boot breadcrumb — whether THIS boot fell back to the LKG (+ age),
	//      and whether it composed an incomplete set.
	//   2. The frozen LKG itself — ARM-telemetry (HIGH-1): emitted on EVERY boot
	//      so the operator can verify a node is armed before #14 pulls its
	//      control plane. Read here (not snapshotted) so confirmed_at reflects
	//      the current on-disk LKG even after a re-provision.
	if bc, err := LoadBreadcrumb(BootBreadcrumbPath); err == nil {
		payload.BootIncomplete = bc.Incomplete
		if bc.FromLKG {
			payload.BootedFromLKG = true
			if !bc.LKGConfirmedAt.IsZero() {
				payload.LKGAgeSeconds = int64(time.Since(bc.LKGConfirmedAt).Seconds())
			}
		}
	}
	if lkg, err := LoadBootLKG(BootLKGPath); err == nil {
		payload.LKGPresent = true
		payload.LKGConfirmedAt = lkg.ConfirmedAt.UTC().Format(time.RFC3339)
		payload.LKGModuleCount = len(lkg.Modules)
	}
	return payload
}

// bootstrap ensures mTLS material exists at PKIDir. On first boot (no
// cert on disk) it discovers identity via the standard Resolver chain
// (kernel cmdline → virtio-fw-cfg → cloud metadata → local identity.cfg),
// trades the bootstrap token for an mTLS cert at /node_api/enroll, and
// persists the result so subsequent invocations skip enrollment.
//
// An already-enrolled on-disk identity ALWAYS wins over discovery. The
// post-switch_root service is started with no --platform-url flag, so
// running the resolver first would reach the anonymous ClaimStrategy — which
// polls /node_api/claim forever (unbounded, deadline-detached) and never
// returns, so the cert federation-accept wrote to the bind-mounted /persist
// would never be adopted. We therefore check for a usable on-disk cert up
// front (step 0), keying off the platform URL the enrollment persisted to
// meta.json, and only fall through to discovery + enroll on a genuine first
// boot with no cert.
//
// Returns a transport.Client ready for mTLS-authenticated platform calls.
func (s *Service) bootstrap(ctx context.Context, paths enroll.PKIPaths) (*transport.Client, error) {
	// 0. Adopt an already-enrolled on-disk identity before any discovery.
	// Prefer the explicit --platform-url flag; otherwise use the URL the
	// enrollment persisted to meta.json (the host the node enrolled against).
	// A valid cert on disk short-circuits the resolver entirely, so a
	// post-pivot service never blocks in ClaimStrategy while holding a cert.
	adoptURL := s.cfg.PlatformURL
	if adoptURL == "" {
		adoptURL = enroll.ReadPlatformURL(paths)
	}
	if adoptURL != "" {
		if c, err := transport.LoadFromPKIDir(adoptURL, paths); err == nil {
			s.cfg.PlatformURL = adoptURL
			return c, nil
		}
	}

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

// applyHostnameFromFwCfg sets the node's hostname from the platform-provided
// instance_name fw-cfg blob (desiredHostname): it writes /etc/hostname AND
// applies the value to the running kernel via sethostname(2), idempotently.
// Runs once early in Run() — before the reconcile loop — so journald and the
// bootstrap logs carry the correct hostname immediately; the reconcile loop
// reasserts it every tick thereafter.
//
// Durable, not transient. The prior implementation used
// `hostnamectl set-hostname --transient` on the belief that /etc/hostname
// couldn't be persisted on the overlay rootfs. It can: the writable upper
// layer accepts the write, and base-os now masks /etc/hostname out of its
// erofs lower, so the agent's write is authoritative on every boot instead of
// losing to a build-chroot hostname baked into the shipped blob. Writing the
// file (not just the transient kernel value) is what makes it survive across
// systemd-hostnamed re-reads and reboots.
//
// Returns nil silently when no fw-cfg instance_name is present (bare
// provision, non-QEMU provider, or an empty name server-side).
func (s *Service) applyHostnameFromFwCfg() error {
	name := desiredHostname()
	if name == "" {
		return nil
	}
	if _, err := etcidentity.ApplyHostname("", name, true); err != nil {
		return err
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
