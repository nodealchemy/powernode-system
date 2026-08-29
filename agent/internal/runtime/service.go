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
	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/migration"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/oci"
	"github.com/nodealchemy/powernode-system/agent/internal/probe"
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
	// verifyProbes runs each attached module's manifest-declared `verify:`
	// probes (IMP-3855ff9908f2). Snapshot-style, like sdwan.Manager:
	// buildHeartbeat only READS the stored snapshot, so assembling a
	// heartbeat never spawns a subshell.
	//
	// The probing itself runs from PostSend, which the heartbeat loop calls
	// SYNCHRONOUSLY between one beat and the next — so a pass does delay the
	// following heartbeat. That is bounded by probe.DefaultRefreshBudget
	// (20s against a 30s beat), and on a steady fleet a pass does no work at
	// all: a module is re-probed only when its digest changes or its refresh
	// interval elapses. Without that bound a slow filesystem could push the
	// node past the platform's 600s live-heartbeat window and make it read as
	// SILENT — an outage manufactured by an observability feature.
	verifyProbes *probe.Evaluator
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
		verifyProbes:      newVerifyEvaluator(cfg),
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

	// Operator SSH keys are synced by AuthorizedKeysSyncer on its own goroutine
	// (spawned below), NOT here and NOT from the heartbeat's PostSend hook. Both
	// of those were fire-once-or-gated: the one-shot fetch here ran before the
	// platform could possibly be up on a self-hosted control plane, and PostSend
	// only fires after a SUCCESSFUL heartbeat, so a node with a broken platform
	// link never received keys — no SSH exactly when an operator needed to debug
	// it. See AuthorizedKeysSyncer for the incident this comes from.

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
			// authorized_keys is deliberately NOT here — it runs on its own
			// timer so key sync survives a failing heartbeat (AuthorizedKeysSyncer).
			sdwanMgr.Reconcile(ctx)
			// IMP-3855ff9908f2 — re-run each attached module's `verify:`
			// probes. Cheap on a steady fleet (a module whose digest is
			// unchanged is skipped until the refresh interval elapses) and
			// immediate on a NEW digest, which is the moment a bad publish
			// is detectable. Never returns an error into the loop; a run
			// that cannot happen leaves the previous snapshot in place, and
			// the platform ages that out on the agent's own clock.
			s.verifyProbes.Refresh(ctx)
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
			Transport: client,
			// BlobClient(), not `client`: blob bodies are unbounded and must not ride
			// the 30s whole-request Timeout. It still routes through Client.doWith, so
			// the 401 self-heal Puller.HTTPClient documents is preserved. See DoStream.
			HTTPClient:  client.BlobClient(),
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
	//
	// The asymmetry with boot_confirm that used to be documented here — LKG
	// capture keeping the loopback default while the bless gate did not — was
	// REMOVED on 2026-08-17. Its stated reason (LKG promotion is a permanent
	// freeze, so do not weaken its gate) assumed the loopback default was the
	// stricter of the two. On a node serving no web tier it is not stricter, it
	// is unsatisfiable, so the capturer never promoted anything at all and the
	// whole node class ran with no last-known-good. The full argument, and why
	// a self-hosted control plane is unaffected, is on LKGCapturer.resolveGate.
	//
	// AppHealthURL is passed RAW here, for the same reason boot_confirm passes it
	// raw below: an unset URL must stay unset so resolveGate can tell "this node
	// serves /up" apart from "nothing was configured". Defaulting it to
	// defaultAppHealthURL at this call site is what made the gate unsatisfiable.
	capturer := &LKGCapturer{
		BreadcrumbPath:      BootBreadcrumbPath,
		LKGPath:             BootLKGPath,
		DefaultAppHealthURL: s.cfg.AppHealthURL,
		Hostname:            desiredHostname(),
		CachePath:           mount.DefaultLayout().Resolve().ModuleCachePath,
		// The local gate's other half — systemd cannot see a broken module
		// composition, and this can. Same source boot_confirm uses.
		ReconcileOK: reconciler.ComposedOK,
		OnError:     s.cfg.OnError,
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
			BreadcrumbPath: BootBreadcrumbPath,
			// RAW — an unset URL must stay unset so the gate can tell "this node
			// serves /up" apart from "nothing was configured" and pick a probe
			// the node can pass. (Both gates now pass it raw; the local
			// `healthURL` that used to default this for LKG capture is gone.)
			AppHealthURL: s.cfg.AppHealthURL,
			Hostname:     desiredHostname(),
			BootedGitSHA: s.bootedImageGitSHA,
			Runner:       mount.ExecRunner{},
			// The local gate's other half: systemd cannot see a broken module
			// composition, and this can.
			ReconcileOK: reconciler.ComposedOK,
			OnError:     s.cfg.OnError,
		}
		if err := confirmer.Run(ctx); err != nil {
			s.cfg.OnError("boot_confirm", err)
		}
	})
	// Operator SSH key sync on an independent timer. Same reasoning as
	// boot_confirm above: a node whose platform link is down must still be
	// reachable, and gating this on heartbeat success meant the break-glass
	// path depended on the thing the operator was trying to debug.
	spawn("authorized_keys_sync", func() {
		syncer := &AuthorizedKeysSyncer{
			Client:  client,
			OnError: s.cfg.OnError,
		}
		if err := syncer.Run(ctx); err != nil && !errors.Is(err, context.Canceled) {
			s.cfg.OnError("authorized_keys_sync", err)
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
		payload.SdwanOvnState = sdwanMgr.OvnNbStatus()
	}
	// IMP-6151ae14f4e5: both left nil/omitted (never a fabricated reading)
	// when /proc is unreadable or unparseable. See readMemAvailableKB /
	// readLoadAverage for why MemAvailable (not MemFree) and why
	// load_average is still populated even though cpu_pct isn't derived
	// from it.
	if kb, ok := readMemAvailableKB("/proc/meminfo"); ok {
		payload.MemoryFreeKB = &kb
	}
	if la, ok := readLoadAverage("/proc/loadavg"); ok {
		payload.LoadAverage = la
	}
	// Pure snapshot read — the probes themselves run in PostSend. nil stays
	// nil (omitempty): "no module here declares a probe" is an absence the
	// platform records as NOT MEASURED, and must never be sent as an empty
	// block that could read as "verified, nothing wrong".
	payload.ModuleVerifyState = s.verifyProbes.Snapshot()
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
		if !lkg.ConfirmedAt.IsZero() {
			payload.LKGConfirmedAt = lkg.ConfirmedAt.UTC().Format(time.RFC3339)
		}
		payload.LKGModuleCount = len(lkg.Modules)
	}
	// On a pivot (native root-mode) node the compose path grants capabilities
	// additively and does NOT reset the bounding set (see ComposeForPivot and
	// WriteAmbientCapabilityDropInAt). Report that omission so it is visible in
	// reported state, not just in a code comment (IMP-01a02f70-9bfb). Seccomp
	// and PrivateUsers ARE enforced on this path as of that fix, so they are not
	// listed. On cloud_init nodes attachModule enforces the full set — the field
	// stays nil/omitted.
	if pivotAwareRootMode() == lifecycle.RootModeNative {
		// capability_bounding_set: granted additively (ambient), never reset —
		//   pending a per-module runtime-capability audit.
		// mandatory_access_control: the pivot/compose path does not load
		//   SELinux/AppArmor profiles at all (LoadSELinuxProfile/LoadAppArmorProfile
		//   run only on the cloud_init Apply path), so a module's selinux_profile/
		//   apparmor_profile is inert post-pivot — report it rather than let the
		//   heartbeat overstate confinement (review finding F3).
		payload.PivotConfinementOmitted = []string{"capability_bounding_set", "mandatory_access_control"}
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

// newVerifyEvaluator builds the module-verify probe evaluator, pointed at the
// SAME attach-state file the rest of the service uses. Threading cfg.StatePath
// through rather than letting the evaluator fall back to the mount.StatePath
// constant is what keeps a test-configured agent (and any future non-default
// deployment) from reading the host's live /persist state.
func newVerifyEvaluator(cfg Config) *probe.Evaluator {
	e := probe.NewEvaluator(cfg.OnError)
	if cfg.StatePath != "" {
		e.StatePath = cfg.StatePath
	}
	return e
}
