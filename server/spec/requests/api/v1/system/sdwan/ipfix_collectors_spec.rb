# frozen_string_literal: true

require "rails_helper"

# Phase O6 of the OVS+OVN dual-profile networking roadmap.
RSpec.describe "Api::V1::System::Sdwan::IpfixCollectors", type: :request do
  let(:user)    { user_with_permissions("sdwan.ipfix.read") }
  let(:account) { user.account }
  let(:headers) { auth_headers_for(user) }

  before do
    Sdwan::IpfixCollector.where(account_id: account.id).delete_all
  end

  describe "GET /api/v1/system/sdwan/ipfix_collectors" do
    it "returns an empty list when no collectors exist" do
      get "/api/v1/system/sdwan/ipfix_collectors", headers: headers
      expect(response).to have_http_status(:ok)
      expect(json_response_data["ipfix_collectors"]).to eq([])
    end

    it "lists collectors scoped to the current account" do
      ::Sdwan::IpfixCollector.create!(
        account_id: account.id, name: "ours", host: "10.0.0.1", port: 4739,
        sampling_rate: 1, state: "active"
      )
      other = create(:account)
      ::Sdwan::IpfixCollector.create!(
        account_id: other.id, name: "theirs", host: "10.0.0.2", port: 4739,
        sampling_rate: 1, state: "active"
      )

      get "/api/v1/system/sdwan/ipfix_collectors", headers: headers
      names = json_response_data["ipfix_collectors"].map { |c| c["name"] }
      expect(names).to contain_exactly("ours")
    end

    it "marks the oldest active collector as the winning one" do
      old = ::Sdwan::IpfixCollector.create!(
        account_id: account.id, name: "old", host: "10.0.0.1", port: 4739,
        sampling_rate: 1, state: "active", created_at: 1.hour.ago
      )
      _new = ::Sdwan::IpfixCollector.create!(
        account_id: account.id, name: "new", host: "10.0.0.2", port: 4739,
        sampling_rate: 1, state: "active"
      )

      get "/api/v1/system/sdwan/ipfix_collectors", headers: headers
      rows = json_response_data["ipfix_collectors"]
      winning = rows.find { |r| r["is_winning_collector"] }
      expect(winning["id"]).to eq(old.id)
    end

    it "marks a disabled collector as not winning even if it's the oldest active candidate when no active rows exist" do
      ::Sdwan::IpfixCollector.create!(
        account_id: account.id, name: "disabled-only", host: "10.0.0.1", port: 4739,
        sampling_rate: 1, state: "disabled"
      )
      get "/api/v1/system/sdwan/ipfix_collectors", headers: headers
      rows = json_response_data["ipfix_collectors"]
      expect(rows.first["is_winning_collector"]).to be false
    end

    it "filters by state" do
      ::Sdwan::IpfixCollector.create!(
        account_id: account.id, name: "a", host: "10.0.0.1", port: 4739,
        sampling_rate: 1, state: "active"
      )
      ::Sdwan::IpfixCollector.create!(
        account_id: account.id, name: "b", host: "10.0.0.2", port: 4739,
        sampling_rate: 1, state: "disabled"
      )

      get "/api/v1/system/sdwan/ipfix_collectors", params: { state: "disabled" }, headers: headers
      states = json_response_data["ipfix_collectors"].map { |c| c["state"] }
      expect(states).to eq([ "disabled" ])
    end

    it "rejects without the read permission" do
      no_perm_user = user_with_permissions("sdwan.networks.read")
      get "/api/v1/system/sdwan/ipfix_collectors", headers: auth_headers_for(no_perm_user)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET /api/v1/system/sdwan/ipfix_collectors/:id" do
    it "returns the full collector with timestamps + bracketed IPv6 endpoint" do
      collector = ::Sdwan::IpfixCollector.create!(
        account_id: account.id, name: "v6", host: "fd00::1", port: 4739,
        sampling_rate: 100, state: "active"
      )

      get "/api/v1/system/sdwan/ipfix_collectors/#{collector.id}", headers: headers
      payload = json_response_data["ipfix_collector"]
      expect(payload["id"]).to eq(collector.id)
      expect(payload["target_endpoint"]).to eq("[fd00::1]:4739")
      expect(payload["sampling_rate"]).to eq(100)
      expect(payload["is_winning_collector"]).to be true
      expect(payload["created_at"]).to be_present
    end

    it "returns 404 for a collector in a different account" do
      other = create(:account)
      collector = ::Sdwan::IpfixCollector.create!(
        account_id: other.id, name: "stranger", host: "10.0.0.1", port: 4739,
        sampling_rate: 1, state: "active"
      )
      get "/api/v1/system/sdwan/ipfix_collectors/#{collector.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /api/v1/system/sdwan/ipfix_collectors/:id" do
    let(:manager) { user_with_permissions("sdwan.ipfix.read", "sdwan.ipfix.manage", account: account) }
    let(:manager_headers) { auth_headers_for(manager) }
    let!(:collector) do
      ::Sdwan::IpfixCollector.create!(
        account_id: account.id, name: "primary",
        host: "10.0.0.1", port: 4739,
        sampling_rate: 1, state: "active"
      )
    end

    it "transitions to disabled when state=disabled" do
      patch "/api/v1/system/sdwan/ipfix_collectors/#{collector.id}",
            params: { ipfix_collector: { state: "disabled" } }.to_json,
            headers: manager_headers.merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
      expect(collector.reload.state).to eq("disabled")
    end

    it "transitions to active when state=active" do
      collector.update!(state: "disabled")
      patch "/api/v1/system/sdwan/ipfix_collectors/#{collector.id}",
            params: { ipfix_collector: { state: "active" } }.to_json,
            headers: manager_headers.merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
      expect(collector.reload.state).to eq("active")
    end

    it "rejects an unknown state" do
      patch "/api/v1/system/sdwan/ipfix_collectors/#{collector.id}",
            params: { ipfix_collector: { state: "haunted" } }.to_json,
            headers: manager_headers.merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "rejects without sdwan.ipfix.manage permission" do
      patch "/api/v1/system/sdwan/ipfix_collectors/#{collector.id}",
            params: { ipfix_collector: { state: "disabled" } }.to_json,
            headers: headers.merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "DELETE /api/v1/system/sdwan/ipfix_collectors/:id" do
    let(:manager) { user_with_permissions("sdwan.ipfix.read", "sdwan.ipfix.manage", account: account) }
    let(:manager_headers) { auth_headers_for(manager) }

    it "destroys the collector + cascades to its flow_samples" do
      collector = ::Sdwan::IpfixCollector.create!(
        account_id: account.id, name: "doomed", host: "10.0.0.1", port: 4739,
        sampling_rate: 1, state: "active"
      )
      ::Sdwan::IpfixIngestService.call(
        account: account, ipfix_collector: collector,
        records: [ {
          src_ip: "10.0.0.10", dst_ip: "10.0.0.20",
          src_port: 12345, dst_port: 5432, protocol: 6,
          octet_count: 1500, packet_count: 1,
          flow_start_at: 1.minute.ago.iso8601,
          flow_end_at: Time.current.iso8601
        } ]
      )
      expect(::Sdwan::FlowSample.where(ipfix_collector_id: collector.id).count).to eq(1)

      delete "/api/v1/system/sdwan/ipfix_collectors/#{collector.id}", headers: manager_headers

      expect(response).to have_http_status(:ok)
      expect(json_response_data["deleted"]).to be true
      expect(::Sdwan::IpfixCollector.find_by(id: collector.id)).to be_nil
      expect(::Sdwan::FlowSample.where(ipfix_collector_id: collector.id).count).to eq(0)
    end

    it "rejects without sdwan.ipfix.manage permission" do
      collector = ::Sdwan::IpfixCollector.create!(
        account_id: account.id, name: "kept", host: "10.0.0.1", port: 4739,
        sampling_rate: 1, state: "active"
      )
      delete "/api/v1/system/sdwan/ipfix_collectors/#{collector.id}", headers: headers
      expect(response).to have_http_status(:forbidden)
    end
  end
end
