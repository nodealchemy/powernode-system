# frozen_string_literal: true

require "yaml"
require "fileutils"

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

    SYSTEM_PREFIX = "/etc/traefik"

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
      def write_static_config!(dynamic_dir: nil, output_path: nil)
        dynamic_dir ||= default_dynamic_dir
        out = output_path || default_static_config_path
        FileUtils.mkdir_p(File.dirname(out))
        config = {
          "entryPoints" => {
            "web" => {
              "address" => ":80",
              # Redirect ALL plaintext :80 traffic to :443. The
              # entry-point-level redirector applies before any router
              # match, so we don't need per-cert HTTP routers — the
              # protocol upgrade is universal. Browsers that default
              # to HTTP for typed URLs (Chrome's "type without https://")
              # get bounced to HTTPS automatically.
              "http" => {
                "redirections" => {
                  "entryPoint" => {
                    "to"        => "websecure",
                    "scheme"    => "https",
                    "permanent" => true
                  }
                }
              }
            },
            # Single HTTPS entrypoint. The pass-tls-client-cert middleware
            # (applied here, entrypoint-level) forwards the verified CN for
            # every router. The clientAuth TLS option is NOT set here — it is
            # set per-router (see render_routers), because Traefik only honors
            # clientAuth options bound to a router's HostSNI. Certless browser
            # traffic and cert-bearing agent/worker traffic share one port.
            "websecure" => {
              "address" => ":443",
              "http"    => {
                "middlewares" => [ "pass-tls-client-cert@file" ]
              }
            }
          },
          "providers" => {
            "file" => {
              "directory" => dynamic_dir,
              "watch"     => true
            }
          },
          "log"       => { "level" => ENV["POWERNODE_TRAEFIK_LOG_LEVEL"].presence || "INFO" },
          "accessLog" => {},
          "api"       => { "dashboard" => false, "insecure" => false }
        }
        File.write(out, YAML.dump(config))
        out
      end

      def default_static_config_path
        return ENV["POWERNODE_TRAEFIK_STATIC_CONFIG"] if ENV["POWERNODE_TRAEFIK_STATIC_CONFIG"].present?
        File.join(File.dirname(default_dynamic_dir), "traefik.yaml")
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

      # Resolves the dynamic-config dir per the precedence above.
      def default_dynamic_dir
        return ENV["POWERNODE_TRAEFIK_DYNAMIC_DIR"] if ENV["POWERNODE_TRAEFIK_DYNAMIC_DIR"].present?
        return "#{SYSTEM_PREFIX}/dynamic" if can_use_system_prefix?
        rails_fallback_dir("dynamic")
      end

      def default_cert_dir
        return ENV["POWERNODE_TRAEFIK_CERT_DIR"] if ENV["POWERNODE_TRAEFIK_CERT_DIR"].present?
        return "#{SYSTEM_PREFIX}/certs" if can_use_system_prefix?
        rails_fallback_dir("certs")
      end

      def default_ca_dir
        return ENV["POWERNODE_TRAEFIK_CA_DIR"] if ENV["POWERNODE_TRAEFIK_CA_DIR"].present?
        return "#{SYSTEM_PREFIX}/ca" if can_use_system_prefix?
        rails_fallback_dir("ca")
      end

      private

      def can_use_system_prefix?
        File.directory?(SYSTEM_PREFIX) && File.writable?(SYSTEM_PREFIX)
      end

      def rails_fallback_dir(sub)
        if defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root
          # Segment by Rails.env so test runs don't pollute development
          # state (and vice versa). Production deployments override via
          # POWERNODE_TRAEFIK_*_DIR env, so this fallback only hits in
          # dev + test.
          env = (::Rails.respond_to?(:env) && ::Rails.env) ? ::Rails.env.to_s : "shared"
          ::Rails.root.join("tmp", "traefik", env, sub).to_s
        else
          File.join(Dir.tmpdir, "powernode-traefik", sub)
        end
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
    def self.backend_url
      ENV["POWERNODE_PROXY_BACKEND_URL"].presence || "http://127.0.0.1:3000"
    end

    def self.frontend_url
      ENV["POWERNODE_PROXY_FRONTEND_URL"].presence || "http://127.0.0.1:3001"
    end

    # The standalone worker's Rack app (default :4567), which hosts the Sidekiq
    # Web dashboard at /sidekiq (auth-gated by the worker's SidekiqWebAuth
    # middleware). Only the /sidekiq prefix gets a router below — the worker's
    # private /api/v1 API on the same port is intentionally NOT routed publicly.
    def self.worker_web_url
      ENV["POWERNODE_PROXY_WORKER_WEB_URL"].presence || "http://127.0.0.1:4567"
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
    def self.extra_hosts
      from_env = ENV["POWERNODE_PROXY_EXTRA_HOSTS"].to_s.split(",")
      (from_env + trusted_proxy_hosts).map(&:strip).reject(&:empty?).uniq
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
      return [] unless defined?(::AdminSetting)

      cfg = ::AdminSetting.reverse_proxy_url_config
      return [] unless cfg.is_a?(Hash)

      hosts = Array(cfg[:trusted_hosts]) | Array(cfg["trusted_hosts"])
      hosts.filter_map do |raw|
        h = raw.to_s.strip
        next if h.empty? || h.include?("*")          # wildcards need HostRegexp — skip
        h = h.sub(/:\d+\z/, "") if h.count(":") <= 1 # strip :port (leave IPv6 literals alone)
        next if h.empty? || %w[localhost 127.0.0.1 ::1].include?(h)

        h
      end.uniq
    rescue StandardError
      []
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
      extras = extra_hosts || self.extra_hosts
      hosts = [ primary_host ] + extras
      return "Host(`#{primary_host}`)" if hosts.size == 1
      formatted = hosts.map { |h| "Host(`#{h}`)" }.join(" || ")
      "(#{formatted})"
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

    # True only when the cert's on-disk PEM material is actually present and
    # non-empty. A `valid` AcmeCertificate row can still point at a missing or
    # blank/stub .crt (e.g. a materialize where lego returned an empty
    # cert_pem), which makes Traefik log "failed to find any PEM data in
    # certificate input" on every reload. Gating the tls.certificates entry on
    # this stops that. Deliberately gates ONLY the cert entry, never the routers
    # — the read-side ingress projection (routers_for / IngressRoutePresenter)
    # has no filesystem access and must stay identical to the write path, so a
    # host with a broken cert keeps its routers and falls back to the
    # default-store cert (surfacing the TLS mismatch rather than 404ing).
    def cert_materialized?(cert)
      cert_path = self.class.cert_file_path(cert, cert_dir: @cert_dir)
      key_path  = self.class.key_file_path(cert, cert_dir: @cert_dir)
      return false unless File.file?(cert_path) && File.file?(key_path)

      File.read(cert_path).include?("-----BEGIN")
    rescue SystemCallError
      false
    end

    # Nine routers per cert, all on the single `websecure` (:443) entrypoint.
    # Every router carries `tls.options=mtls-optional@file`
    # (VerifyClientCertIfGiven): a client cert is verified against the internal
    # CA when presented but never required. The pass-tls-client-cert middleware
    # (entrypoint-level) forwards the CN. Because EVERY router on a given host
    # uses the SAME option, there is no per-SNI conflict. Path specificity sets
    # priority: Traefik orders by rule length, so the long mTLS-bearing API
    # prefixes match before the bare `/api` and the Host-only frontend catchall.
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

    def render_services
      {
        "powernode-backend" => {
          "loadBalancer" => {
            "servers" => [ { "url" => self.class.backend_url } ],
            "passHostHeader" => true
          }
        },
        "powernode-frontend" => {
          "loadBalancer" => {
            "servers" => [ { "url" => self.class.frontend_url } ],
            "passHostHeader" => true
          }
        },
        "powernode-worker-web" => {
          "loadBalancer" => {
            "servers" => [ { "url" => self.class.worker_web_url } ],
            "passHostHeader" => true
          }
        }
      }
    end
  end
end
