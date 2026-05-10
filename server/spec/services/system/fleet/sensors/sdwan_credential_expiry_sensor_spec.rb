# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Fleet::Sensors::SdwanCredentialExpirySensor do
  let(:account) { Account.first || create(:account) }
  let(:sensor) { described_class.new(account: account) }

  before do
    Sdwan::MembershipCredential.where(account_id: account.id).delete_all
    Sdwan::ConstellationSigningKey.where(account_id: account.id).delete_all
    Sdwan::Peer.where(account_id: account.id).delete_all
    Sdwan::Network.where(account_id: account.id).delete_all
    Sdwan::Configuration.where(account_id: account.id).delete_all
  end

  let!(:network) { Sdwan::Network.create!(account_id: account.id, name: "exp-net-#{SecureRandom.hex(3)}") }
  let!(:node)    { sdwan_test_node(account: account) }
  let!(:inst)    { sdwan_test_node_instance(node: node) }
  let!(:peer) do
    Sdwan::Peer.create!(account: account, sdwan_network_id: network.id, node_instance: inst,
                        publicly_reachable: true, endpoint_host_v6: "2001:db8::1", endpoint_port: 51820)
  end

  # A small helper to insert MC rows directly. Bypasses signer (which
  # we exercise in its own spec) so this spec can manipulate window
  # boundaries cleanly. `not_before` defaults to an hour ago so that
  # tests using ago-style refresh_after values still pass the
  # `refresh_after >= not_before` validation.
  def make_mc(status:, not_after:, refresh_after:, not_before: 1.hour.ago, revision: 1)
    Sdwan::MembershipCredential.create!(
      account: account,
      peer: peer,
      network: network,
      status: status,
      revision: revision,
      issued_at: not_before,
      not_before: not_before,
      not_after: not_after,
      refresh_after: refresh_after,
      envelope_json: '{"rev":1}',
      signature_b64: "AAAA",
      constellation_handle: "acct-test"
    )
  end

  describe "#sense" do
    it "returns no signals for an active MC well outside the advisory window" do
      make_mc(status: "active", not_after: 2.hours.from_now, refresh_after: 1.hour.from_now)
      expect(sensor.sense).to be_empty
    end

    it "emits a medium-severity expiring signal inside the 15-minute window" do
      mc = make_mc(status: "active", not_after: 10.minutes.from_now, refresh_after: 5.minutes.from_now)
      signals = sensor.sense
      sig = signals.find { |s| s.kind == "system.sdwan_credential_expiring" }
      expect(sig).not_to be_nil
      expect(sig.severity).to eq(:medium)
      expect(sig.payload["membership_credential_id"]).to eq(mc.id)
      expect(sig.payload["remediation_action"]).to eq("system.sdwan_credential_refresh")
    end

    it "escalates to high severity inside the 5-minute window" do
      make_mc(status: "active", not_after: 3.minutes.from_now, refresh_after: 1.minute.ago)
      sig = sensor.sense.find { |s| s.kind == "system.sdwan_credential_expiring" }
      expect(sig.severity).to eq(:high)
    end

    it "uses a stable fingerprint per MC id" do
      mc = make_mc(status: "active", not_after: 10.minutes.from_now, refresh_after: 5.minutes.from_now)
      sig = sensor.sense.find { |s| s.kind == "system.sdwan_credential_expiring" }
      expect(sig.fingerprint).to eq("sdwan_credential_expiring:#{mc.id}")
    end

    it "ignores revoked rows" do
      make_mc(status: "revoked", not_after: 10.minutes.from_now, refresh_after: 5.minutes.from_now)
      Sdwan::MembershipCredential.where(account_id: account.id).update_all(
        revoked_at: Time.current, revocation_reason: "test"
      )
      expect(sensor.sense).to be_empty
    end

    it "scopes to the current account" do
      other_account = create(:account)
      other_net = Sdwan::Network.create!(account_id: other_account.id, name: "other")
      other_node = sdwan_test_node(account: other_account)
      other_inst = sdwan_test_node_instance(node: other_node)
      other_peer = Sdwan::Peer.create!(account: other_account, sdwan_network_id: other_net.id,
                                       node_instance: other_inst, publicly_reachable: true,
                                       endpoint_host_v6: "2001:db8::99", endpoint_port: 51820)
      Sdwan::MembershipCredential.create!(
        account: other_account, peer: other_peer, network: other_net,
        status: "active", revision: 1,
        issued_at: 1.minute.ago, not_before: 1.minute.ago,
        not_after: 5.minutes.from_now, refresh_after: 1.minute.ago,
        envelope_json: '{}', signature_b64: "AAAA",
        constellation_handle: "acct-other"
      )

      expect(sensor.sense).to be_empty
    end

    it "emits a refresh_stalled signal when an expiring MC has no superseding revision" do
      make_mc(status: "expiring", revision: 1,
              not_after: 10.minutes.from_now, refresh_after: 1.minute.ago)
      sig = sensor.sense.find { |s| s.kind == "system.sdwan_credential_refresh_stalled" }
      expect(sig).not_to be_nil
      expect(sig.severity).to eq(:high)
      expect(sig.payload["seconds_overdue"]).to be >= 0
    end

    it "does NOT emit refresh_stalled when a newer revision exists for the same (peer, network)" do
      make_mc(status: "expiring", revision: 1,
              not_after: 10.minutes.from_now, refresh_after: 1.minute.ago)
      make_mc(status: "active", revision: 2,
              not_after: 1.hour.from_now, refresh_after: 30.minutes.from_now)

      stalled = sensor.sense.select { |s| s.kind == "system.sdwan_credential_refresh_stalled" }
      expect(stalled).to be_empty
    end

    it "returns an empty array (not nil) when nothing matches" do
      expect(sensor.sense).to eq([])
    end
  end
end
