# frozen_string_literal: true

require "rails_helper"

RSpec.describe Federation::ServiceCatalogService, type: :service do
  let(:operator_account) { create(:account) }
  let(:peer) { create(:system_federation_peer, :platform, :active, account: operator_account) }

  describe ".list_active_offerings" do
    let!(:draft_offering)      { create(:system_federation_service_offering, account: operator_account, name: "Z draft") }
    let!(:active_offering)     { create(:system_federation_service_offering, :active, account: operator_account, name: "A active") }
    let!(:deprecated_offering) { create(:system_federation_service_offering, :deprecated, account: operator_account, name: "M deprecated") }
    let!(:retired_offering)    { create(:system_federation_service_offering, :retired, account: operator_account, name: "X retired") }

    it "returns active + deprecated offerings ordered by name" do
      result = described_class.list_active_offerings(account: operator_account)
      expect(result.pluck(:id)).to eq([ active_offering.id, deprecated_offering.id ])
    end

    it "excludes draft (not yet published) + retired (terminal)" do
      result = described_class.list_active_offerings(account: operator_account)
      expect(result.pluck(:id)).not_to include(draft_offering.id, retired_offering.id)
    end

    it "scopes by account (does not leak other operators' offerings)" do
      other = create(:account)
      _other_offering = create(:system_federation_service_offering, :active, account: other)
      result = described_class.list_active_offerings(account: operator_account)
      expect(result.pluck(:account_id).uniq).to eq([ operator_account.id ])
    end
  end

  describe ".issue_subscription!" do
    let!(:offering) do
      create(:system_federation_service_offering, :active,
              account: operator_account, slug: "gitea",
              default_grant_ttl_days: 30,
              default_grant_scopes: %w[read write])
    end

    context "happy path" do
      it "issues a FederationGrant scoped to the offering" do
        result = described_class.issue_subscription!(
          account: operator_account,
          offering_slug: "gitea",
          requesting_peer: peer,
          local_hostname: "git.alice.tld"
        )
        expect(result.ok?).to be true
        expect(result.grant).to be_persisted
        expect(result.grant.resource_kind).to eq("service_offering")
        expect(result.grant.resource_id).to eq(offering.id)
        expect(result.grant.permission_scopes).to match_array(%w[read write])
        expect(result.grant.federation_peer_id).to eq(peer.id)
      end

      it "returns connection details for the subscriber's Traefik" do
        result = described_class.issue_subscription!(
          account: operator_account,
          offering_slug: "gitea",
          requesting_peer: peer,
          local_hostname: "git.alice.tld"
        )
        expect(result.connection[:protocol]).to eq("https")
        expect(result.connection[:backend_port]).to eq(443)
        expect(result.connection[:grant_id]).to eq(result.grant.id)
        expect(result.connection[:expires_at]).to be_present
        expect(result.connection[:ttl_seconds]).to be > 0
      end

      it "honors the offering's default_grant_ttl_days" do
        result = described_class.issue_subscription!(
          account: operator_account, offering_slug: "gitea",
          requesting_peer: peer, local_hostname: "git.alice.tld"
        )
        # 30 days = 2,592,000 seconds, allow a few seconds of clock slop
        expect(result.connection[:ttl_seconds]).to be_within(60).of(30.days.to_i)
      end

      it "embeds the local_hostname in remote_subject so multiple subscriptions per peer can coexist" do
        result_a = described_class.issue_subscription!(
          account: operator_account, offering_slug: "gitea",
          requesting_peer: peer, local_hostname: "git.alice.tld"
        )
        result_b = described_class.issue_subscription!(
          account: operator_account, offering_slug: "gitea",
          requesting_peer: peer, local_hostname: "git-staging.alice.tld"
        )
        expect(result_a.ok?).to be true
        expect(result_b.ok?).to be true
        expect(result_a.grant.id).not_to eq(result_b.grant.id)
        expect(result_a.grant.remote_subject).to include("git.alice.tld")
        expect(result_b.grant.remote_subject).to include("git-staging.alice.tld")
      end
    end

    context "TTL clamping" do
      it "clamps a too-short TTL up to MIN_GRANT_TTL_DAYS" do
        result = described_class.issue_subscription!(
          account: operator_account, offering_slug: "gitea",
          requesting_peer: peer, local_hostname: "git.alice.tld",
          ttl_days: 1
        )
        expect(result.ok?).to be true
        # MIN is 7 days; result should reflect that
        expect(result.connection[:ttl_seconds]).to be_within(60).of(7.days.to_i)
      end

      it "honors a custom ttl_days when above the minimum" do
        result = described_class.issue_subscription!(
          account: operator_account, offering_slug: "gitea",
          requesting_peer: peer, local_hostname: "git.alice.tld",
          ttl_days: 90
        )
        expect(result.connection[:ttl_seconds]).to be_within(60).of(90.days.to_i)
      end
    end

    context "error cases" do
      it "fails when offering slug is unknown" do
        result = described_class.issue_subscription!(
          account: operator_account, offering_slug: "nonexistent",
          requesting_peer: peer, local_hostname: "git.alice.tld"
        )
        expect(result.ok?).to be false
        expect(result.error).to match(/Unknown offering/)
      end

      it "fails when offering is not active (deprecated)" do
        offering.deprecate!(reason: "replaced")
        result = described_class.issue_subscription!(
          account: operator_account, offering_slug: "gitea",
          requesting_peer: peer, local_hostname: "git.alice.tld"
        )
        expect(result.ok?).to be false
        expect(result.error).to match(/not accepting/)
      end

      it "fails when offering is at capacity" do
        offering.update!(capacity_metadata: { "max_subscribers" => 0 })
        result = described_class.issue_subscription!(
          account: operator_account, offering_slug: "gitea",
          requesting_peer: peer, local_hostname: "git.alice.tld"
        )
        expect(result.ok?).to be false
        expect(result.error).to match(/at capacity/)
      end
    end
  end
end
