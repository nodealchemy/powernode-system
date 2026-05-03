# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::PhysicalEnrollmentService, type: :service do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:node)     { create(:system_node, account: account) }
  let(:instance) do
    create(:system_node_instance, node: node, variety: "physical", status: "pending")
  end

  describe ".record_discovery!" do
    it "creates a fresh UnclaimedDevice on first poll" do
      result = nil
      expect {
        result = described_class.record_discovery!(
          account: account,
          mac: "aa:bb:cc:dd:ee:01",
          dmi_uuid: "uuid-1",
          hostname: "rpi-test",
          architecture: "arm64",
          platform_hint: "rpi4"
        )
      }.to change { System::UnclaimedDevice.count }.by(1)
      expect(result.created).to be true
      expect(result.unclaimed.discovered_mac).to eq("aa:bb:cc:dd:ee:01")
      expect(result.unclaimed.claim_code.length).to eq(System::UnclaimedDevice::CLAIM_CODE_LENGTH)
    end

    it "upserts existing row on subsequent polls (no new claim_code)" do
      first = described_class.record_discovery!(account: account, mac: "aa:bb:cc:dd:ee:02")
      original_code = first.unclaimed.claim_code
      original_first_seen = first.unclaimed.first_seen_at

      expect {
        sleep 0.05
        second = described_class.record_discovery!(account: account, mac: "aa:bb:cc:dd:ee:02")
        expect(second.created).to be false
        expect(second.unclaimed.id).to eq(first.unclaimed.id)
        expect(second.unclaimed.claim_code).to eq(original_code) # preserved
        expect(second.unclaimed.first_seen_at).to eq(original_first_seen)
        expect(second.unclaimed.last_seen_at).to be > first.unclaimed.last_seen_at
      }.not_to change { System::UnclaimedDevice.count }
    end

    it "raises when mac is blank" do
      expect {
        described_class.record_discovery!(account: account, mac: "")
      }.to raise_error(ArgumentError, /mac is required/)
    end
  end

  describe ".confirm_claim!" do
    let(:unclaimed) do
      described_class.record_discovery!(
        account: account, mac: "aa:bb:cc:dd:ee:03", hostname: "rpi-claim-test"
      ).unclaimed
    end

    it "binds device to instance + updates both records" do
      result = described_class.confirm_claim!(unclaimed: unclaimed, node_instance: instance)
      expect(result.ok?).to be true

      unclaimed.reload
      instance.reload
      expect(unclaimed.claimed_at).to be_within(2.seconds).of(Time.current)
      expect(unclaimed.claimed_node_instance_id).to eq(instance.id)
      expect(instance.claim_code).to eq(unclaimed.claim_code)
      expect(instance.discovered_mac).to eq("aa:bb:cc:dd:ee:03")
      expect(instance.discovered_hostname).to eq("rpi-claim-test")
      expect(instance.claimed?).to be true
    end

    it "rejects double-claim" do
      described_class.confirm_claim!(unclaimed: unclaimed, node_instance: instance)
      result = described_class.confirm_claim!(unclaimed: unclaimed.reload, node_instance: instance)
      expect(result.ok?).to be false
      expect(result.error).to include("already claimed")
    end

    it "rejects when unclaimed missing" do
      result = described_class.confirm_claim!(unclaimed: nil, node_instance: instance)
      expect(result.ok?).to be false
    end

    it "rejects when node_instance missing" do
      result = described_class.confirm_claim!(unclaimed: unclaimed, node_instance: nil)
      expect(result.ok?).to be false
    end
  end

  describe ".poll_status" do
    let(:unclaimed) do
      described_class.record_discovery!(account: account, mac: "aa:bb:cc:dd:ee:04").unclaimed
    end

    it "returns pending with claim_code when not yet claimed" do
      poll = described_class.poll_status(unclaimed)
      expect(poll.status).to eq("pending")
      expect(poll.claim_code).to eq(unclaimed.claim_code)
      expect(poll.bootstrap_token).to be_nil
    end

    it "returns claimed with bootstrap_token after operator confirms" do
      described_class.confirm_claim!(unclaimed: unclaimed, node_instance: instance)
      poll = described_class.poll_status(unclaimed.reload)
      expect(poll.status).to eq("claimed")
      expect(poll.bootstrap_token).to be_present
      expect(poll.bootstrap_token.length).to be > 30 # base64-encoded 32 bytes
      expect(poll.instance_uuid).to eq(instance.id)
    end

    it "issues a fresh bootstrap_token each time (single-use semantics enforced at /enroll)" do
      described_class.confirm_claim!(unclaimed: unclaimed, node_instance: instance)
      poll1 = described_class.poll_status(unclaimed.reload)
      poll2 = described_class.poll_status(unclaimed.reload)
      # Each poll mints a new token; only one will succeed at /enroll due
      # to single-use enforcement on the BootstrapToken model.
      expect(poll1.bootstrap_token).not_to eq(poll2.bootstrap_token)
    end

    it "returns expired when expires_at past" do
      unclaimed.update!(expires_at: 1.minute.ago)
      poll = described_class.poll_status(unclaimed)
      expect(poll.status).to eq("expired")
    end
  end
end
