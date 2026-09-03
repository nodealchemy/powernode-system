# frozen_string_literal: true

require "rails_helper"
require "tmpdir"
require "yaml"

RSpec.describe Sdwan::ServiceExposureWriter, type: :service do
  let(:account)  { Account.first || create(:account) }
  let(:dns_cred) { create(:system_acme_dns_credential, :valid, account: account) }
  let(:cert) do
    create(:system_acme_certificate, :valid, account: account, dns_credential: dns_cred,
                                             common_name: "apps.example.test")
  end
  let(:tmp_dir) { Dir.mktmpdir("local-services") }

  after { FileUtils.rm_rf(tmp_dir) if Dir.exist?(tmp_dir) }

  subject(:writer) { described_class.new(account: account, dynamic_dir: tmp_dir) }

  def create_service(**attrs)
    Sdwan::Service.create!(
      { account: account, slug: "grafana-#{SecureRandom.hex(3)}", name: "Grafana",
        protocol: "https", backend_host: "10.20.0.5", backend_port: 3000,
        local_enabled: true, local_certificate: cert }.merge(attrs)
    )
  end

  def parse(services)
    YAML.safe_load(writer.render_yaml(services))
  end

  describe "#render_yaml" do
    it "emits a /svc/<slug> router on websecure pointing at the backend URL" do
      svc = create_service(slug: "grafana")
      parsed = parse([ svc ])

      router = parsed.dig("http", "routers", "localsvc-#{svc.id}")
      expect(router["rule"]).to include("Host(`apps.example.test`)").and include("PathPrefix(`/svc/grafana`)")
      expect(router["entryPoints"]).to eq([ "websecure" ])
      expect(router.dig("tls", "options")).to eq("mtls-optional@file")

      backend = parsed.dig("http", "services", "localsvc-#{svc.id}", "loadBalancer")
      expect(backend.dig("servers", 0, "url")).to eq("https://10.20.0.5:3000")
      expect(backend["passHostHeader"]).to be(true)
    end

    it "chains forwardauth -> stripprefix -> headers for authenticated mode" do
      svc = create_service(local_auth_mode: "authenticated")
      parsed = parse([ svc ])

      expect(parsed.dig("http", "routers", "localsvc-#{svc.id}", "middlewares")).to eq(
        [ "localsvc-#{svc.id}-forwardauth", "localsvc-#{svc.id}-stripprefix", "localsvc-#{svc.id}-headers" ]
      )
      fa = parsed.dig("http", "middlewares", "localsvc-#{svc.id}-forwardauth", "forwardAuth")
      expect(fa["address"]).to include("/api/v1/system/ingress/forward_auth?service=#{svc.id}")
      expect(fa["authResponseHeaders"]).to include("X-Powernode-User", "X-Powernode-Groups", "X-Powernode-Account")
      expect(fa["trustForwardHeader"]).to be(false)

      strip = parsed.dig("http", "middlewares", "localsvc-#{svc.id}-stripprefix", "stripPrefix")
      expect(strip["prefixes"]).to eq([ "/svc/#{svc.slug}" ])
      hdr = parsed.dig("http", "middlewares", "localsvc-#{svc.id}-headers", "headers", "customRequestHeaders")
      expect(hdr["X-Forwarded-Prefix"]).to eq("/svc/#{svc.slug}")
    end

    it "omits forwardAuth for public mode" do
      svc = create_service(local_auth_mode: "public")
      parsed = parse([ svc ])

      expect(parsed.dig("http", "routers", "localsvc-#{svc.id}", "middlewares")).to eq(
        [ "localsvc-#{svc.id}-stripprefix", "localsvc-#{svc.id}-headers" ]
      )
      expect(parsed.dig("http", "middlewares").keys).not_to include("localsvc-#{svc.id}-forwardauth")
    end

    it "omits stripPrefix + X-Forwarded-Prefix when strip is disabled" do
      svc = create_service(local_strip_prefix: false)
      parsed = parse([ svc ])

      expect(parsed.dig("http", "routers", "localsvc-#{svc.id}", "middlewares")).to eq(
        [ "localsvc-#{svc.id}-forwardauth" ]
      )
    end

    it "skips a service whose host can't be resolved rather than emitting a hostless router" do
      svc = create_service(local_certificate: nil)
      # no valid account cert to fall back on → must skip, not hijack /svc on every host
      System::AcmeCertificate.where(account_id: account.id).update_all(status: "revoked")
      expect(parse([ svc ])).to eq({})
    end
  end

  # Path B — public TLS-carrying TCP via Traefik SNI (campaign 019f3458 increment
  # 5). Same writer, same shared entrypoint; a separate top-level "tcp" section
  # alongside the existing "http" one so both facets coexist in one YAML file.
  describe "#render_yaml — public TCP exposure (Path B)" do
    def create_public_service(**attrs)
      Sdwan::Service.create!(
        { account: account, slug: "tls-svc-#{SecureRandom.hex(3)}", name: "TLS Service",
          protocol: "tls", backend_host: "10.30.0.7", backend_port: 5432,
          public_enabled: true, local_certificate: cert }.merge(attrs)
      )
    end

    it "emits a HostSNI tcp.router on websecure for a passthrough (default) service" do
      svc = create_public_service
      parsed = parse([ svc ])

      router = parsed.dig("tcp", "routers", "pubsvc-#{svc.id}")
      expect(router["rule"]).to eq("HostSNI(`apps.example.test`)")
      expect(router["service"]).to eq("pubsvc-#{svc.id}")
      expect(router["entryPoints"]).to eq([ "websecure" ])
      expect(router["tls"]).to eq("passthrough" => true)

      backend = parsed.dig("tcp", "services", "pubsvc-#{svc.id}", "loadBalancer", "servers", 0)
      expect(backend["address"]).to eq("10.30.0.7:5432")
      expect(parsed["http"]).to be_nil # this service has no local_enabled facet
    end

    it "terminate mode with client_auth none: bare tls hash (no options — cert resolved by SNI store match)" do
      svc = create_public_service(edge_mode: "terminate")
      router = parse([ svc ]).dig("tcp", "routers", "pubsvc-#{svc.id}")
      expect(router["tls"]).to eq({})
    end

    it "terminate mode with client_auth required: tls.options -> mtls-required@file" do
      svc = create_public_service(edge_mode: "terminate", client_auth: "required")
      router = parse([ svc ]).dig("tcp", "routers", "pubsvc-#{svc.id}")
      expect(router["tls"]).to eq("options" => "mtls-required@file")
    end

    it "resolves the HostSNI host the same way the local facet does (explicit cert, else account primary)" do
      # Creating the service touches the shared `cert` let (apps.example.test) as
      # a side effect even though it's not attached below; revoke it afterward so
      # only the fallback cert created next is a valid candidate — deterministic
      # regardless of creation-order ties on created_at.
      svc = create_public_service(local_certificate: nil)
      System::AcmeCertificate.where(account_id: account.id).update_all(status: "revoked")
      create(:system_acme_certificate, :valid, account: account,
                                                dns_credential: dns_cred, common_name: "fallback.example.test")

      router = parse([ svc ]).dig("tcp", "routers", "pubsvc-#{svc.id}")
      expect(router["rule"]).to eq("HostSNI(`fallback.example.test`)")
    end

    it "skips a public service whose host can't be resolved, same as the local facet" do
      svc = create_public_service(local_certificate: nil)
      System::AcmeCertificate.where(account_id: account.id).update_all(status: "revoked")
      expect(parse([ svc ])).to eq({})
    end

    it "coexists with a local-facet service in the same render without cross-contamination" do
      local_svc  = create_service(slug: "local-one")
      public_svc = create_public_service
      parsed = parse([ local_svc, public_svc ])

      expect(parsed.dig("http", "routers", "localsvc-#{local_svc.id}")).to be_present
      expect(parsed.dig("tcp", "routers", "pubsvc-#{public_svc.id}")).to be_present
      expect(parsed.dig("http", "routers", "pubsvc-#{public_svc.id}")).to be_nil
      expect(parsed.dig("tcp", "routers", "localsvc-#{local_svc.id}")).to be_nil
    end

    # REGRESSION — a service with public_enabled=false (the default/existing
    # shape for every pre-increment-5 row) must render byte-identical HTTP
    # output; no "tcp" key at all should appear.
    it "produces zero change for an existing local-only service (public_enabled defaults false)" do
      svc = create_service(slug: "unaffected")
      parsed = parse([ svc ])
      expect(parsed.key?("tcp")).to be(false)
      expect(parsed.dig("http", "routers", "localsvc-#{svc.id}", "tls", "options")).to eq("mtls-optional@file")
    end
  end

  describe "#write!" do
    it "writes one file per account and reports the route count" do
      create_service
      result = writer.write!
      expect(File.basename(result[:output_path])).to eq("local-services-#{account.id}.yaml")
      expect(result[:route_count]).to eq(1)
      expect(File.exist?(result[:output_path])).to be(true)
    end

    it "excludes a hostless/uncertified service from route_count and reports it as skipped " \
       "(bug: route_count previously counted every exposed service regardless of whether its " \
       "router was actually rendered, so a caller couldn't tell a skip from a real success)" do
      svc = create_service(local_certificate: nil)
      # no valid account cert to fall back on -> render_yaml must skip this service's router
      System::AcmeCertificate.where(account_id: account.id).update_all(status: "revoked")

      result = writer.write!

      expect(result[:route_count]).to eq(0)
      expect(result[:skipped_service_ids]).to eq([ svc.id ])
      expect(result[:drained_service_ids]).to eq([])
    end

    # Operator ruling 2026-09-02 (APO-3d). Rendering a router with an empty
    # `servers` list is a 503 machine, and falling back to the legacy columns
    # sends every request to the host a replace cycle just declared dead.
    it "skips a service whose backend set is ENTIRELY draining, renders no router for it, and " \
       "reports it under drained_service_ids rather than the host/cert skip list" do
      svc = create_service(slug: "all-draining", backend_host: "10.20.0.5", backend_port: 3000)
      Sdwan::ServiceBackend.create!(service: svc, backend_host: "10.20.0.11",
                                    backend_port: 3000, status: "draining")

      allow(Rails.logger).to receive(:warn)
      result = writer.write!

      expect(result[:route_count]).to eq(0)
      expect(result[:drained_service_ids]).to eq([ svc.id ])
      # The two reasons stay SEPARATE: ExposeServiceLocalExecutor turns
      # skipped_service_ids membership into a certificate-shaped remediation
      # message, which is a fabricated cause for a drained set.
      expect(result[:skipped_service_ids]).to eq([])
      expect(YAML.safe_load(File.read(result[:output_path])).to_h).to eq({})
      expect(Rails.logger).to have_received(:warn).with(/draining/)
    end
  end

  # APO-3c — load balancing across a scaled project's backend set. Before this
  # increment a Sdwan::Service had exactly ONE backend and the writer emitted a
  # single `servers` entry with no weights and no health check, so scaling a
  # project out produced replicas that received no traffic at all.
  describe "#render_yaml — multi-backend load balancing (APO-3c)" do
    def add_backend(svc, host, port: 8080, **attrs)
      Sdwan::ServiceBackend.create!({ service: svc, backend_host: host, backend_port: port }.merge(attrs))
    end

    # EQUALITY oracle, not a `include`/`dig` oracle: the whole point of the
    # degenerate case is that NOTHING new appears in it, which a subset
    # assertion cannot see. Same hash, same key order, therefore same YAML bytes.
    it "leaves a single-backend service byte-identical to the pre-load-balancing output" do
      svc = create_service(slug: "solo", backend_host: "10.20.0.5", backend_port: 3000)

      lb = parse([ svc ]).dig("http", "services", "localsvc-#{svc.id}", "loadBalancer")

      expect(lb).to eq("servers" => [ { "url" => "https://10.20.0.5:3000" } ],
                       "passHostHeader" => true)
      expect(lb.keys).to eq(%w[servers passHostHeader])
    end

    it "leaves a single-backend service byte-identical even when ONE explicit backend row exists" do
      svc = create_service(slug: "solo-explicit")
      add_backend(svc, "10.20.0.11", port: 3000)

      lb = parse([ svc.reload ]).dig("http", "services", "localsvc-#{svc.id}", "loadBalancer")

      expect(lb).to eq("servers" => [ { "url" => "https://10.20.0.11:3000" } ],
                       "passHostHeader" => true)
    end

    it "fans the http loadBalancer out to one server per backend, in a deterministic order" do
      svc = create_service(slug: "scaled")
      add_backend(svc, "10.20.0.11")
      add_backend(svc, "10.20.0.12")
      add_backend(svc, "10.20.0.13")

      lb = parse([ svc.reload ]).dig("http", "services", "localsvc-#{svc.id}", "loadBalancer")

      expect(lb["servers"].map { |s| s["url"] }).to eq(
        [ "https://10.20.0.11:8080", "https://10.20.0.12:8080", "https://10.20.0.13:8080" ]
      )
      expect(lb["passHostHeader"]).to be(true)
    end

    it "omits per-server weight while the set is uniform" do
      svc = create_service(slug: "uniform")
      add_backend(svc, "10.20.0.11")
      add_backend(svc, "10.20.0.12")

      servers = parse([ svc.reload ]).dig("http", "services", "localsvc-#{svc.id}",
                                          "loadBalancer", "servers")

      expect(servers.map(&:keys).flatten.uniq).to eq([ "url" ])
    end

    it "emits weighted round robin once the operator differentiates the weights" do
      svc = create_service(slug: "weighted")
      add_backend(svc, "10.20.0.11", weight: 3)
      add_backend(svc, "10.20.0.12", weight: 1)

      servers = parse([ svc.reload ]).dig("http", "services", "localsvc-#{svc.id}",
                                          "loadBalancer", "servers")

      expect(servers).to eq([
        { "url" => "https://10.20.0.11:8080", "weight" => 3 },
        { "url" => "https://10.20.0.12:8080", "weight" => 1 }
      ])
    end

    # Health checking is OPT-IN: a check aimed at the wrong path takes the WHOLE
    # pool out (Traefik 503s once every server has failed), which is worse than
    # the single unchecked backend it replaced. So a fanned-out service gets no
    # healthCheck until somebody who knows the path asks for one.
    it "attaches NO health check to a multi-backend http service by default" do
      svc = create_service(slug: "checked")
      add_backend(svc, "10.20.0.11")
      add_backend(svc, "10.20.0.12")

      lb = parse([ svc.reload ]).dig("http", "services", "localsvc-#{svc.id}", "loadBalancer")

      expect(Sdwan::ServiceLoadBalancing::DEFAULT_HEALTH_CHECK_ENABLED).to be(false)
      expect(lb.key?("healthCheck")).to be(false)
      expect(lb["servers"].size).to eq(2)
    end

    it "attaches the health check once a service opts in" do
      svc = create_service(slug: "opted-in",
                           metadata: { "load_balancer" => { "health_check_enabled" => true } })
      add_backend(svc, "10.20.0.11")
      add_backend(svc, "10.20.0.12")

      health = parse([ svc.reload ]).dig("http", "services", "localsvc-#{svc.id}",
                                         "loadBalancer", "healthCheck")

      expect(health).to eq(
        "path"     => Sdwan::ServiceLoadBalancing::DEFAULT_HEALTH_CHECK_PATH,
        "interval" => Sdwan::ServiceLoadBalancing::DEFAULT_HEALTH_CHECK_INTERVAL,
        "timeout"  => Sdwan::ServiceLoadBalancing::DEFAULT_HEALTH_CHECK_TIMEOUT
      )
    end

    it "resolves the health-check settings from SiteSetting, not from the constants" do
      SiteSetting.set("system.sdwan.service_load_balancing.health_check_enabled", true)
      SiteSetting.set("system.sdwan.service_load_balancing.health_check_path", "/healthz")
      SiteSetting.set("system.sdwan.service_load_balancing.health_check_interval", "45s")
      SiteSetting.set("system.sdwan.service_load_balancing.health_check_timeout", "9s")

      svc = create_service(slug: "sitesetting")
      add_backend(svc, "10.20.0.11")
      add_backend(svc, "10.20.0.12")

      health = parse([ svc.reload ]).dig("http", "services", "localsvc-#{svc.id}",
                                         "loadBalancer", "healthCheck")

      expect(health).to eq("path" => "/healthz", "interval" => "45s", "timeout" => "9s")
    end

    it "lets a single service override the health-check path without moving the deployment default" do
      SiteSetting.set("system.sdwan.service_load_balancing.health_check_enabled", true)
      svc = create_service(slug: "per-service",
                           metadata: { "load_balancer" => { "health_check_path" => "/-/ready" } })
      add_backend(svc, "10.20.0.11")
      add_backend(svc, "10.20.0.12")

      health = parse([ svc.reload ]).dig("http", "services", "localsvc-#{svc.id}",
                                         "loadBalancer", "healthCheck")

      expect(health["path"]).to eq("/-/ready")
    end

    # `false` is a VALUE, not an absence: the per-service switch must beat a
    # deployment-wide `true`, which a `.presence ||` chain would drop.
    it "lets a service switch the health check off under a deployment-wide default of on" do
      SiteSetting.set("system.sdwan.service_load_balancing.health_check_enabled", true)
      svc = create_service(slug: "unchecked",
                           metadata: { "load_balancer" => { "health_check_enabled" => false } })
      add_backend(svc, "10.20.0.11")
      add_backend(svc, "10.20.0.12")

      lb = parse([ svc.reload ]).dig("http", "services", "localsvc-#{svc.id}", "loadBalancer")

      expect(lb.key?("healthCheck")).to be(false)
      expect(lb["servers"].size).to eq(2)
    end

    it "never emits a health check for a single-backend service, however it is configured" do
      SiteSetting.set("system.sdwan.service_load_balancing.health_check_enabled", true)
      SiteSetting.set("system.sdwan.service_load_balancing.health_check_path", "/healthz")
      svc = create_service(slug: "solo-nocheck")

      lb = parse([ svc ]).dig("http", "services", "localsvc-#{svc.id}", "loadBalancer")

      expect(lb.key?("healthCheck")).to be(false)
    end

    it "fans the public tcp loadBalancer out to every backend (address form, no weight/health)" do
      svc = Sdwan::Service.create!(
        account: account, slug: "tls-scaled", name: "TLS Service", protocol: "tls",
        backend_host: "10.30.0.7", backend_port: 5432, public_enabled: true,
        local_certificate: cert
      )
      add_backend(svc, "10.30.0.8", port: 5432)
      add_backend(svc, "10.30.0.9", port: 5432, weight: 5)

      lb = parse([ svc.reload ]).dig("tcp", "services", "pubsvc-#{svc.id}", "loadBalancer")

      expect(lb).to eq("servers" => [ { "address" => "10.30.0.8:5432" },
                                      { "address" => "10.30.0.9:5432" } ])
    end

    # Sdwan::Service#load_balanced_backends filters and orders in RUBY rather
    # than in SQL for exactly one reason: a scoped/ordered association call
    # would issue a fresh query per service and defeat the writer's
    # `includes(backends: :backend_vip)`. Nothing else in the suite goes
    # through #write! (the `parse` helper hand-builds its service array), so
    # without this a "tidy-up" to `backends.active.order(:created_at)` would
    # reintroduce the N+1 and stay green.
    it "loads every service's backend set in ONE query, not one per service" do
      2.times do |i|
        svc = create_service(slug: "eager-#{i}")
        add_backend(svc, "10.20.1.#{i}0")
        add_backend(svc, "10.20.1.#{i}1")
      end

      backend_queries = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        sql = payload[:sql].to_s
        backend_queries << sql if sql.include?("system_sdwan_service_backends") && sql.start_with?("SELECT")
      end

      begin
        described_class.new(account: account, dynamic_dir: tmp_dir).write!
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      expect(backend_queries.size).to eq(1), "expected one eager-load, got:\n#{backend_queries.join("\n")}"
    end
  end
end
