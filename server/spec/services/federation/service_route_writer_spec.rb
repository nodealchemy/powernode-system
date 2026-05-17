# frozen_string_literal: true

require "rails_helper"
require "tmpdir"
require "yaml"

RSpec.describe Federation::ServiceRouteWriter, type: :service do
  let(:account) { create(:account) }
  let(:tmp_dir) { Dir.mktmpdir("traefik-routes") }

  after { FileUtils.rm_rf(tmp_dir) if Dir.exist?(tmp_dir) }

  describe ".write!" do
    context "with no active subscriptions" do
      it "writes an empty config (no http or tcp blocks)" do
        result = described_class.write!(account: account, dynamic_dir: tmp_dir)
        expect(result[:route_count]).to eq(0)
        parsed = YAML.load_file(result[:output_path])
        expect(parsed).to eq({})
      end
    end

    context "with an active https subscription" do
      let!(:sub) do
        create(:system_federation_service_subscription, :active, account: account,
                                                                 protocol: "https",
                                                                 local_hostname: "git.alice.tld",
                                                                 backend_vip: "fd00:abc::10",
                                                                 backend_port: 443)
      end

      it "emits an HTTPRouter rule + service + grant-injection middleware" do
        result = described_class.write!(account: account, dynamic_dir: tmp_dir)
        expect(result[:route_count]).to eq(1)
        parsed = YAML.load_file(result[:output_path])

        router_key = "sub-#{sub.id}"
        expect(parsed["http"]["routers"][router_key]["rule"]).to eq("Host(`git.alice.tld`)")
        expect(parsed["http"]["routers"][router_key]["tls"]).to eq("certResolver" => "letsencrypt")
        expect(parsed["http"]["routers"][router_key]["middlewares"]).to eq([ "#{router_key}-grant" ])

        backend = parsed["http"]["services"]["#{router_key}-backend"]
        expect(backend["loadBalancer"]["servers"]).to eq([ { "url" => "https://fd00:abc::10:443" } ])
        expect(backend["loadBalancer"]["passHostHeader"]).to be false

        mw = parsed["http"]["middlewares"]["#{router_key}-grant"]
        expect(mw["headers"]["customRequestHeaders"]["Authorization"])
          .to eq("Bearer #{sub.federation_grant.bearer_token}")
      end
    end

    context "with an active plain-http subscription" do
      let!(:http_sub) do
        # http subscriptions don't need a cert (TLS handled upstream
        # or not at all). Pass acme_certificate: nil.
        create(:system_federation_service_subscription, :active, account: account,
                                                                  protocol: "http",
                                                                  local_hostname: "http.alice.tld",
                                                                  acme_certificate: nil)
      end

      it "emits the router with NO tls block" do
        result = described_class.write!(account: account, dynamic_dir: tmp_dir)
        parsed = YAML.load_file(result[:output_path])
        router = parsed["http"]["routers"]["sub-#{http_sub.id}"]
        expect(router).not_to have_key("tls")
      end
    end

    context "with an active tcp subscription" do
      let!(:tcp_sub) do
        create(:system_federation_service_subscription, :active, :tcp, account: account,
                                                                        protocol: "tcp",
                                                                        local_hostname: "pg.alice.tld",
                                                                        backend_vip: "fd00:abc::20",
                                                                        backend_port: 5432,
                                                                        acme_certificate: nil)
      end

      it "emits a TCPRouter with HostSNI + load-balancer address" do
        result = described_class.write!(account: account, dynamic_dir: tmp_dir)
        parsed = YAML.load_file(result[:output_path])
        router = parsed["tcp"]["routers"]["sub-#{tcp_sub.id}"]
        expect(router["rule"]).to eq("HostSNI(`pg.alice.tld`)")
        expect(router).not_to have_key("tls")  # tcp (not tls) → no tls block

        backend = parsed["tcp"]["services"]["sub-#{tcp_sub.id}-backend"]
        expect(backend["loadBalancer"]["servers"]).to eq([ { "address" => "fd00:abc::20:5432" } ])
      end
    end

    context "with an active TLS-wrapped TCP subscription" do
      let!(:tls_sub) do
        create(:system_federation_service_subscription, :active, account: account,
                                                                  protocol: "tls",
                                                                  local_hostname: "mqtt.alice.tld",
                                                                  backend_vip: "fd00:abc::30",
                                                                  backend_port: 8883)
      end

      it "emits a TCPRouter with tls block" do
        result = described_class.write!(account: account, dynamic_dir: tmp_dir)
        parsed = YAML.load_file(result[:output_path])
        router = parsed["tcp"]["routers"]["sub-#{tls_sub.id}"]
        expect(router["tls"]).to eq({})
      end
    end

    context "with mixed subscriptions including site-local" do
      let!(:https_sub) do
        create(:system_federation_service_subscription, :active, account: account,
                                                                  protocol: "https",
                                                                  local_hostname: "git.alice.tld")
      end
      let!(:site_local_sub) do
        create(:system_federation_service_subscription, :active, :site_local, account: account)
      end

      it "includes the public sub and excludes the site-local sub" do
        result = described_class.write!(account: account, dynamic_dir: tmp_dir)
        expect(result[:route_count]).to eq(1)
        parsed = YAML.load_file(result[:output_path])
        expect(parsed["http"]["routers"]).to have_key("sub-#{https_sub.id}")
        expect(parsed.dig("http", "routers", "sub-#{site_local_sub.id}")).to be_nil
        expect(parsed.dig("tcp", "routers", "sub-#{site_local_sub.id}")).to be_nil
      end
    end

    context "with subscriptions in non-active state" do
      let!(:pending_sub) { create(:system_federation_service_subscription, account: account) }
      let!(:suspended_sub) { create(:system_federation_service_subscription, :suspended, account: account) }
      let!(:cancelled_sub) { create(:system_federation_service_subscription, :cancelled, account: account) }

      it "excludes pending, suspended, and cancelled subscriptions" do
        result = described_class.write!(account: account, dynamic_dir: tmp_dir)
        expect(result[:route_count]).to eq(0)
      end
    end

    it "names the output file per account id" do
      result = described_class.write!(account: account, dynamic_dir: tmp_dir)
      expect(File.basename(result[:output_path])).to eq("service-subscriptions-#{account.id}.yaml")
    end

    it "creates dynamic_dir if missing" do
      missing = File.join(tmp_dir, "nested", "subdir")
      result = described_class.write!(account: account, dynamic_dir: missing)
      expect(Dir.exist?(missing)).to be true
      expect(File.exist?(result[:output_path])).to be true
    end
  end
end
