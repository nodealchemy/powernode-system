package dockerd

import "context"

// DaemonApplier is the agent's local-side surface for the Docker daemon
// lifecycle. Production wraps file IO + systemctl; tests inject an
// in-memory stub. Implementations MUST be idempotent — Reconcile may
// call any method on every heartbeat tick when state is stable.
//
// The shell-out implementation (`shell_applier.go`, future slice)
// will:
//   - HasCert / WriteCert: read/write under /etc/docker/{ca,server-cert,server-key}.pem
//   - WriteDaemonConfig:    render /etc/docker/daemon.json with TLS + listen addr
//   - IsDaemonRunning / Start / Stop: shell out to `systemctl`
//   - DaemonVersion:        parse `docker version --format '{{.Server.Version}}'`
type DaemonApplier interface {
	// HasCert returns true iff the on-disk TLS material is present and
	// usable. Callers treat any error as "no cert" — the reconciler
	// then re-requests via the platform.
	HasCert(ctx context.Context) (bool, error)

	// WriteCert atomically persists the platform-signed material to
	// disk. PEM strings are written verbatim; callers handle no
	// transformation. Order of operations is unspecified — the
	// implementation may write key first or cert first, but the final
	// state must be all-three-present-or-none-present.
	WriteCert(ctx context.Context, material CertMaterial) error

	// RemoveCert tears down the on-disk material. Tolerates
	// already-absent files (operator may have removed them
	// out-of-band).
	RemoveCert(ctx context.Context) error

	// WriteDaemonConfig renders /etc/docker/daemon.json. Idempotent:
	// if the file already matches the rendered content, the
	// implementation may no-op. Implementations should NOT trigger a
	// daemon reload here — Reconcile orchestrates restart vs.
	// SIGHUP separately.
	WriteDaemonConfig(ctx context.Context, cfg DaemonConfig) error

	// IsDaemonRunning checks systemd's view of the dockerd unit.
	// Returns false on any uncertainty — the reconciler will retry
	// next tick rather than charge ahead.
	IsDaemonRunning(ctx context.Context) (bool, error)

	// StartDaemon ensures dockerd is running. Idempotent — callers may
	// invoke when the daemon is already up; implementation should
	// no-op in that case.
	StartDaemon(ctx context.Context) error

	// StopDaemon ensures dockerd is not running. Idempotent.
	StopDaemon(ctx context.Context) error

	// DaemonVersion returns the running daemon's version string
	// (e.g. "25.0.3"). Returns "" + nil when the daemon is not
	// running — callers treat empty as "not yet known".
	DaemonVersion(ctx context.Context) (string, error)
}

// CertMaterial is the per-host TLS bundle the agent persists. PEM
// strings, no encoding twists. Pulled from a wants_cert handshake
// response (see SignedCertificate in handshake.go).
type CertMaterial struct {
	// CAChainPEM is the trust root for the platform's mTLS clients.
	// dockerd presents this to clients so they can verify the daemon
	// cert chains back to the platform CA.
	CAChainPEM string

	// ServerCertPEM is the daemon's server cert, signed by the platform
	// CA with CN="docker-daemon-<node_instance_id>".
	ServerCertPEM string

	// ServerKeyPEM is the Ed25519 private half of the daemon's
	// keypair. Generated locally by the agent — never received from
	// the platform.
	ServerKeyPEM string
}

// DaemonConfig captures the salient subset of /etc/docker/daemon.json
// the reconciler renders. Operator-supplied keys (log-driver,
// registry-mirrors, storage-driver, etc.) come in via ExtraConfig
// from the platform's runtime/<runtime>/config endpoint and are
// merged with the base TLS+listen fields at render time.
type DaemonConfig struct {
	// ListenAddress is the tcp://[<v6>]:2376 binding the daemon should
	// expose. Computed from the NodeInstance's SDWAN /128. Per Phase B
	// Decision 1, no public socket exposure — daemon binds overlay-
	// only.
	ListenAddress string

	// TLSCAPath / TLSCertPath / TLSKeyPath point at the on-disk PEM
	// files written by WriteCert. Implementations should use the same
	// paths from a shared constant set so swapping write+read code
	// stays trivial.
	TLSCAPath   string
	TLSCertPath string
	TLSKeyPath  string

	// ExtraConfig carries operator-supplied daemon.json overrides
	// (slice 10). Resolved server-side from dependant config-variety
	// NodeModules and shipped via the runtime/docker/config endpoint.
	// Merged INTO the rendered daemon.json after the base TLS + listen
	// fields. Security-blocked keys (tls/tlsverify/tlscacert/tlscert/
	// tlskey/hosts) are stripped defensively at write time even though
	// the server resolver also strips them — defense in depth.
	ExtraConfig map[string]any
}

// DaemonPaths is the canonical on-disk layout. All shell-out
// implementations must agree on these paths so the reconciler can
// reason about cert existence without the applier needing to
// re-export them.
type DaemonPaths struct {
	CAFile     string // ca chain PEM path  (e.g. /etc/docker/ca.pem)
	CertFile   string // server cert PEM    (e.g. /etc/docker/server-cert.pem)
	KeyFile    string // server key PEM     (e.g. /etc/docker/server-key.pem)
	ConfigFile string // daemon.json path   (e.g. /etc/docker/daemon.json)
}

// DefaultPaths is the path layout the production shell applier will
// use. Centralized here so tests can override individually if needed
// (e.g. `paths := DefaultPaths; paths.CAFile = tmpDir + "/ca.pem"`).
var DefaultPaths = DaemonPaths{
	CAFile:     "/etc/docker/ca.pem",
	CertFile:   "/etc/docker/server-cert.pem",
	KeyFile:    "/etc/docker/server-key.pem",
	ConfigFile: "/etc/docker/daemon.json",
}
