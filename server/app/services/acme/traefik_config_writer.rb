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
    # YAML referencing mtls-required is loaded. powernode-reverse-proxy.sh
    # calls `write_mtls_shared_dynamic!` before per-account `write!` runs.
    SHARED_MTLS_FILENAME = "_mtls.yaml"

    # Bundle filename for the internal CA chain used by Traefik to verify
    # client certificates on mTLS-required routes. Written by
    # `write_internal_ca!`; referenced from the shared mTLS YAML via
    # `tls.options.mtls-required.clientAuth.caFiles`.
    INTERNAL_CA_FILENAME = "internal-ca.pem"

    class << self
      def write!(account:, dynamic_dir: nil, cert_dir: nil)
        new(account: account,
            dynamic_dir: dynamic_dir || default_dynamic_dir,
            cert_dir: cert_dir || default_cert_dir).write!
      end

      # Default port for the dedicated mTLS-required entrypoint.
      # Operator-overridable via POWERNODE_TRAEFIK_MTLS_PORT. Chosen above
      # the conventional :443 to avoid colliding with the public-facing
      # listener; below :8443 to keep it inside the standard "secondary
      # https" range. Workers + agents + federation peers connect to this
      # port for any /api/v1/{system/node_api, system/federation_api,
      # internal} traffic.
      MTLS_ENTRYPOINT_PORT = 4443

      # Writes the platform's static Traefik config (entry points +
      # providers + logging). This is what systemd passes via
      # --configFile=<this path>. Idempotent — safe to call repeatedly.
      #
      # Two TLS entrypoints:
      #   - websecure (:443)        — browser + operator + MCP. No client
      #                               cert required.
      #   - websecure-mtls (:4443)  — agents + federation peers + workers.
      #                               Client cert REQUIRED at the listener
      #                               level (TLS option set as the
      #                               entrypoint default).
      # This split avoids Traefik's per-SNI TLS-option conflict — a single
      # hostname can't simultaneously require + not-require client certs
      # without different entrypoints.
      def write_static_config!(dynamic_dir: nil, output_path: nil)
        dynamic_dir ||= default_dynamic_dir
        out = output_path || default_static_config_path
        mtls_port = (ENV["POWERNODE_TRAEFIK_MTLS_PORT"] || MTLS_ENTRYPOINT_PORT).to_i
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
            "websecure" => { "address" => ":443" },
            # Dedicated mTLS-required listener. Routers bound to this
            # entrypoint get mtls-required@file applied via the shared
            # dynamic config (no per-router tls.options needed). The
            # passTLSClientCert middleware forwards the verified CN.
            "websecure-mtls" => {
              "address" => ":#{mtls_port}",
              "http"    => {
                "tls"         => { "options" => "mtls-required@file" },
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

      # Writes the shared dynamic config holding the mTLS-required TLS
      # option set + the passTLSClientCert middleware. These primitives
      # are referenced by per-account routers via `mtls-required@file`
      # and `pass-tls-client-cert@file`. Idempotent.
      #
      # Header forwarding: passTLSClientCert.info.subject.commonName=true
      # makes Traefik emit
      #   X-Forwarded-Tls-Client-Cert-Info: Subject="CN=<value>"
      # which BaseController#mtls_subject_cn parses. The agent's cert CN
      # is its NodeInstance.id, so the platform can resolve the caller
      # without consulting a JWT.
      def write_mtls_shared_dynamic!(dynamic_dir: nil, ca_dir: nil)
        dir = dynamic_dir || default_dynamic_dir
        ca_path = File.join(ca_dir || default_ca_dir, INTERNAL_CA_FILENAME)
        FileUtils.mkdir_p(dir)
        out = File.join(dir, SHARED_MTLS_FILENAME)
        File.write(out, YAML.dump(shared_mtls_config(ca_path)))
        out
      end

      def shared_mtls_config(ca_path)
        {
          "tls" => {
            "options" => {
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
          "certificates" => certs.map { |c| render_cert_entry(c) }
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

    # Additional hostnames Traefik should route to the same backend/frontend
    # services as the cert's common_name. Used when the platform sits behind
    # an external reverse proxy that terminates a public hostname's TLS and
    # forwards HTTP requests with the original Host header preserved.
    #
    # Example (ops): cert is for `ops.ipnode.net` (internal), but the public
    # face `ops.powernode.org` lands here via the external proxy. Setting
    # POWERNODE_PROXY_EXTRA_HOSTS=ops.powernode.org makes the router rule
    # match both Host values without claiming to have a cert for the public
    # name (TLS for the public hostname is the external proxy's job).
    #
    # Comma-separated; whitespace trimmed; empty entries dropped.
    def self.extra_hosts
      raw = ENV["POWERNODE_PROXY_EXTRA_HOSTS"].to_s
      raw.split(",").map(&:strip).reject(&:empty?)
    end

    private

    def render_cert_entry(cert)
      {
        "certFile" => self.class.cert_file_path(cert, cert_dir: @cert_dir),
        "keyFile"  => self.class.key_file_path(cert, cert_dir: @cert_dir),
        "stores"   => [ "default" ]
      }
    end

    # Six routers per cert, split across TWO entrypoints to avoid Traefik's
    # per-SNI TLS-option conflict (one host can't simultaneously require +
    # not-require client certs on the same listener):
    #
    # `websecure` (:443) — NO client cert required:
    #   - <slug>-api            — Host(`cn`) && PathPrefix(`/api`)
    #   - <slug>-cable          — Host(`cn`) && PathPrefix(`/cable`)   (ActionCable WS)
    #   - <slug>-frontend       — Host(`cn`)                            (catchall)
    #
    # `websecure-mtls` (:4443) — mTLS-REQUIRED at the listener level (the
    # entrypoint's http.tls.options sets mtls-required@file as the default,
    # and the entrypoint's http.middlewares forwards the verified CN — no
    # per-router config needed):
    #   - <slug>-node-api       — Host(`cn`) && PathPrefix(`/api/v1/system/node_api`)
    #                              (agent client cert)
    #   - <slug>-federation-api — Host(`cn`) && PathPrefix(`/api/v1/system/federation_api`)
    #                              (federation peer client cert)
    #   - <slug>-internal-api   — Host(`cn`) && PathPrefix(`/api/v1/internal`)
    #                              (Sidekiq worker client cert)
    #   - <slug>-worker-auth    — Host(`cn`) && PathPrefix(`/api/v1/worker_auth`)
    #                              (worker-web client cert; user creds in body)
    #   - <slug>-cable-mtls     — Host(`cn`) && PathPrefix(`/cable`)
    #                              (Sidekiq worker WS; user browsers use the
    #                               <slug>-cable router on :443 with user JWT)
    #
    # Controllers decide what kind of identity the verified cert belongs to:
    #   NodeApi::BaseController        → looks up NodeInstance by CN
    #   FederationApi::BaseController  → looks up NodeCertificate with subject_kind="federation_peer"
    #   Internal::InternalBaseController (in core) → looks up Worker by CN
    #   WorkerAuthController (in core) → looks up Worker by CN, validates user body
    #   ApplicationCable::Connection   → mTLS arm resolves Worker by CN, user-JWT arm resolves User
    def render_routers(cert)
      slug = router_slug(cert)
      hosts_matcher = build_hosts_matcher(cert.common_name)
      mtls_tls = { "options" => "mtls-required@file" }
      [
        [ "#{slug}-node-api", {
          "rule"        => "#{hosts_matcher} && PathPrefix(`/api/v1/system/node_api`)",
          "service"     => "powernode-backend",
          "entryPoints" => [ "websecure-mtls" ],
          "tls"         => mtls_tls
        } ],
        [ "#{slug}-federation-api", {
          "rule"        => "#{hosts_matcher} && PathPrefix(`/api/v1/system/federation_api`)",
          "service"     => "powernode-backend",
          "entryPoints" => [ "websecure-mtls" ],
          "tls"         => mtls_tls
        } ],
        [ "#{slug}-internal-api", {
          "rule"        => "#{hosts_matcher} && PathPrefix(`/api/v1/internal`)",
          "service"     => "powernode-backend",
          "entryPoints" => [ "websecure-mtls" ],
          "tls"         => mtls_tls
        } ],
        [ "#{slug}-worker-api", {
          "rule"        => "#{hosts_matcher} && PathPrefix(`/api/v1/system/worker_api`)",
          "service"     => "powernode-backend",
          "entryPoints" => [ "websecure-mtls" ],
          "tls"         => mtls_tls
        } ],
        [ "#{slug}-worker-auth", {
          "rule"        => "#{hosts_matcher} && PathPrefix(`/api/v1/worker_auth`)",
          "service"     => "powernode-backend",
          "entryPoints" => [ "websecure-mtls" ],
          "tls"         => mtls_tls
        } ],
        [ "#{slug}-cable-mtls", {
          "rule"        => "#{hosts_matcher} && PathPrefix(`/cable`)",
          "service"     => "powernode-backend",
          "entryPoints" => [ "websecure-mtls" ],
          "tls"         => mtls_tls
        } ],
        [ "#{slug}-api", {
          "rule"        => "#{hosts_matcher} && PathPrefix(`/api`)",
          "service"     => "powernode-backend",
          "entryPoints" => [ "websecure" ],
          "tls"         => {}
        } ],
        [ "#{slug}-agent", {
          # Federation-spawned children fetch the powernode-agent binary
          # from their parent via this prefix on the public entrypoint.
          # The Rails app symlinks the binary under public/agent/ so the
          # static file server serves it — no controller required.
          "rule"        => "#{hosts_matcher} && PathPrefix(`/agent`)",
          "service"     => "powernode-backend",
          "entryPoints" => [ "websecure" ],
          "tls"         => {}
        } ],
        [ "#{slug}-cable", {
          "rule"        => "#{hosts_matcher} && PathPrefix(`/cable`)",
          "service"     => "powernode-backend",
          "entryPoints" => [ "websecure" ],
          "tls"         => {}
        } ],
        [ "#{slug}-frontend", {
          "rule"        => hosts_matcher,
          "service"     => "powernode-frontend",
          "entryPoints" => [ "websecure" ],
          "tls"         => {}
        } ]
      ]
    end

    # Builds Traefik's host matcher. Without extra hosts configured, emits
    # the single-host form `Host(\`cn\`)`. With extras, emits OR'd matchers
    # `(Host(\`cn\`) || Host(\`extra1\`) || Host(\`extra2\`))` because
    # Traefik v3's `Host()` only accepts one hostname per invocation —
    # multi-arg `Host(a, b)` was a v2 form that v3 rejects with
    # "unexpected number of parameters". Parentheses wrap the OR so the
    # operator precedence with the trailing `&& PathPrefix(...)` is right.
    def build_hosts_matcher(primary_host)
      hosts = [ primary_host ] + self.class.extra_hosts
      return "Host(`#{primary_host}`)" if hosts.size == 1
      formatted = hosts.map { |h| "Host(`#{h}`)" }.join(" || ")
      "(#{formatted})"
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
        }
      }
    end

    # Traefik router names are arbitrary but should be deterministic +
    # human-readable. Use the cert's common_name with non-DNS chars
    # collapsed to dashes.
    def router_slug(cert)
      cert.common_name.to_s.gsub(/[^a-zA-Z0-9]+/, "-").gsub(/(^-|-$)/, "")
    end
  end
end
