# frozen_string_literal: true

require "yaml"
require "fileutils"

module Sdwan
  # Offering-side writer: emits Traefik dynamic config for an account's LOCALLY
  # exposed services (Sdwan::Service#local_enabled) as `/svc/<slug>` routers on
  # the account's own host(s). This is the mirror of Federation::ServiceRouteWriter
  # (which is the SUBSCRIBER side, routing to remote backends). One YAML file per
  # account in the dynamic-config dir; Traefik file-watches and hot-reloads.
  #
  # Acme::TraefikConfigWriter stays focused on the platform's own per-cert routers
  # — Traefik merges all dynamic files. Router/service/middleware keys live in
  # distinct namespaces (`<slug>-*` platform, `localsvc-*` here, `sub-*` federation)
  # so they never collide.
  #
  # Per-service output shape:
  #
  #   http:
  #     routers:
  #       localsvc-<id>:
  #         rule: (Host(`cn`) || …) && PathPrefix(`/svc/<slug>`)
  #         service: localsvc-<id>
  #         entryPoints: [websecure]
  #         tls: { options: mtls-optional@file }
  #         middlewares: [localsvc-<id>-forwardauth, localsvc-<id>-stripprefix, localsvc-<id>-headers]
  #     services:
  #       localsvc-<id>:
  #         loadBalancer: { servers: [{ url: <scheme>://<vip-or-host>:<port> }], passHostHeader: true }
  #     middlewares:
  #       localsvc-<id>-forwardauth: { forwardAuth: { address:…?service=<id>, authResponseHeaders:…, trustForwardHeader:false } }
  #       localsvc-<id>-stripprefix: { stripPrefix: { prefixes: [/svc/<slug>] } }
  #       localsvc-<id>-headers:     { headers: { customRequestHeaders: { X-Forwarded-Prefix: /svc/<slug> } } }
  class ServiceExposureWriter
    class WriteError < StandardError; end

    # Identity headers the ForwardAuth endpoint returns and Traefik forwards to
    # the backend (authResponseHeaders). Inbound spoofed copies are dropped
    # because trustForwardHeader is false and the backend trusts only these.
    FORWARD_AUTH_HEADERS = %w[X-Powernode-User X-Powernode-Groups X-Powernode-Account].freeze

    # Same websecure entrypoint + clientAuth option as the platform routers, so
    # there is no per-SNI clientAuth conflict on a shared host (Traefik binds the
    # option by HostSNI). Local services authenticate via ForwardAuth, not mTLS.
    ENTRYPOINT   = "websecure"
    TLS_RESOLVER = "mtls-optional@file"

    class << self
      def write!(account:, dynamic_dir: nil)
        new(account: account, dynamic_dir: dynamic_dir).write!
      end

      # Internal URL Traefik's forwardAuth middleware calls to authenticate a
      # caller for a non-public local exposure. Env-overridable; defaults to the
      # backend's ingress forward_auth endpoint (reached over loopback on :3000).
      def forward_auth_base_url
        ENV["POWERNODE_PROXY_FORWARD_AUTH_URL"].presence ||
          "#{::Acme::TraefikConfigWriter.backend_url}/api/v1/system/ingress/forward_auth"
      end
    end

    def initialize(account:, dynamic_dir: nil)
      @account = account
      @dynamic_dir = dynamic_dir || ::Acme::TraefikConfigWriter.default_dynamic_dir
    end

    def write!
      services = exposed_services
      yaml = render_yaml(services)

      FileUtils.mkdir_p(@dynamic_dir)
      output_path = File.join(@dynamic_dir, "local-services-#{@account.id}.yaml")
      File.write(output_path, yaml)

      # route_count/skipped_service_ids reflect what render_yaml actually put
      # in the YAML (@rendered_service_ids/@skipped_service_ids), NOT
      # services.size — a caller exposing one service when its host/cert
      # can't be resolved must be able to tell "0 routers written" from
      # "1 router written" rather than reading a route_count that always
      # equals the exposed-service count regardless of what was skipped.
      { output_path: output_path, route_count: @rendered_service_ids.size,
        skipped_service_ids: @skipped_service_ids }
    rescue StandardError => e
      raise WriteError, "ServiceExposureWriter failed: #{e.class}: #{e.message}"
    end

    # Renders the Traefik dynamic hash. Public for testability (no filesystem
    # side effects). A service whose host can't be resolved is skipped — a
    # hostless PathPrefix router would hijack /svc/<slug> on every served host.
    # Records which services were rendered vs skipped (@rendered_service_ids /
    # @skipped_service_ids) so #write! can report an accurate route_count.
    def render_yaml(services)
      routers = {}
      backends = {}
      middlewares = {}
      @rendered_service_ids = []
      @skipped_service_ids  = []

      services.each do |svc|
        host = host_for(svc)
        if host.blank?
          log_skip(svc)
          @skipped_service_ids << svc.id
          next
        end

        @rendered_service_ids << svc.id
        add_service!(svc, host, routers, backends, middlewares)
      end

      top = {}
      if routers.any?
        top["http"] = { "routers" => routers, "services" => backends }
        top["http"]["middlewares"] = middlewares if middlewares.any?
      end
      YAML.dump(top)
    end

    private

    def exposed_services
      ::Sdwan::Service.locally_exposed
                      .where(account_id: @account.id)
                      .includes(:local_certificate, :backend_vip)
                      .to_a
    end

    def add_service!(svc, host, routers, backends, middlewares)
      key = svc.local_router_slug
      host_rule = ::Acme::TraefikConfigWriter.host_rule_for(host)
      chain = middleware_chain!(svc, middlewares)

      router = {
        "rule" => "#{host_rule} && PathPrefix(`#{svc.local_path_prefix}`)",
        "service" => key,
        "entryPoints" => [ ENTRYPOINT ],
        "tls" => { "options" => TLS_RESOLVER }
      }
      router["middlewares"] = chain if chain.any?
      routers[key] = router

      backends[key] = {
        "loadBalancer" => {
          "servers" => [ { "url" => svc.backend_url } ],
          "passHostHeader" => true
        }
      }
    end

    # Chain order: ForwardAuth → StripPrefix → X-Forwarded-Prefix. Authenticate on
    # the full original path first; then strip the /svc/<slug> prefix so the
    # backend sees "/"; then advertise the stripped prefix so subpath-aware apps
    # (Grafana root_url etc.) build correct absolute URLs.
    def middleware_chain!(svc, middlewares)
      chain = []

      unless svc.local_auth_mode == "public"
        mw = "#{svc.local_router_slug}-forwardauth"
        middlewares[mw] = {
          "forwardAuth" => {
            "address" => "#{self.class.forward_auth_base_url}?service=#{svc.id}",
            "authResponseHeaders" => FORWARD_AUTH_HEADERS,
            "trustForwardHeader" => false
          }
        }
        chain << mw
      end

      if svc.local_strip_prefix
        strip = "#{svc.local_router_slug}-stripprefix"
        middlewares[strip] = { "stripPrefix" => { "prefixes" => [ svc.local_path_prefix ] } }
        chain << strip

        hdr = "#{svc.local_router_slug}-headers"
        middlewares[hdr] = {
          "headers" => { "customRequestHeaders" => { "X-Forwarded-Prefix" => svc.local_path_prefix } }
        }
        chain << hdr
      end

      chain
    end

    # The host the /svc/<slug> router mounts under: the service's explicit local
    # certificate CN, else the account's primary (most recent valid) cert CN.
    def host_for(svc)
      return svc.local_certificate.common_name if svc.local_certificate

      account_primary_cert_cn
    end

    def account_primary_cert_cn
      return @account_primary_cert_cn if defined?(@account_primary_cert_cn)

      @account_primary_cert_cn =
        ::System::AcmeCertificate.where(account_id: @account.id, status: "valid")
                                 .order(created_at: :desc).limit(1).pick(:common_name)
    end

    def log_skip(svc)
      Rails.logger.warn(
        "[ServiceExposureWriter] skipping local exposure #{svc.slug} (#{svc.id}): no host/cert resolvable"
      )
      true
    end
  end
end
