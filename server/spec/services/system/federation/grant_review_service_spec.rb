# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Federation::GrantReviewService, type: :service do
  let(:account) { create(:account) }
  let(:peer)    { create(:system_federation_peer, :platform, account: account) }
  let(:user)    { create(:user, account: account) }

  describe ".run!" do
    it "reviews only accounts that have federation peers" do
      _unfederated = create(:account)
      create(:system_federation_peer, account: account)

      result = described_class.run!
      expect(result.accounts_reviewed).to eq(1)
      expect(result.findings_by_account).to have_key(account.id)
    end

    it "scopes to a single account when supplied" do
      result = described_class.run!(account: account)
      expect(result.accounts_reviewed).to eq(1)
    end

    it "aggregates total findings across categories" do
      # Create one broad-scope grant + one capability drift
      create(:system_federation_grant,
             account: account, federation_peer: peer, grantor_user: user,
             permission_scopes: %w[admin])
      drift_peer = create(:system_federation_peer, :active,
                          account: account, extension_slugs: [ "trading" ])

      result = described_class.run!(account: account)
      findings = result.findings_by_account[account.id]
      expect(findings[:broad_scope_grants]).to eq(1)
      expect(findings[:capability_drift]).to eq(1)
      expect(findings[:total]).to be >= 2
    end

    it "returns 0 findings for a clean account" do
      # peer exists but no concerning state
      peer  # eager-create
      result = described_class.run!(account: account)
      expect(result.findings_by_account[account.id][:total]).to eq(0)
      expect(result.total_findings).to eq(0)
    end

    it "records ran_at on the result" do
      result = described_class.run!(account: account)
      expect(result.ran_at).to be_within(2.seconds).of(Time.current)
    end
  end
end
