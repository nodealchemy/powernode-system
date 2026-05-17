# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::PlatformDeployment, type: :model do
  describe "constants" do
    it "defines SERVICE_ROLES covering every platform component" do
      expect(described_class::SERVICE_ROLES).to match_array(
        %w[api worker frontend postgres redis reverse-proxy satellite-runtime]
      )
    end
  end

  describe "associations" do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:node_template).class_name("System::NodeTemplate") }
    it { is_expected.to belong_to(:virtual_ip).class_name("Sdwan::VirtualIp").optional }
  end

  describe "validations" do
    subject { build(:system_platform_deployment) }

    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_length_of(:name).is_at_most(100) }
    it { is_expected.to validate_inclusion_of(:service_role).in_array(described_class::SERVICE_ROLES) }
    it { is_expected.to validate_numericality_of(:target_replicas).only_integer.is_greater_than_or_equal_to(0) }

    it "enforces case-insensitive name uniqueness per account" do
      first = create(:system_platform_deployment, name: "Hub-API")
      dup = build(:system_platform_deployment, account: first.account, name: "hub-api")
      expect(dup).not_to be_valid
      expect(dup.errors[:name]).to include("has already been taken")
    end

    it "allows same name across different accounts" do
      a = create(:system_platform_deployment, name: "hub-api")
      b = build(:system_platform_deployment, name: "hub-api")
      expect(b.account).not_to eq(a.account)
      expect(b).to be_valid
    end
  end

  describe "scopes" do
    let!(:api)     { create(:system_platform_deployment, :api) }
    let!(:worker)  { create(:system_platform_deployment, :worker, account: api.account) }
    let!(:sat)     { create(:system_platform_deployment, :satellite, account: api.account) }

    it ".by_role filters by service_role" do
      expect(described_class.by_role("api")).to include(api)
      expect(described_class.by_role("api")).not_to include(worker)
    end

    it ".for_satellite filters by extension slug" do
      expect(described_class.for_satellite(sat.satellite_extension_slug)).to eq([ sat ])
    end

    it ".for_mainline excludes satellite deployments" do
      expect(described_class.for_mainline).to include(api, worker)
      expect(described_class.for_mainline).not_to include(sat)
    end
  end

  describe "#preferred_endpoint" do
    it "returns the VIP host when a virtual_ip is attached" do
      vip = build_stubbed(:sdwan_virtual_ip, cidr: "fd00:beef::42/128")
      deployment = build(:system_platform_deployment, virtual_ip: vip)
      expect(deployment.preferred_endpoint).to eq("fd00:beef::42")
    end

    it "returns the public DNS hostname when no VIP" do
      deployment = build(:system_platform_deployment, :with_dns, public_dns_hostname: "hub.example.com")
      expect(deployment.preferred_endpoint).to eq("hub.example.com")
    end

    it "returns nil when neither VIP nor DNS is set" do
      deployment = build(:system_platform_deployment)
      expect(deployment.preferred_endpoint).to be_nil
    end
  end

  describe "#dial_candidates" do
    it "returns SDWAN candidate first when VIP is attached" do
      vip = build_stubbed(:sdwan_virtual_ip, cidr: "fd00:beef::100/128")
      deployment = build(:system_platform_deployment,
                         virtual_ip: vip, public_dns_hostname: "hub.example.com")
      candidates = deployment.dial_candidates(port: 3000)
      expect(candidates.first).to eq(url: "https://fd00:beef::100:3000", scope: :sdwan)
      expect(candidates.last).to eq(url: "https://hub.example.com:3000", scope: :wan)
    end

    it "omits port segment when not supplied" do
      deployment = build(:system_platform_deployment, :with_dns, public_dns_hostname: "hub.example.com")
      candidates = deployment.dial_candidates
      expect(candidates).to eq([ { url: "https://hub.example.com", scope: :wan } ])
    end

    it "returns empty array when no endpoints configured" do
      deployment = build(:system_platform_deployment)
      expect(deployment.dial_candidates).to eq([])
    end
  end

  describe "default metadata initialization" do
    it "initializes metadata to an empty hash" do
      expect(described_class.new.metadata).to eq({})
    end
  end
end
