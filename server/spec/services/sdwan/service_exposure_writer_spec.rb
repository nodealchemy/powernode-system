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
    end
  end
end
