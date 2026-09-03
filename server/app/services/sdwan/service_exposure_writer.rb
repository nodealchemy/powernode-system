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
  #
  # A service with a multi-member Sdwan::ServiceBackend set (APO-3c) renders one
  # `servers` entry per member, plus `weight` when the members' weights differ
  # and a `healthCheck` block (Sdwan::ServiceLoadBalancing). A service with no
  # backend set — the norm — renders exactly the single-server shape above,
  # byte for byte. A service whose set is ENTIRELY draining is skipped
  # (Sdwan::Service#fully_drained?, APO-3d) and reported under its OWN key,
  # drained_service_ids — never rendered with an empty `servers` list, and
  # never silently redirected to its legacy columns.
  #
  # The two skip reasons are reported SEPARATELY on purpose.
  # skipped_service_ids keeps its original, single meaning — "no host/cert
  # resolvable" — because its consumer (System::Ai::Skills::ExposeServiceLocalExecutor)
  # turns membership into a cert-shaped remediation message. Folding a drained
  # set into the same list would have that executor fail a legitimate expose
  # with a fabricated cause and a remedy that cannot work.
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

    # Path B (public TLS-carrying TCP, campaign 019f3458 increment 5): the
    # REQUIRED-client-cert counterpart of TLS_RESOLVER, applied only when a
    # public_enabled service opts into `client_auth == "required"` under
    # `edge_mode == "terminate"` (model validation ties the two together —
    # Traefik cannot inspect a client cert on an undecrypted passthrough
    # stream). Defined in Acme::TraefikConfigWriter.shared_mtls_config
    # alongside mtls-optional, same shared CA bundle.
    PUBLIC_MTLS_REQUIRED_OPTION = "mtls-required@file"

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

      # route_count/skipped_service_ids/drained_service_ids reflect what
      # render_yaml actually put in the YAML, NOT services.size — a caller
      # exposing one service when its host/cert can't be resolved must be able
      # to tell "0 routers written" from "1 router written" rather than reading
      # a route_count that always equals the exposed-service count regardless
      # of what was skipped. Each skip reason keeps its own list so a caller
      # diagnoses the one it actually hit.
      { output_path: output_path, route_count: @rendered_service_ids.size,
        skipped_service_ids: @skipped_service_ids,
        drained_service_ids: @drained_service_ids }
    rescue StandardError => e
      raise WriteError, "ServiceExposureWriter failed: #{e.class}: #{e.message}"
    end

    # Renders the Traefik dynamic hash. Public for testability (no filesystem
    # side effects). A service whose host can't be resolved is skipped — a
    # hostless PathPrefix/HostSNI router would hijack traffic on every served
    # host. So is a service whose backend set is fully drained — a router with
    # no servers is a 503 machine, and the legacy columns are not a fallback
    # once a set exists (APO-3d). Each service independently opts into the local (HTTP, `http.*`)
    # and/or public (TLS-carrying TCP, `tcp.*`) facet — the two are mutually
    # exclusive in practice (local requires an http/https protocol, public
    # requires tls), but this method makes no assumption of that and just
    # dispatches on each flag. Records which services were rendered vs skipped
    # (@rendered_service_ids / @skipped_service_ids) so #write! can report an
    # accurate route_count, and under which reason
    # (@skipped_service_ids = no host/cert, @drained_service_ids = set fully
    # draining).
    def render_yaml(services)
      routers = {}
      backends = {}
      middlewares = {}
      tcp_routers = {}
      tcp_backends = {}
      @rendered_service_ids = []
      @skipped_service_ids  = []
      @drained_service_ids  = []

      services.each do |svc|
        if svc.fully_drained?
          log_skip(svc, reason: "every backend is draining")
          @drained_service_ids << svc.id
          next
        end

        host = host_for(svc)
        if host.blank?
          log_skip(svc, reason: "no host/cert resolvable")
          @skipped_service_ids << svc.id
          next
        end

        @rendered_service_ids << svc.id
        add_service!(svc, host, routers, backends, middlewares) if svc.local_enabled?
        add_public_tcp_route!(svc, host, tcp_routers, tcp_backends) if svc.public_enabled?
      end

      top = {}
      if routers.any?
        top["http"] = { "routers" => routers, "services" => backends }
        top["http"]["middlewares"] = middlewares if middlewares.any?
      end
      top["tcp"] = { "routers" => tcp_routers, "services" => tcp_backends } if tcp_routers.any?
      YAML.dump(top)
    end

    private

    # Union of both exposure facets — a service opts into either, both (not
    # possible today; mutually exclusive by protocol validation), or neither.
    def exposed_services
      ::Sdwan::Service.active
                      .where(account_id: @account.id)
                      .where("local_enabled OR public_enabled")
                      .includes(:local_certificate, :backend_vip, backends: :backend_vip)
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

      backends[key] = { "loadBalancer" => http_load_balancer(svc) }
    end

    # The HTTP servers load balancer for the service's effective backend set
    # (APO-3c). Before the set existed this emitted one hardcoded server built
    # from the service's own backend columns, so scaling a project out produced
    # replicas that received no traffic.
    #
    # DEGENERATE CASE IS BYTE-IDENTICAL, and that is load-bearing: a service
    # with one backend (i.e. every service with no Sdwan::ServiceBackend rows)
    # renders `{"servers" => [{"url" => …}], "passHostHeader" => true}` — same
    # keys, same order, no weight, no healthCheck — so YAML.dump produces the
    # same bytes it always did and Traefik does not reload a single existing
    # account's dynamic file on deploy.
    def http_load_balancer(svc)
      targets = svc.load_balanced_backends

      lb = {
        "servers" => targets.map { |target| http_server_entry(svc, target, targets) },
        "passHostHeader" => true
      }
      health = health_check_for(svc, targets)
      lb["healthCheck"] = health if health
      lb
    end

    def http_server_entry(svc, target, targets)
      entry = { "url" => target.url(scheme: svc.protocol) }
      entry["weight"] = target.weight if weighted?(targets)
      entry
    end

    # Per-server `weight` rides the servers load balancer only once the operator
    # has actually differentiated the members. A uniform set IS round robin, so
    # emitting `weight: 1` on every server changes nothing about how traffic is
    # spread — it only widens the schema of every file this writer produces for
    # no behavioural gain. Emitting the key exactly when it MEANS something
    # keeps the generated config the smallest thing that expresses the intent.
    # (`weight` is documented on http.services.<x>.loadBalancer.servers for the
    # Traefik the reverse-proxy-traefik module installs — 3.7.1 per
    # scripts/module-build/stage15.sh, whose static config is the only thing in
    # the tree pointing at /etc/traefik/dynamic.)
    def weighted?(targets)
      targets.size > 1 && targets.map(&:weight).uniq.size > 1
    end

    # Health checks are for pools. A single-backend service has nowhere to fail
    # over TO, so a check there can only take the one backend out — never emit
    # one. Defaults (path/interval/timeout, and the off switch) resolve through
    # Sdwan::ServiceLoadBalancing: service metadata, then account settings, then
    # SiteSetting, then its constants.
    def health_check_for(svc, targets)
      return nil unless targets.size > 1

      ::Sdwan::ServiceLoadBalancing.health_check_for(svc, account: @account)
    end

    # Path B — public TLS-carrying TCP via Traefik SNI (campaign 019f3458
    # increment 5). Traefik demuxes this alongside the platform's own HTTP(S)
    # routers on the SAME websecure entrypoint by inspecting the ClientHello's
    # SNI; no new entrypoint is ever added (ratified in
    # docs/operations/reverse-proxy.md + the runbook's Path B section).
    #
    #   edge_mode "passthrough" (default) — Traefik forwards the encrypted
    #     stream untouched; the backend terminates TLS itself.
    #   edge_mode "terminate" — Traefik terminates. No `passthrough`/`certFile`
    #     key is set here: Traefik resolves the serving cert by matching the
    #     router's HostSNI against the `tls.certificates` entries
    #     Acme::TraefikConfigWriter already emits for every valid
    #     System::AcmeCertificate (reused, not duplicated). `client_auth ==
    #     "required"` layers on the shared REQUIRED-client-cert TLS option
    #     (model validation already ties that to edge_mode terminate, since
    #     Traefik cannot inspect a client cert on an undecrypted passthrough
    #     stream).
    #
    # Same address-form TCP backend regardless of edge_mode — Traefik's TCP
    # loadBalancer dials a bare host:port, not a URL (mirrors
    # Federation::ServiceRouteWriter#add_tcp_route!).
    def add_public_tcp_route!(svc, host, routers, backends)
      key = svc.public_router_slug

      router = {
        "rule" => "HostSNI(`#{host}`)",
        "service" => key,
        "entryPoints" => [ ENTRYPOINT ]
      }
      router["tls"] =
        if svc.edge_mode == "terminate"
          svc.client_auth == "required" ? { "options" => PUBLIC_MTLS_REQUIRED_OPTION } : {}
        else
          { "passthrough" => true }
        end
      routers[key] = router

      backends[key] = { "loadBalancer" => { "servers" => tcp_server_entries(svc) } }
    end

    # The TCP facet fans out to one server per backend and stops there.
    #
    # Traefik's TCP servers load balancer takes a bare address per server and
    # supports NEITHER a per-server weight (WRR is a service-level construct
    # there — `tcp.services.<x>.weighted` over child services, not over the
    # servers of one load balancer) nor a healthCheck on the vendored build. So
    # weights and health checks stay HTTP-only; a scaled TLS service gets plain
    # round robin, which is still the difference between N replicas serving and
    # one.
    #
    # "#{address}:#{port}" rather than Sdwan::HostPort.join, deliberately: this
    # writer and Federation::ServiceRouteWriter emit the unbracketed form (see
    # the divergence documented in Sdwan::HostPort's header), and the degenerate
    # single-backend output must not change bytes here either.
    def tcp_server_entries(svc)
      svc.load_balanced_backends.map do |target|
        { "address" => "#{target.address}:#{target.backend_port}" }
      end
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
            # .dup: FORWARD_AUTH_HEADERS is a shared frozen constant. Emitting the
            # SAME Array instance into 2+ services' middleware hashes makes
            # YAML.dump anchor/alias it (Psych detects the repeated object_id) —
            # Psych::AliasesNotEnabled then rejects re-parsing via YAML.safe_load
            # (discovered rendering 2 authenticated-mode services in one call;
            # Traefik's own YAML parser tolerates aliases, but no Ruby-side
            # re-parse should have to).
            "authResponseHeaders" => FORWARD_AUTH_HEADERS.dup,
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

    def log_skip(svc, reason:)
      Rails.logger.warn(
        "[ServiceExposureWriter] skipping exposure #{svc.slug} (#{svc.id}): #{reason}"
      )
      true
    end
  end
end
