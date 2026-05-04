# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::Bgp::AsNumberAllocator, type: :service do
  let(:account) { Account.first || create(:account) }

  before { Sdwan::AccountBgp.where(account_id: account.id).destroy_all }

  it "allocates an AS within the RFC 6996 4-byte private range" do
    row = described_class.allocate!(account: account)
    expect(row.as_number).to be_between(
      Sdwan::AccountBgp::PRIVATE_AS_MIN,
      Sdwan::AccountBgp::PRIVATE_AS_MAX
    )
  end

  it "is deterministic for the same account on the first attempt (stable across DR)" do
    row1 = described_class.allocate!(account: account)
    row1_as = row1.as_number
    Sdwan::AccountBgp.where(account_id: account.id).destroy_all

    row2 = described_class.allocate!(account: account)
    expect(row2.as_number).to eq(row1_as)
  end

  it "rejects collisions and finds another candidate" do
    # Force the deterministic candidate to be 'taken' by a different account
    other_account = Account.where.not(id: account.id).first || create(:account)
    Sdwan::AccountBgp.where(account_id: other_account.id).destroy_all

    forced = described_class.allocate!(account: account)
    forced_as = forced.as_number
    Sdwan::AccountBgp.where(account_id: account.id).destroy_all

    Sdwan::AccountBgp.create!(
      account_id: other_account.id,
      as_number: forced_as,
      router_id_strategy: "peer_overlay_ipv6_hash",
      enabled: true
    )

    row = described_class.allocate!(account: account)
    expect(row.as_number).not_to eq(forced_as)
    expect(row.as_number).to be_between(
      Sdwan::AccountBgp::PRIVATE_AS_MIN,
      Sdwan::AccountBgp::PRIVATE_AS_MAX
    )
  end
end
