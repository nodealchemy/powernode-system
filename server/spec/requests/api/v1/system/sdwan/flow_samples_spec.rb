# frozen_string_literal: true

require "rails_helper"

# Phase O6 follow-up of the OVS+OVN dual-profile networking roadmap.
RSpec.describe "Api::V1::System::Sdwan::FlowSamples", type: :request do
  let(:reader)  { user_with_permissions("sdwan.ipfix.read") }
  let(:writer)  { user_with_permissions("sdwan.ipfix.ingest") }
  let(:account) { reader.account }

  let(:read_headers)   { auth_headers_for(reader) }
  let(:ingest_headers) { auth_headers_for(::User.create!(account: account, email: "ingest@x.test", password: "Aaa12345!", roles: writer.roles)) }

  let(:collector) do
    ::Sdwan::IpfixCollector.create!(
      account_id: account.id, name: "primary",
      host: "10.0.0.1", port: 4739,
      sampling_rate: 1, state: "active"
    )
  end

  let(:valid_payload) do
    {
      flow_samples: [
        {
          src_ip: "10.0.0.10", dst_ip: "10.0.0.20",
          src_port: 12345, dst_port: 5432,
          protocol: 6,
          octet_count: 1500, packet_count: 1,
          flow_start_at: 1.minute.ago.iso8601,
          flow_end_at: Time.current.iso8601
        }
      ]
    }
  end

  before do
    Sdwan::FlowSample.where(account_id: account.id).delete_all
  end

  describe "POST /api/v1/system/sdwan/ipfix_collectors/:id/flow_samples" do
    it "ingests a batch and returns the count" do
      # Reader needs the writer permission too — model the dual-permission
      # setup by giving the reader the ingest permission inline.
      writer_user = user_with_permissions("sdwan.ipfix.ingest")
      collector_for_writer = ::Sdwan::IpfixCollector.create!(
        account_id: writer_user.account.id, name: "writer-c",
        host: "10.0.0.1", port: 4739, sampling_rate: 1, state: "active"
      )

      post "/api/v1/system/sdwan/ipfix_collectors/#{collector_for_writer.id}/flow_samples",
           params: valid_payload.to_json,
           headers: auth_headers_for(writer_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
      body = json_response_data
      expect(body["ingested_count"]).to eq(1)
      expect(body["rejected_count"]).to eq(0)
      expect(body["batch_id"]).to be_present
    end

    it "returns rejected records without aborting the batch" do
      writer_user = user_with_permissions("sdwan.ipfix.ingest")
      collector_for_writer = ::Sdwan::IpfixCollector.create!(
        account_id: writer_user.account.id, name: "writer-c",
        host: "10.0.0.1", port: 4739, sampling_rate: 1, state: "active"
      )

      payload = {
        flow_samples: [
          valid_payload[:flow_samples].first,
          valid_payload[:flow_samples].first.merge(src_ip: "")  # invalid
        ]
      }
      post "/api/v1/system/sdwan/ipfix_collectors/#{collector_for_writer.id}/flow_samples",
           params: payload.to_json,
           headers: auth_headers_for(writer_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
      body = json_response_data
      expect(body["ingested_count"]).to eq(1)
      expect(body["rejected_count"]).to eq(1)
      expect(body["rejected"].first["error"]).to match(/src_ip is required/)
    end

    it "rejects without sdwan.ipfix.ingest permission" do
      no_perm = user_with_permissions("sdwan.ipfix.read", account: account)
      post "/api/v1/system/sdwan/ipfix_collectors/#{collector.id}/flow_samples",
           params: valid_payload.to_json,
           headers: auth_headers_for(no_perm).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end

    it "returns 404 for a collector in another account" do
      writer_user = user_with_permissions("sdwan.ipfix.ingest")
      other = create(:account)
      stranger = ::Sdwan::IpfixCollector.create!(
        account_id: other.id, name: "stranger", host: "10.0.0.1", port: 4739,
        sampling_rate: 1, state: "active"
      )
      post "/api/v1/system/sdwan/ipfix_collectors/#{stranger.id}/flow_samples",
           params: valid_payload.to_json,
           headers: auth_headers_for(writer_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/system/sdwan/ipfix_collectors/:id/flow_samples" do
    before do
      ::Sdwan::IpfixIngestService.call(
        account: account, ipfix_collector: collector,
        records: valid_payload[:flow_samples]
      )
    end

    it "lists flow samples scoped to the collector" do
      get "/api/v1/system/sdwan/ipfix_collectors/#{collector.id}/flow_samples",
          headers: read_headers
      expect(response).to have_http_status(:ok)
      body = json_response_data
      expect(body["count"]).to eq(1)
      sample = body["flow_samples"].first
      expect(sample["src_ip"]).to eq("10.0.0.10")
      expect(sample["protocol"]).to eq(6)
      expect(sample["protocol_label"]).to eq("tcp")
    end

    it "respects the limit parameter" do
      ::Sdwan::IpfixIngestService.call(
        account: account, ipfix_collector: collector,
        records: Array.new(5) { valid_payload[:flow_samples].first }
      )
      get "/api/v1/system/sdwan/ipfix_collectors/#{collector.id}/flow_samples",
          params: { limit: 2 }, headers: read_headers
      body = json_response_data
      expect(body["count"]).to eq(2)
    end

    it "rejects without sdwan.ipfix.read permission" do
      no_perm = user_with_permissions("sdwan.networks.read", account: account)
      get "/api/v1/system/sdwan/ipfix_collectors/#{collector.id}/flow_samples",
          headers: auth_headers_for(no_perm)
      expect(response).to have_http_status(:forbidden)
    end
  end
end
