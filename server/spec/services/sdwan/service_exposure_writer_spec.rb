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
