# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::FederationGrant, type: :model do
  describe "constants" do
    it "defines SCOPES + TTL constants" do
      expect(described_class::SCOPES).to eq(%w[read write admin migrate])
      expect(described_class::DEFAULT_TTL).to eq(30.days)
      expect(described_class::MIN_TTL).to eq(7.days)
      expect(described_class::REVOKED_RETENTION).to eq(90.days)
    end
  end

  describe "associations" do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:federation_peer).class_name("System::FederationPeer") }
    # Optional — system-issued grants (e.g. Federation::ServiceCatalogService)
    # have no specific user grantor.
    it { is_expected.to belong_to(:grantor_user).class_name("User").optional }
  end

  describe "validations" do
    subject { build(:system_federation_grant) }

    it { is_expected.to validate_presence_of(:remote_subject) }
    it { is_expected.to validate_presence_of(:resource_kind) }

    it "fills in expires_at on create when blank (default TTL)" do
      # The before_validation callback provides a default, so empty
      # expires_at is auto-filled rather than rejected. Test the
      # callback rather than presence_of (which would set it to nil
      # and observe it pop back).
      account = create(:account)
      peer = create(:system_federation_peer, :platform, account: account)
      grant = described_class.new(
        account: account, federation_peer: peer,
        grantor_user: create(:user, account: account),
        remote_subject: "alice@b", resource_kind: "skill",
        permission_scopes: [ "read" ], expires_at: nil
      )
      expect(grant.save).to be true
      expect(grant.expires_at).to be_present
    end

    it "rejects expires_at before issued_at" do
      grant = build(:system_federation_grant,
                    issued_at: Time.current,
                    expires_at: 1.minute.ago)
      expect(grant).not_to be_valid
      expect(grant.errors[:expires_at]).to include(/must be after issued_at/)
    end

    it "rejects TTL below minimum (7 days)" do
      grant = build(:system_federation_grant,
                    issued_at: Time.current,
                    expires_at: 3.days.from_now)
      expect(grant).not_to be_valid
      expect(grant.errors[:expires_at]).to include(/at least/)
    end

    it "rejects invalid scopes" do
      grant = build(:system_federation_grant, permission_scopes: [ "bogus" ])
      expect(grant).not_to be_valid
      expect(grant.errors[:permission_scopes]).to be_present
    end

    it "accepts all four standard scopes" do
      grant = build(:system_federation_grant, permission_scopes: %w[read write admin migrate])
      expect(grant).to be_valid
    end
  end

  describe "default-timestamps on create" do
    it "fills issued_at and expires_at when blank" do
      account = create(:account)
      grant = described_class.new(
        account: account,
        federation_peer: create(:system_federation_peer, :platform, account: account),
        grantor_user: create(:user, account: account),
        remote_subject: "alice@b",
        resource_kind: "skill",
        permission_scopes: [ "read" ]
      )
      expect(grant.save).to be true
      expect(grant.issued_at).to be_within(2.seconds).of(Time.current)
      expect(grant.expires_at).to be_within(2.seconds).of(Time.current + 30.days)
    end
  end

  describe "state predicates" do
    it "#active? for an unexpired non-revoked non-archived grant" do
      grant = create(:system_federation_grant)
      expect(grant.active?).to be true
    end

    it "#expired? when past expires_at" do
      grant = create(:system_federation_grant, :expired)
      expect(grant.expired?).to be true
      expect(grant.active?).to be false
    end

    it "#revoked? after revoke!" do
      grant = create(:system_federation_grant)
      grant.revoke!(reason: "testing")
      expect(grant.revoked?).to be true
      expect(grant.active?).to be false
    end

    it "#archived? after archive!" do
      grant = create(:system_federation_grant, :revoked)
      grant.archive!
      expect(grant.archived?).to be true
    end

    it "#has_scope? returns true when scope is in permission_scopes" do
      grant = create(:system_federation_grant, permission_scopes: %w[read migrate])
      expect(grant.has_scope?(:read)).to be true
      expect(grant.has_scope?("migrate")).to be true
      expect(grant.has_scope?(:write)).to be false
    end
  end

  describe "scopes" do
    let!(:active_grant)   { create(:system_federation_grant) }
    let!(:expired_grant)  { create(:system_federation_grant, :expired) }
    let!(:revoked_grant)  { create(:system_federation_grant, :revoked) }
    let!(:archived_grant) { create(:system_federation_grant, :archived) }

    it ".active returns only non-revoked + non-archived + unexpired" do
      expect(described_class.active).to include(active_grant)
      expect(described_class.active).not_to include(expired_grant, revoked_grant, archived_grant)
    end

    it ".expired returns past-expiry grants (excluding archived)" do
      expect(described_class.expired).to include(expired_grant)
      expect(described_class.expired).not_to include(active_grant, archived_grant)
    end

    it ".revoked returns revoked-not-archived grants" do
      expect(described_class.revoked).to include(revoked_grant)
      expect(described_class.revoked).not_to include(active_grant, archived_grant)
    end

    it ".ready_for_archival returns revoked grants past the retention window" do
      old_revoke = create(:system_federation_grant, revoked_at: 100.days.ago,
                                                    revocation_reason: "old")
      expect(described_class.ready_for_archival).to include(old_revoke)
      expect(described_class.ready_for_archival).not_to include(revoked_grant)  # only 1 day old
    end
  end

  describe "#bearer_token + .find_by_bearer_token" do
    it "round-trips fg-<id>" do
      grant = create(:system_federation_grant)
      expect(grant.bearer_token).to eq("fg-#{grant.id}")
      expect(described_class.find_by_bearer_token(grant.bearer_token)).to eq(grant)
    end

    it "returns nil for malformed tokens" do
      expect(described_class.find_by_bearer_token("bogus")).to be_nil
      expect(described_class.find_by_bearer_token(nil)).to be_nil
    end
  end

  describe "unique constraints" do
    it "permits a kind-wide AND a specific-resource grant for the same peer+subject+kind" do
      peer = create(:system_federation_peer, :platform)
      account = peer.account
      user = create(:user, account: account)

      kind_wide = create(:system_federation_grant,
                          account: account, federation_peer: peer,
                          grantor_user: user,
                          remote_subject: "bob@b",
                          resource_kind: "skill",
                          resource_id: nil)
      specific = build(:system_federation_grant,
                       account: account, federation_peer: peer,
                       grantor_user: user,
                       remote_subject: "bob@b",
                       resource_kind: "skill",
                       resource_id: SecureRandom.uuid)
      expect(specific.save).to be true
      expect(kind_wide.reload).to be_present
    end

    it "rejects duplicate kind-wide grant" do
      first = create(:system_federation_grant,
                     remote_subject: "bob@b",
                     resource_kind: "skill",
                     resource_id: nil)
      dup = build(:system_federation_grant,
                  account: first.account, federation_peer: first.federation_peer,
                  grantor_user: first.grantor_user,
                  remote_subject: "bob@b",
                  resource_kind: "skill",
                  resource_id: nil)
      expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
