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

    class << self
      def write!(account:, dynamic_dir: nil, cert_dir: nil)
        new(account: account,
            dynamic_dir: dynamic_dir || default_dynamic_dir,
            cert_dir: cert_dir || default_cert_dir).write!
      end

      # Writes the platform's static Traefik config (entry points +
      # providers + logging). This is what systemd passes via
      # --configFile=<this path>. Idempotent — safe to call repeatedly.
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
            "websecure" => { "address" => ":443" }
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

    private

    def render_cert_entry(cert)
      {
        "certFile" => self.class.cert_file_path(cert, cert_dir: @cert_dir),
        "keyFile"  => self.class.key_file_path(cert, cert_dir: @cert_dir),
        "stores"   => [ "default" ]
      }
    end

    # Three routers per cert, all on the `websecure` (:443) entry point:
    #
    #   - <slug>-api      — Host(`cn`) && PathPrefix(`/api`)
    #   - <slug>-cable    — Host(`cn`) && PathPrefix(`/cable`)   (ActionCable WS)
    #   - <slug>-frontend — Host(`cn`)                            (catchall)
    #
    # Traefik scores routers by rule length; longer rules win. So API and
    # Cable take precedence over the frontend catchall automatically —
    # no explicit priority needed.
    def render_routers(cert)
      slug = router_slug(cert)
      host = cert.common_name
      [
        [ "#{slug}-api", {
          "rule"        => "Host(`#{host}`) && PathPrefix(`/api`)",
          "service"     => "powernode-backend",
          "entryPoints" => [ "websecure" ],
          "tls"         => {}
        } ],
        [ "#{slug}-cable", {
          "rule"        => "Host(`#{host}`) && PathPrefix(`/cable`)",
          "service"     => "powernode-backend",
          "entryPoints" => [ "websecure" ],
          "tls"         => {}
        } ],
        [ "#{slug}-frontend", {
          "rule"        => "Host(`#{host}`)",
          "service"     => "powernode-frontend",
          "entryPoints" => [ "websecure" ],
          "tls"         => {}
        } ]
      ]
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
