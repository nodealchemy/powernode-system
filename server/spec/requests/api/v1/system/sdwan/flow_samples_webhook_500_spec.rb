# frozen_string_literal: true

require "rails_helper"

# webhook-500 regression for the high-volume IPFIX ingest endpoint. Inbound
# sidecar (vector/fluent-bit) batches must NEVER 500 on a malformed record: a
# 500 makes the collector retry the whole batch forever and the poison record
# never drains. A bad IP must not poison the insert_all batch, and a non-object
# array element must not raise NoMethodError.
RSpec.describe "Api::V1::System::Sdwan::FlowSamples ingest hardening", type: :request do
  let(:writer)  { user_with_permissions("system.sdwan.ipfix.ingest") }
  let(:account) { writer.account }
  let(:headers) { auth_headers_for(writer).merge("Content-Type" => "application/json") }
  let(:collector) do
    ::Sdwan::IpfixCollector.create!(account_id: account.id, name: "c", host: "10.0.0.1",
                                    port: 4739, sampling_rate: 1, state: "active")
  end

  def valid_sample
    {
      src_ip: "10.0.0.10", dst_ip: "10.0.0.20", src_port: 1234, dst_port: 5432,
      protocol: 6, octet_count: 1500, packet_count: 1,
      flow_start_at: 1.minute.ago.iso8601, flow_end_at: Time.current.iso8601
    }
  end

  def ingest(samples)
    post "/api/v1/system/sdwan/ipfix_collectors/#{collector.id}/flow_samples",
         params: { flow_samples: samples }.to_json, headers: headers
  end

  it "rejects a malformed-IP record instead of poisoning the whole insert_all batch (no 500)" do
    ingest([ valid_sample, valid_sample.merge(src_ip: "not-an-ip") ])

    expect(response).to have_http_status(:ok)
    body = json_response_data
    expect(body["ingested_count"]).to eq(1)
    expect(body["rejected_count"]).to eq(1)
    expect(body["rejected"].first["error"]).to match(/src_ip/i)
    expect(Sdwan::FlowSample.where(ipfix_collector_id: collector.id).count).to eq(1)
  end

  it "rejects a non-object array element instead of raising NoMethodError (no 500)" do
    ingest([ "i-am-not-an-object", valid_sample ])

    expect(response).to have_http_status(:ok)
    body = json_response_data
    expect(body["ingested_count"]).to eq(1)
    expect(body["rejected_count"]).to eq(1)
  end
end
