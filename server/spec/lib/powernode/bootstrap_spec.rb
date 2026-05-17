# frozen_string_literal: true

require "rails_helper"

RSpec.describe Powernode::Bootstrap, type: :lib do
  let(:account) { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }

  before { described_class.invalidate! }

  describe ".discover_peer" do
    it "returns the PlatformDeployment matching role + account" do
      deployment = create(:system_platform_deployment, :api,
                          account: account, node_template: template)
      result = described_class.discover_peer(:api, account: account)
      expect(result).to eq(deployment)
    end

    it "returns nil when no deployment matches" do
      result = described_class.discover_peer(:api, account: account)
      expect(result).to be_nil
    end

    it "ignores satellite deployments when looking up mainline roles" do
      create(:system_platform_deployment, :satellite,
             account: account, node_template: template,
             service_role: "satellite-runtime", satellite_extension_slug: "trading")
      mainline_api = create(:system_platform_deployment, :api,
                            account: account, node_template: template)
      result = described_class.discover_peer(:api, account: account)
      expect(result).to eq(mainline_api)
    end

    it "scopes lookup by account" do
      other_account = create(:account)
      other_platform = create(:system_node_platform, account: other_account)
      other_template = create(:system_node_template, account: other_account, node_platform: other_platform)
      create(:system_platform_deployment, :api,
             account: other_account, node_template: other_template)
      result = described_class.discover_peer(:api, account: account)
      expect(result).to be_nil
    end

    it "prefers the deployment with higher target_replicas" do
      _small = create(:system_platform_deployment, :api,
                      account: account, node_template: template, target_replicas: 1)
      large = create(:system_platform_deployment, :api,
                     account: account, node_template: template,
                     name: "hub-api-large", target_replicas: 5)
      expect(described_class.discover_peer(:api, account: account)).to eq(large)
    end
  end

  describe "caching" do
    it "caches the lookup within the TTL window" do
      deployment = create(:system_platform_deployment, :api,
                          account: account, node_template: template)
      first = described_class.discover_peer(:api, account: account)
      expect(first).to eq(deployment)

      # Mutate the DB directly — cached value should still be returned
      deployment.update!(target_replicas: 99)
      cached = described_class.discover_peer(:api, account: account)
      expect(cached.target_replicas).to eq(1)  # stale
    end

    it "respects refresh: true to bypass the cache" do
      deployment = create(:system_platform_deployment, :api,
                          account: account, node_template: template)
      described_class.discover_peer(:api, account: account)
      deployment.update!(target_replicas: 99)
      fresh = described_class.discover_peer(:api, account: account, refresh: true)
      expect(fresh.target_replicas).to eq(99)
    end

    it "invalidate! clears the cache" do
      deployment = create(:system_platform_deployment, :api,
                          account: account, node_template: template)
      described_class.discover_peer(:api, account: account)
      deployment.update!(target_replicas: 77)
      described_class.invalidate!
      after = described_class.discover_peer(:api, account: account)
      expect(after.target_replicas).to eq(77)
    end

    it "invalidate(role, account:) clears just one slot" do
      api = create(:system_platform_deployment, :api,
                   account: account, node_template: template)
      worker = create(:system_platform_deployment, :worker,
                      account: account, node_template: template)

      # Prime both
      described_class.discover_peer(:api, account: account)
      described_class.discover_peer(:worker, account: account)

      api.update!(target_replicas: 3)
      worker.update!(target_replicas: 5)
      described_class.invalidate(:api, account: account)

      # api refreshed; worker still cached
      expect(described_class.discover_peer(:api, account: account).target_replicas).to eq(3)
      expect(described_class.discover_peer(:worker, account: account).target_replicas).to eq(1)
    end
  end

  describe ".endpoint_for" do
    it "returns the VIP-prefixed URL when a VIP is attached" do
      vip_account_network = create(:sdwan_network, account: account)
      vip = create(:sdwan_virtual_ip, network: vip_account_network, cidr: "fd00:c0de::1/128")
      create(:system_platform_deployment, :api,
             account: account, node_template: template, virtual_ip: vip)
      url = described_class.endpoint_for(:api, port: 3000, account: account)
      expect(url).to eq("https://fd00:c0de::1:3000")
    end

    it "falls back to public_dns_hostname when no VIP" do
      create(:system_platform_deployment, :api, :with_dns,
             account: account, node_template: template,
             public_dns_hostname: "hub.example.com")
      url = described_class.endpoint_for(:api, port: 443, account: account)
      expect(url).to eq("https://hub.example.com:443")
    end

    it "returns nil when no deployment is registered" do
      expect(described_class.endpoint_for(:api, account: account)).to be_nil
    end
  end

  describe ".dial_candidates" do
    it "returns all priority-ordered candidates when both VIP + DNS are set" do
      vip_network = create(:sdwan_network, account: account)
      vip = create(:sdwan_virtual_ip, network: vip_network, cidr: "fd00:c0de::42/128")
      create(:system_platform_deployment, :api, :with_dns,
             account: account, node_template: template,
             virtual_ip: vip, public_dns_hostname: "hub.example.com")
      candidates = described_class.dial_candidates(:api, port: 3000, account: account)
      expect(candidates).to eq([
        { url: "https://fd00:c0de::42:3000", scope: :sdwan },
        { url: "https://hub.example.com:3000", scope: :wan }
      ])
    end

    it "returns empty array when no deployment found" do
      expect(described_class.dial_candidates(:api, account: account)).to eq([])
    end
  end
end
