# frozen_string_literal: true

require "yaml"
require "fileutils"
require "openssl"

module Acme
  # Generates Traefik dynamic configuration from active AcmeCertificate
  # rows. Writes one YAML file per account into the dynamic-config
  # directory; Traefik file-watches the directory and reloads
  # automatically when files change.
  #
  # Output shape (Traefik dynamic config v3 — file provider):
  #
  #   tls:
  #     certificates:
  #       - certFile: <cert_dir>/<acct>/<cert-id>.crt
  #         keyFile:  <cert_dir>/<acct>/<cert-id>.key
  #         stores:   ["default"]
  #
  # Path resolution:
  #   1. POWERNODE_TRAEFIK_DYNAMIC_DIR / POWERNODE_TRAEFIK_CERT_DIR env
  #   2. /etc/traefik/{dynamic,certs} if the parent /etc/traefik exists +
  #      is writable (production install)
  #   3. <Rails.root>/tmp/traefik/{dynamic,certs} otherwise (dev fallback)
  #
  # Materializing the PEMs onto disk is `Acme::CertificateManager`'s
  # responsibility (it pulls from Vault + writes to the paths this
  # writer references). This class only emits the YAML pointing at
  # those paths.
  #
  # Plan reference: Decentralized Federation §J + P2.5.4 + P2.5.10.
  class TraefikConfigWriter
    class WriteError < StandardError; end

    # File name for the shared dynamic config holding the mTLS TLS option
    # set + the passTLSClientCert middleware. Per-account YAMLs reference
    # these by `<name>@file`, so this file must exist before any per-account
    # YAML referencing mtls-optional is loaded. powernode-reverse-proxy.sh
    # calls `write_mtls_shared_dynamic!` before per-account `write!` runs.
    SHARED_MTLS_FILENAME = "_mtls.yaml"

    # OUR internal CA chain ONLY. Written by `write_internal_ca!`. This is the
    # anchor core auth (Security::MtlsTrust) verifies node/worker/internal certs
    # against — a peer-CA cert must NOT validate here.
    INTERNAL_CA_FILENAME = "internal-ca.pem"

    # Traefik's CLIENT-cert trust bundle: our CA + every reachable federation
    # peer's CA (symmetric peers sign with their own). Written by
    # `write_client_auth_bundle!`; referenced from the shared mTLS YAML via
    # `tls.options.mtls-optional.clientAuth.caFiles`. Distinct from
    # internal-ca.pem so peer CAs are trusted at the TLS handshake WITHOUT being
    # trusted for node/worker identity (the backend re-binds per-peer).
    CLIENT_AUTH_BUNDLE_FILENAME = "client-auth-bundle.pem"

    class << self
      def write!(account:, dynamic_dir: nil, cert_dir: nil)
        new(account: account,
            dynamic_dir: dynamic_dir || default_dynamic_dir,
            cert_dir: cert_dir || default_cert_dir).write!
      end

      # Writes the platform's static Traefik config (entry points +
      # providers + logging). This is what systemd passes via
      # --configFile=<this path>. Idempotent — safe to call repeatedly.
      #
      # Single TLS entrypoint with OPTIONAL mTLS:
      #   - websecure (:443) — serves everyone. mtls-optional@file
      #     (VerifyClientCertIfGiven) verifies a client cert against the
      #     internal CA WHEN PRESENTED but never requires one at the handshake.
      #     Certless clients (browsers, operators, MCP, agent enroll/
      #     federation-accept) connect fine; cert-bearing clients (agents,
      #     federation peers, workers) get their CN forwarded by the
      #     pass-tls-client-cert middleware. Per-route enforcement lives in the
      #     backend (NodeApi/FederationApi/Internal/WorkerAuth base controllers
      #     401 when the CN is absent).
      # IMPORTANT: the TLS option is applied PER-ROUTER (render_routers sets
      # tls.options on every router), NOT at the entrypoint. Traefik binds
      # clientAuth options by the matched router's HostSNI — an entrypoint-level
      # `http.tls.options` is silently ignored for client-cert verification
      # (verified empirically: entrypoint-only RequireAndVerify still let a
      # certless request through). The pass-tls-client-cert MIDDLEWARE works at
      # the entrypoint level and stays here. Every router uses the SAME
      # mtls-optional option, so there is no per-SNI conflict.
      # Lifted to Core::IngressConfigWriter (campaign 019f3458 increment 8 —
      # zero System:: dependency, needed unconditionally in core mode too).
      # Delegating instead of duplicating keeps the two writers from drifting;
      # output is unchanged (same config shape, byte-for-byte).
      def write_static_config!(dynamic_dir: nil, output_path: nil)
        ::Core::IngressConfigWriter.write_static_config!(dynamic_dir: dynamic_dir, output_path: output_path)
      end

      def default_static_config_path
        ::Core::IngressConfigWriter.default_static_config_path
      end

      # Writes the platform's internal CA chain to disk so Traefik can use
      # it as the trust anchor when verifying agent client certs on
      # mTLS-required routes. Idempotent — overwrites on every call so the
      # bundle stays fresh if the root rotates. Path is referenced from
      # the shared mTLS dynamic YAML via `clientAuth.caFiles`.
      def write_internal_ca!(ca_dir: nil)
        dir = ca_dir || default_ca_dir
        FileUtils.mkdir_p(dir)
        out = File.join(dir, INTERNAL_CA_FILENAME)
        File.write(out, ::System::InternalCaService.ca_chain_pem)
        out
      end

      # Writes the Traefik client-auth trust bundle: our internal CA PLUS every
      # reachable federation peer's CA (symmetric peers sign with their own).
      # This is what the shared mtls-optional clientAuth.caFiles points at, so
      # Traefik accepts a peer-signed cert at the handshake — the backend then
      # re-binds it to the specific peer (federation) or rejects it on node/
      # worker routes (Security::MtlsTrust verifies against our CA only).
      # Idempotent; rewriting it is how peer-CA rotation/teardown propagates
      # (Traefik file-watches the directory and reloads).
      def write_client_auth_bundle!(ca_dir: nil)
        dir = ca_dir || default_ca_dir
        FileUtils.mkdir_p(dir)
        out = File.join(dir, CLIENT_AUTH_BUNDLE_FILENAME)
        pems = [ ::System::InternalCaService.ca_chain_pem ]
        pems.concat(::System::FederationPeer.trusted_ca_pems) if defined?(::System::FederationPeer)
        body = pems.compact.map { |p| p.to_s.strip }.reject(&:empty?).join("\n")
        File.write(out, "#{body}\n")
        out
      end

      # Writes the shared dynamic config holding the OPTIONAL-mTLS TLS
      # option set + the passTLSClientCert middleware. These primitives are
      # applied at the websecure entrypoint via `mtls-optional@file` and
      # `pass-tls-client-cert@file`. Idempotent.
      #
      # clientAuthType=VerifyClientCertIfGiven: a presented cert is verified
      # against the internal CA, but no cert is required at the handshake —
      # so the same :443 listener serves certless browsers AND cert-bearing
      # agents/workers/peers. Per-route enforcement is the backend's job.
      #
      # Header forwarding: passTLSClientCert.info.subject.commonName=true
      # makes Traefik emit
      #   X-Forwarded-Tls-Client-Cert-Info: Subject="CN=<value>"
      # which BaseController#mtls_subject_cn parses. The agent's cert CN
      # is its NodeInstance.id, so the platform can resolve the caller
      # without consulting a JWT.
      def write_mtls_shared_dynamic!(dynamic_dir: nil, ca_dir: nil)
        dir = dynamic_dir || default_dynamic_dir
        cadir = ca_dir || default_ca_dir
        # Write/refresh the client-auth bundle BEFORE the option references it,
        # so peer-CA trust and the pem-forwarding it requires ship together.
        write_client_auth_bundle!(ca_dir: cadir)
        ca_path = File.join(cadir, CLIENT_AUTH_BUNDLE_FILENAME)
        FileUtils.mkdir_p(dir)
        out = File.join(dir, SHARED_MTLS_FILENAME)
        File.write(out, YAML.dump(shared_mtls_config(ca_path)))
        out
      end

      def shared_mtls_config(ca_path)
        {
          "tls" => {
            "options" => {
              "mtls-optional" => {
                "clientAuth" => {
                  "caFiles"        => [ ca_path ],
                  # Verify a presented cert against the internal CA, but do
                  # not require one — lets certless browser/operator/enroll
                  # traffic share :443 with cert-bearing agent/worker traffic.
                  "clientAuthType" => "VerifyClientCertIfGiven"
                }
              },
              # REQUIRED-client-cert counterpart, for Sdwan::Service Path B
              # (public TLS-carrying TCP, campaign 019f3458 increment 5)
              # `client_auth == "required"` under `edge_mode == "terminate"`.
              # Same CA bundle as mtls-optional — only clientAuthType differs.
              # Router-bound (like mtls-optional), never entrypoint-level, so
              # it applies only to the specific HostSNI that opts in.
              "mtls-required" => {
                "clientAuth" => {
                  "caFiles"        => [ ca_path ],
                  "clientAuthType" => "RequireAndVerifyClientCert"
                }
              }
            }
          },
          "http" => {
            "middlewares" => {
              "pass-tls-client-cert" => {
                "passTLSClientCert" => {
                  # pem:true forwards the full client cert (X-Forwarded-Tls-
                  # Client-Cert) so the backend can re-verify it against the
                  # right per-identity anchor (Security::MtlsClientVerifier).
                  # Coupled with the peer CAs in caFiles above — they ship
                  # together, which is the invariant the backend's graceful
                  # no-PEM path relies on.
                  "pem" => true,
                  "info" => {
                    "subject" => { "commonName" => true }
                  }
                }
              }
            }
          }
        }
      end

      # Path Acme::CertificateManager writes the cert PEM to.
      def cert_file_path(certificate, cert_dir: nil)
        File.join(cert_dir || default_cert_dir, certificate.account_id, "#{certificate.id}.crt")
      end

      # Path Acme::CertificateManager writes the private key to.
      def key_file_path(certificate, cert_dir: nil)
        File.join(cert_dir || default_cert_dir, certificate.account_id, "#{certificate.id}.key")
      end

      # Path for the issuer chain — when Traefik serves the cert, it
      # serves <leaf>+<chain>. Splitting them on disk lets renewals
      # touch only the leaf when the chain hasn't changed.
      def chain_file_path(certificate, cert_dir: nil)
        File.join(cert_dir || default_cert_dir, certificate.account_id, "#{certificate.id}.chain.pem")
      end

      # Path resolution — lifted to Core::IngressConfigWriter (same env
      # precedence: POWERNODE_TRAEFIK_*_DIR -> /etc/traefik/* if usable ->
      # <Rails.root>/tmp/traefik/<env>/*). Delegated so core mode and
      # extension mode resolve identically.
      def default_dynamic_dir
        ::Core::IngressConfigWriter.default_dynamic_dir
      end

      def default_cert_dir
        ::Core::IngressConfigWriter.default_cert_dir
      end

      def default_ca_dir
        ::Core::IngressConfigWriter.default_ca_dir
      end
    end

    def initialize(account:, dynamic_dir:, cert_dir:)
      @account = account
      @dynamic_dir = dynamic_dir
      @cert_dir = cert_dir
    end

    def write!
      certs = ::System::AcmeCertificate.where(account_id: @account.id, status: "valid").to_a
      yaml = render_yaml(certs)

      FileUtils.mkdir_p(@dynamic_dir)
      output_path = File.join(@dynamic_dir, "acme-#{@account.id}.yaml")
      File.write(output_path, yaml)

      { output_path: output_path, cert_count: certs.size }
    rescue StandardError => e
      raise WriteError, "TraefikConfigWriter failed: #{e.class}: #{e.message}"
    end

    # Renders the YAML hash that Traefik will consume. Public so tests
    # can verify the rendered content without filesystem side effects.
    #
    # Emits three sections:
    #
    #   - tls.certificates — one entry per valid cert
    #   - http.routers — per cert: API + Cable + frontend routers, ordered
    #     by Traefik's auto-priority (longer/more-specific rules win)
    #   - http.services — `powernode-backend` (Rails) + `powernode-frontend`
    #     (Vite dev or built assets), URLs from env with sensible defaults
    def render_yaml(certs)
      hash = {
        "tls" => {
          "certificates" => certs.select { |c| cert_materialized?(c) }.map { |c| render_cert_entry(c) }
        }
      }
      if certs.any?
        hash["http"] = {
          "routers"  => certs.flat_map { |c| render_routers(c) }.to_h,
          "services" => render_services
        }
      end
      YAML.dump(hash)
    end

    # The HTTP services dict mapping logical name → backend URL. Both
    # endpoints are env-configurable so the same writer works in dev
    # (localhost:3000 + :3001) and in production (SDWAN VIPs etc).
    # Lifted to Core::IngressConfigWriter (campaign 019f3458 increment 8 —
    # pure ENV, zero System:: dependency); delegated here so external callers
    # (Sdwan::ServiceExposureWriter, Acme::IngressRoutePresenter, specs) keep
    # working unchanged.
    def self.backend_url
      ::Core::IngressConfigWriter.backend_url
    end

    def self.frontend_url
      ::Core::IngressConfigWriter.frontend_url
    end

    # The standalone worker's Rack app (default :4567), which hosts the Sidekiq
    # Web dashboard at /sidekiq (auth-gated by the worker's SidekiqWebAuth
    # middleware). Only the /sidekiq prefix gets a router below — the worker's
    # private /api/v1 API on the same port is intentionally NOT routed publicly.
    def self.worker_web_url
      ::Core::IngressConfigWriter.worker_web_url
    end

    # Additional hostnames Traefik should route to the same backend/frontend
    # services as the cert's common_name. Used when the platform sits behind
    # an external reverse proxy that terminates a public hostname's TLS and
    # forwards HTTP requests with the original Host header preserved.
    #
    # Example (ops): cert is for `ops.ipnode.us` (internal), but the public
    # face `ops.powernode.org` lands here via the external proxy. Setting
    # POWERNODE_PROXY_EXTRA_HOSTS=ops.powernode.org makes the router rule
    # match both Host values without claiming to have a cert for the public
    # name (TLS for the public hostname is the external proxy's job).
    #
    # Comma-separated; whitespace trimmed; empty entries dropped. Merged with the
    # operator-managed allowlist (trusted_proxy_hosts) so hosts added via
    # scripts/manage-proxy-hosts.sh are routed by the bundled proxy too.
    # Lifted to Core::IngressConfigWriter — AdminSetting is already core, so
    # this had zero System:: dependency to begin with.
    def self.extra_hosts
      ::Core::IngressConfigWriter.extra_hosts
    end

    # Hostnames from the operator-managed reverse-proxy allowlist
    # (AdminSetting.reverse_proxy_url_config[:trusted_hosts], maintained by
    # scripts/manage-proxy-hosts.sh) that are valid Traefik Host() values. This is
    # the integration seam that makes `manage-proxy-hosts.sh add <host>` route
    # <host> through the bundled proxy. Only literal hosts/IPs are usable: ports
    # are stripped (the websecure entrypoint owns :443) and wildcard/regex
    # patterns + the localhost family are dropped (Host() takes literals;
    # localhost is already a cert CN). Best-effort — returns [] (never raises) if
    # AdminSetting is unavailable (e.g. migrations not yet run / core mode).
    def self.trusted_proxy_hosts
      ::Core::IngressConfigWriter.trusted_proxy_hosts
    end

    # The single TLS option (clientAuth) applied to every router. Exposed so
    # the read-only ingress projection can report it alongside the write path.
    TLS_RESOLVER = "mtls-optional@file"
    ENTRYPOINT   = "websecure"

    # Per-router specification: [name suffix, path prefix, logical service].
    # ORDER + CONTENTS are the single source of truth shared by render_routers
    # (write path → Traefik YAML) and routers_for (read path → ingress
    # projection). The frontend catchall has no path prefix (Host-only rule).
    ROUTER_SPECS = [
      [ "node-api",       "/api/v1/system/node_api",       "powernode-backend"    ],
      [ "federation-api", "/api/v1/system/federation_api", "powernode-backend"    ],
      [ "internal-api",   "/api/v1/internal",              "powernode-backend"    ],
      [ "worker-api",     "/api/v1/system/worker_api",     "powernode-backend"    ],
      [ "worker-auth",    "/api/v1/worker_auth",           "powernode-backend"    ],
      [ "api",            "/api",                          "powernode-backend"    ],
      [ "agent",          "/agent",                        "powernode-backend"    ],
      [ "cable",          "/cable",                        "powernode-backend"    ],
      [ "sidekiq",        "/sidekiq",                      "powernode-worker-web" ],
      [ "frontend",       nil,                             "powernode-frontend"   ]
    ].freeze

    # Builds Traefik's host matcher for a certificate's common_name. SOURCE OF
    # TRUTH for the host_rule emitted in router rules (write path, via
    # build_hosts_matcher) AND the host_rule reported by the read-only ingress
    # projection. Without extra hosts configured, emits the single-host form
    # `Host(`cn`)`. With POWERNODE_PROXY_EXTRA_HOSTS set, emits OR'd matchers
    # `(Host(`cn`) || Host(`extra1`) ...)` — Traefik v3's `Host()` accepts one
    # hostname per invocation, so multi-host fan-out is an OR group, wrapped in
    # parens so precedence with a trailing `&& PathPrefix(...)` is correct.
    # `extra_hosts:` defaults to the env-reading class method so the write path
    # is unchanged. The read path (IngressRoutesController#index) passes a
    # pre-computed list so the env is parsed once per request instead of once
    # per cert.
    def self.host_rule_for(primary_host, extra_hosts: nil)
      ::Core::IngressConfigWriter.host_rule_for(primary_host, extra_hosts: extra_hosts)
    end

    # Pure, side-effect-free projection of the router metadata for a single
    # certificate. SOURCE OF TRUTH for both the written Traefik config
    # (render_routers builds its YAML from this) and the read-only ingress
    # routes endpoint (Api::V1::System::IngressRoutesController). Returns an
    # Array of plain Hashes — no AR association touches, no filesystem, no env
    # mutation. The frontend catchall router carries a nil path_prefix.
    #
    #   { name:, path_prefix:, backend_service:, backend_url:, entrypoint:, tls_resolver: }
    # `backend_url:`/`frontend_url:`/`worker_web_url:` default to the env-reading
    # class methods so the write path is unchanged. The read path
    # (IngressRoutesController#index) passes pre-computed URLs so the env is
    # parsed once per request instead of once per router (x10) per cert.
    def self.routers_for(cert, backend_url: nil, frontend_url: nil, worker_web_url: nil)
      urls = {
        "powernode-backend"    => backend_url    || self.backend_url,
        "powernode-frontend"   => frontend_url   || self.frontend_url,
        "powernode-worker-web" => worker_web_url || self.worker_web_url
      }
      slug = router_slug_for(cert.common_name)
      ROUTER_SPECS.map do |suffix, path_prefix, service|
        {
          name:            "#{slug}-#{suffix}",
          path_prefix:     path_prefix,
          backend_service: service,
          backend_url:     urls.fetch(service),
          entrypoint:      ENTRYPOINT,
          tls_resolver:    TLS_RESOLVER
        }
      end
    end

    # Traefik router names are arbitrary but should be deterministic +
    # human-readable. Use the cert's common_name with non-DNS chars
    # collapsed to dashes. Class-level so routers_for (and the read-side
    # projection) can derive the slug without an instance.
    def self.router_slug_for(common_name)
      common_name.to_s.gsub(/[^a-zA-Z0-9]+/, "-").gsub(/(^-|-$)/, "")
    end

    private

    def render_cert_entry(cert)
      {
        "certFile" => self.class.cert_file_path(cert, cert_dir: @cert_dir),
        "keyFile"  => self.class.key_file_path(cert, cert_dir: @cert_dir),
        "stores"   => [ "default" ]
      }
    end

    # True only when the cert's on-disk PEM material is actually present,
    # non-blank, and structurally parses. A `valid` AcmeCertificate row can
    # still point at a missing/blank/stub .crt or .key (e.g. a materialize
    # where lego returned an empty cert_pem, or a partial write), which makes
    # Traefik log "failed to find any PEM data in certificate input" on every
    # reload — or worse, fail to build the tls.Certificate for that entry.
    # Gating the tls.certificates entry on this stops that. Both files get the
    # same scrutiny (existence, non-blank, real ASN.1/DER parse via OpenSSL)
    # because a bad key is exactly as unusable to Traefik as a bad cert — the
    # two are only ever consumed as a pair. Deliberately gates ONLY the cert
    # entry, never the routers — the read-side ingress projection (routers_for
    # / IngressRoutePresenter) has no filesystem access and must stay
    # identical to the write path, so a host with a broken cert keeps its
    # routers and falls back to the default-store cert (surfacing the TLS
    # mismatch rather than 404ing). Any skip is logged loudly (warn) with the
    # cert id + reason so a broken materialize doesn't fail silently.
    def cert_materialized?(cert)
      cert_path = self.class.cert_file_path(cert, cert_dir: @cert_dir)
      key_path  = self.class.key_file_path(cert, cert_dir: @cert_dir)

      cert_pem = read_file(cert_path)
      return skip_cert!(cert, "cert file missing or unreadable at #{cert_path}") if cert_pem.nil?
      return skip_cert!(cert, "cert file is blank at #{cert_path}") if cert_pem.blank?

      key_pem = read_file(key_path)
      return skip_cert!(cert, "key file missing or unreadable at #{key_path}") if key_pem.nil?
      return skip_cert!(cert, "key file is blank at #{key_path}") if key_pem.blank?

      begin
        OpenSSL::X509::Certificate.new(cert_pem)
      rescue OpenSSL::OpenSSLError, ArgumentError => e
        return skip_cert!(cert, "cert file fails to parse (#{e.class}: #{e.message}) at #{cert_path}")
      end

      begin
        OpenSSL::PKey.read(key_pem)
      rescue OpenSSL::OpenSSLError, ArgumentError => e
        return skip_cert!(cert, "key file fails to parse (#{e.class}: #{e.message}) at #{key_path}")
      end

      true
    end

    def read_file(path)
      return nil unless File.file?(path)

      File.read(path)
    rescue SystemCallError
      nil
    end

    def skip_cert!(cert, reason)
      Rails.logger.warn(
        "[Acme::TraefikConfigWriter#cert_materialized?] skipping tls.certificates entry for " \
        "cert #{cert.id} (account #{cert.account_id}): #{reason}"
      )
      false
    end

    # One router per `ROUTER_SPECS` entry, per cert, all on the single
    # `websecure` (:443) entrypoint. (Count deliberately not restated here —
    # ROUTER_SPECS above is the single source of truth; a hardcoded number in
    # this comment previously drifted out of sync with it.) Every router
    # carries `tls.options=mtls-optional@file` (VerifyClientCertIfGiven): a
    # client cert is verified against the internal CA when presented but never
    # required. The pass-tls-client-cert middleware (entrypoint-level)
    # forwards the CN. Because EVERY router on a given host uses the SAME
    # option, there is no per-SNI conflict. Path specificity sets priority:
    # Traefik orders by rule length, so the long mTLS-bearing API prefixes
    # match before the bare `/api` and the Host-only frontend catchall.
    #
    #   - <slug>-node-api       — Host(`cn`) && PathPrefix(`/api/v1/system/node_api`)
    #                              (agent client cert)
    #   - <slug>-federation-api — Host(`cn`) && PathPrefix(`/api/v1/system/federation_api`)
    #                              (federation peer client cert)
    #   - <slug>-internal-api   — Host(`cn`) && PathPrefix(`/api/v1/internal`)
    #                              (Sidekiq worker client cert)
    #   - <slug>-worker-api     — Host(`cn`) && PathPrefix(`/api/v1/system/worker_api`)
    #   - <slug>-worker-auth    — Host(`cn`) && PathPrefix(`/api/v1/worker_auth`)
    #                              (worker-web client cert; user creds in body)
    #   - <slug>-api            — Host(`cn`) && PathPrefix(`/api`)        (operator JWT)
    #   - <slug>-agent          — Host(`cn`) && PathPrefix(`/agent`)      (static binary)
    #   - <slug>-cable          — Host(`cn`) && PathPrefix(`/cable`)      (ActionCable WS;
    #                              dual auth — worker CN if a cert is present, else user JWT)
    #   - <slug>-sidekiq        — Host(`cn`) && PathPrefix(`/sidekiq`)    (Sidekiq Web dashboard;
    #                              routes to powernode-worker-web, auth via SidekiqWebAuth middleware)
    #   - <slug>-frontend       — Host(`cn`)                             (catchall)
    #
    # Controllers decide what kind of identity the (optional) cert belongs to:
    #   NodeApi::BaseController        → looks up NodeInstance by CN (401 if absent)
    #   FederationApi::BaseController  → looks up NodeCertificate with subject_kind="federation_peer"
    #   Internal::InternalBaseController (in core) → looks up Worker by CN
    #   WorkerAuthController (in core) → looks up Worker by CN, validates user body
    #   ApplicationCable::Connection   → mTLS arm resolves Worker by CN, user-JWT arm resolves User
    def render_routers(cert)
      hosts_matcher = build_hosts_matcher(cert.common_name)
      # Built from the SAME `routers_for` projection the read-only ingress
      # endpoint consumes, so the two never drift. routers_for supplies the
      # router name, path prefix, and service; this method layers on the
      # write-only YAML concerns: the Host()/PathPrefix() rule string, the
      # entryPoints array, and the per-router tls.options.
      #
      # Every router sets `tls.options=mtls-optional@file` explicitly. Traefik
      # binds clientAuth options by the matched router's HostSNI, so an
      # entrypoint-level option is ignored for client-cert verification — the
      # option MUST be per-router for optional mTLS to take effect. All routers
      # on a host share the SAME option, so there is no per-SNI conflict.
      # Each router gets its own literal `tls` hash (not a shared object) so
      # YAML.dump stays alias-free — a shared ref emits an anchor/alias that
      # Ruby's Psych.load_file (used by specs + reverse-proxy.sh) rejects.
      #
      # Federation-spawned children fetch the powernode-agent binary from their
      # parent via the `/agent` prefix (the Rails app symlinks the binary under
      # public/agent/ so the static file server serves it — no controller).
      self.class.routers_for(cert).map do |router|
        rule =
          if router[:path_prefix].nil?
            hosts_matcher
          else
            "#{hosts_matcher} && PathPrefix(`#{router[:path_prefix]}`)"
          end
        [ router[:name], {
          "rule"        => rule,
          "service"     => router[:backend_service],
          "entryPoints" => [ router[:entrypoint] ],
          "tls"         => { "options" => router[:tls_resolver] }
        } ]
      end
    end

    # Builds Traefik's host matcher. Without extra hosts configured, emits
    # the single-host form `Host(\`cn\`)`. With extras, emits OR'd matchers
    # `(Host(\`cn\`) || Host(\`extra1\`) || Host(\`extra2\`))` because
    # Traefik v3's `Host()` only accepts one hostname per invocation —
    # multi-arg `Host(a, b)` was a v2 form that v3 rejects with
    # "unexpected number of parameters". Parentheses wrap the OR so the
    # operator precedence with the trailing `&& PathPrefix(...)` is right.
    def build_hosts_matcher(primary_host)
      self.class.host_rule_for(primary_host)
    end

    # Lifted to Core::IngressConfigWriter (same 3 fixed upstreams, zero
    # System:: dependency) — delegated so output stays identical.
    def render_services
      ::Core::IngressConfigWriter.render_services
    end
  end
end
