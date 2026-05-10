# frozen_string_literal: true

require "rails_helper"

# Phase O6 follow-up of the OVS+OVN dual-profile networking roadmap.
RSpec.describe Sdwan::IpfixIngestService do
  let(:account) { create(:account) }
  let(:collector) do
    ::Sdwan::IpfixCollector.create!(
      account_id: account.id, name: "primary",
      host: "10.0.0.1", port: 4739,
      sampling_rate: 1, state: "active"
    )
  end

  let(:valid_record) do
    {
      src_ip: "10.0.0.1", dst_ip: "10.0.0.2",
      src_port: 12345, dst_port: 5432,
      protocol: 6,
      octet_count: 1500, packet_count: 1,
      flow_start_at: 1.minute.ago.iso8601,
      flow_end_at: Time.current.iso8601
    }
  end

  describe ".call" do
    it "raises if account is nil" do
      expect {
        described_class.call(account: nil, ipfix_collector: collector, records: [])
      }.to raise_error(ArgumentError, /account is required/)
    end

    it "raises if collector is nil" do
      expect {
        described_class.call(account: account, ipfix_collector: nil, records: [])
      }.to raise_error(ArgumentError, /ipfix_collector is required/)
    end

    it "raises when batch exceeds MAX_BATCH_SIZE" do
      huge = Array.new(described_class::MAX_BATCH_SIZE + 1) { valid_record }
      expect {
        described_class.call(account: account, ipfix_collector: collector, records: huge)
      }.to raise_error(ArgumentError, /exceed MAX_BATCH_SIZE/)
    end

    it "ingests valid records and returns the count" do
      records = [ valid_record, valid_record.merge(src_ip: "10.0.0.3") ]

      expect {
        result = described_class.call(account: account, ipfix_collector: collector, records: records)
        expect(result.ingested_count).to eq(2)
        expect(result.rejected).to eq([])
        expect(result.batch_id).to be_present
      }.to change(::Sdwan::FlowSample, :count).by(2)
    end

    it "scopes the persisted rows to the account + collector" do
      described_class.call(account: account, ipfix_collector: collector, records: [ valid_record ])
      sample = ::Sdwan::FlowSample.last
      expect(sample.account_id).to eq(account.id)
      expect(sample.ipfix_collector_id).to eq(collector.id)
    end

    it "rejects records with missing src_ip but ingests siblings" do
      bad = valid_record.merge(src_ip: "")
      records = [ bad, valid_record ]

      result = described_class.call(account: account, ipfix_collector: collector, records: records)
      expect(result.ingested_count).to eq(1)
      expect(result.rejected.size).to eq(1)
      expect(result.rejected.first[:error]).to match(/src_ip is required/)
      expect(result.rejected.first[:index]).to eq(0)
    end

    it "rejects records with out-of-range protocol" do
      bad = valid_record.merge(protocol: 999)
      result = described_class.call(account: account, ipfix_collector: collector, records: [ bad ])
      expect(result.ingested_count).to eq(0)
      expect(result.rejected.first[:error]).to match(/protocol must be 0-255/)
    end

    it "rejects records with out-of-range src_port" do
      bad = valid_record.merge(src_port: 99_999)
      result = described_class.call(account: account, ipfix_collector: collector, records: [ bad ])
      expect(result.ingested_count).to eq(0)
      expect(result.rejected.first[:error]).to match(/src_port out of range/)
    end

    it "accepts records with no port (e.g., ICMP)" do
      icmp = valid_record.merge(protocol: 1, src_port: nil, dst_port: nil)
      result = described_class.call(account: account, ipfix_collector: collector, records: [ icmp ])
      expect(result.ingested_count).to eq(1)
      expect(::Sdwan::FlowSample.last.src_port).to be_nil
    end

    it "rejects records with unparseable flow_start_at" do
      bad = valid_record.merge(flow_start_at: "not-a-date")
      result = described_class.call(account: account, ipfix_collector: collector, records: [ bad ])
      expect(result.rejected.first[:error]).to match(/flow_start_at is required and must parse/)
    end

    it "defaults observed_at to now when not supplied" do
      records = [ valid_record ]  # no observed_at key
      described_class.call(account: account, ipfix_collector: collector, records: records)
      sample = ::Sdwan::FlowSample.last
      expect(sample.observed_at).to be_within(5.seconds).of(Time.current)
    end

    it "preserves an explicit observed_at" do
      explicit = 2.hours.ago
      records = [ valid_record.merge(observed_at: explicit.iso8601) ]
      described_class.call(account: account, ipfix_collector: collector, records: records)
      sample = ::Sdwan::FlowSample.last
      expect(sample.observed_at).to be_within(1.second).of(explicit)
    end
  end
end
