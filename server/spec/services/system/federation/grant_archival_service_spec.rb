# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Federation::GrantArchivalService, type: :service do
  let(:account) { create(:account) }
  let(:peer)    { create(:system_federation_peer, :platform, account: account) }
  let(:user)    { create(:user, account: account) }

  describe ".run!" do
    it "archives revoked grants past the 90-day retention window" do
      old_revoked = create(:system_federation_grant,
                            account: account, federation_peer: peer, grantor_user: user,
                            revoked_at: 100.days.ago, revocation_reason: "old")
      result = described_class.run!(account: account)
      expect(result.archived).to eq(1)
      expect(result.archived_ids).to include(old_revoked.id)
      expect(old_revoked.reload.archived_at).to be_within(2.seconds).of(Time.current)
    end

    it "does not touch recently-revoked grants" do
      recent = create(:system_federation_grant, :revoked,
                       account: account, federation_peer: peer, grantor_user: user)
      result = described_class.run!(account: account)
      expect(result.archived).to eq(0)
      expect(recent.reload.archived_at).to be_nil
    end

    it "does not touch active or expired-but-not-revoked grants" do
      create(:system_federation_grant,
             account: account, federation_peer: peer, grantor_user: user)
      create(:system_federation_grant, :expired,
             account: account, federation_peer: peer, grantor_user: user)
      result = described_class.run!(account: account)
      expect(result.archived).to eq(0)
    end

    it "is idempotent (already-archived grants stay archived without reprocessing)" do
      old_revoked = create(:system_federation_grant,
                            account: account, federation_peer: peer, grantor_user: user,
                            revoked_at: 100.days.ago, revocation_reason: "old")
      described_class.run!(account: account)
      result2 = described_class.run!(account: account)
      expect(result2.archived).to eq(0)
      expect(old_revoked.reload.archived?).to be true
    end

    it "sweeps all accounts when account is nil" do
      other_account = create(:account)
      other_peer = create(:system_federation_peer, :platform, account: other_account)
      other_user = create(:user, account: other_account)

      create(:system_federation_grant,
             account: account, federation_peer: peer, grantor_user: user,
             revoked_at: 100.days.ago, revocation_reason: "x")
      create(:system_federation_grant,
             account: other_account, federation_peer: other_peer, grantor_user: other_user,
             revoked_at: 95.days.ago, revocation_reason: "y")

      result = described_class.run!
      expect(result.archived).to eq(2)
      expect(result.scope).to eq("all_accounts")
    end
  end
end
