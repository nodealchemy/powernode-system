# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Federation::ServiceOffering, type: :model do
  let(:account) { create(:account) }

  describe "validations" do
    it "requires slug, name, and a backing service" do
      offering = described_class.new(account: account)
      expect(offering).not_to be_valid
      expect(offering.errors[:slug]).to be_present
      expect(offering.errors[:name]).to be_present
      expect(offering.errors[:service]).to be_present
    end

    it "rejects slug containing uppercase or whitespace" do
      [ "Bad Slug", "BadSlug", "bad slug" ].each do |bad|
        offering = build(:system_federation_service_offering, account: account, slug: bad)
        expect(offering).not_to be_valid, "expected #{bad.inspect} to fail validation"
      end
    end

    it "accepts well-formed slugs" do
      [ "gitea", "managed-postgres", "service-1" ].each do |good|
        offering = build(:system_federation_service_offering, account: account, slug: good)
        expect(offering).to be_valid, "expected #{good.inspect} to validate"
      end
    end

    # protocol / backend_port / backend-address validity now live on
    # Sdwan::Service (see sdwan/service_spec) — the offering only references it.

    it "enforces unique slug within account" do
      create(:system_federation_service_offering, account: account, slug: "primary")
      dup = build(:system_federation_service_offering, account: account, slug: "primary")
      expect(dup).not_to be_valid
    end

    it "allows the same slug across different accounts" do
      other_account = create(:account)
      create(:system_federation_service_offering, account: account, slug: "primary")
      other = build(:system_federation_service_offering, account: other_account, slug: "primary")
      expect(other).to be_valid
    end

    it "rejects default_grant_ttl_days below MIN_GRANT_TTL_DAYS" do
      offering = build(:system_federation_service_offering, account: account, default_grant_ttl_days: 3)
      expect(offering).not_to be_valid
    end

    it "rejects unknown scope names in default_grant_scopes" do
      offering = build(:system_federation_service_offering, account: account,
                                                             default_grant_scopes: %w[read sudo])
      expect(offering).not_to be_valid
      expect(offering.errors[:default_grant_scopes]).to be_present
    end
  end

  describe "state machine" do
    let(:offering) { create(:system_federation_service_offering, account: account) }

    it "permits draft → active" do
      expect(offering.activate!).to be true
      expect(offering.reload.status).to eq("active")
    end

    it "permits active → deprecated, recording reason" do
      offering.activate!
      offering.deprecate!(reason: "replaced by Service v2")
      expect(offering.reload.status).to eq("deprecated")
      expect(offering.deprecated_at).to be_present
      expect(offering.metadata["deprecation_reason"]).to include("v2")
    end

    it "permits deprecated → active (un-deprecate)" do
      offering.update!(status: "deprecated", deprecated_at: 1.day.ago)
      offering.activate!
      expect(offering.reload.status).to eq("active")
      expect(offering.deprecated_at).to be_nil
    end

    it "permits any non-terminal → retired" do
      offering.retire!(reason: "decommissioned")
      expect(offering.reload.status).to eq("retired")
      expect(offering.retired_at).to be_present
      expect(offering.terminal?).to be true
    end

    it "refuses transitions from retired (terminal)" do
      offering.update!(status: "retired")
      expect(offering.activate!).to be false
      expect(offering.deprecate!).to be false
    end
  end

  describe "#accepting_subscriptions?" do
    it "is true for active without capacity cap" do
      offering = create(:system_federation_service_offering, :active, account: account)
      expect(offering.accepting_subscriptions?).to be true
    end

    it "is false for deprecated" do
      offering = create(:system_federation_service_offering, :deprecated, account: account)
      expect(offering.accepting_subscriptions?).to be false
    end

    it "is false when at_capacity? returns true" do
      offering = create(:system_federation_service_offering, :active, :capped, account: account)
      allow(offering).to receive(:at_capacity?).and_return(true)
      expect(offering.accepting_subscriptions?).to be false
    end
  end

  describe "scopes" do
    let!(:draft)      { create(:system_federation_service_offering, account: account) }
    let!(:active)     { create(:system_federation_service_offering, :active, account: account) }
    let!(:deprecated) { create(:system_federation_service_offering, :deprecated, account: account) }
    let!(:retired)    { create(:system_federation_service_offering, :retired, account: account) }

    it ".active_offerings returns only active" do
      expect(described_class.active_offerings.pluck(:id)).to eq([ active.id ])
    end

    it ".catalog_listed returns active + deprecated" do
      expect(described_class.catalog_listed.pluck(:id)).to match_array([ active.id, deprecated.id ])
    end

    it ".terminal returns only retired" do
      expect(described_class.terminal.pluck(:id)).to eq([ retired.id ])
    end
  end

  # Phase 2 (Step C): the offering is a federated facet of a required Sdwan::Service;
  # backend reads delegate to it.
  describe "backend delegation to #service" do
    let(:service) do
      ::Sdwan::Service.create!(account: account, slug: "svc-backend", name: "Svc Backend",
                               protocol: "http", backend_host: "10.9.9.9", backend_port: 9090)
    end

    it "requires a backing service" do
      offering = build(:system_federation_service_offering, account: account, service: nil)
      expect(offering).not_to be_valid
      expect(offering.errors[:service]).to be_present
    end

    it "delegates backend reads to the service" do
      offering = create(:system_federation_service_offering, account: account, service: service)
      expect(offering.protocol).to eq("http")
      expect(offering.backend_host).to eq("10.9.9.9")
      expect(offering.backend_port).to eq(9090)
      expect(offering.backend_vip_id).to be_nil
    end

    it ".by_protocol filters through the joined service" do
      https_svc = ::Sdwan::Service.create!(account: account, slug: "svc-https", name: "H",
                                           protocol: "https", backend_host: "h", backend_port: 443)
      http_off  = create(:system_federation_service_offering, account: account, service: service)
      _https_off = create(:system_federation_service_offering, account: account, service: https_svc)
      expect(described_class.by_protocol("http").pluck(:id)).to eq([ http_off.id ])
    end
  end
end
