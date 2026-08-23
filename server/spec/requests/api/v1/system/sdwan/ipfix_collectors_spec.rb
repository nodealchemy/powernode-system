# frozen_string_literal: true

require "rails_helper"

# Phase O6 of the OVS+OVN dual-profile networking roadmap.
RSpec.describe "Api::V1::System::Sdwan::IpfixCollectors", type: :request do
  let(:user)    { user_with_permissions("system.sdwan.ipfix.read") }
  let(:account) { user.account }
  let(:headers) { auth_headers_for(user) }

  before do
    Sdwan::IpfixCollector.where(account_id: account.id).delete_all
  end

  # IMP-6bbe5c673c38 gated #create, #update and #destroy. Examples that pin
  # WRITE semantics force the gate's :proceed branch with this and keep
  # asserting exactly what they always did; the parked branch has its own
  # examples below. The default policy resolution is require_approval, so
  # nothing else exercises the inline path.
  def auto_approve_policy!
    allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
      { policy: "auto_approve", channels: [], conditions: {}, record: nil }
    )
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
      no_perm_user = user_with_permissions("system.sdwan.networks.read")
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
    let(:manager) { user_with_permissions("system.sdwan.ipfix.read", "system.sdwan.ipfix.manage", account: account) }
    let(:manager_headers) { auth_headers_for(manager) }
    let!(:collector) do
      ::Sdwan::IpfixCollector.create!(
        account_id: account.id, name: "primary",
        host: "10.0.0.1", port: 4739,
        sampling_rate: 1, state: "active"
      )
    end

    before { auto_approve_policy! }

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
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects without sdwan.ipfix.manage permission" do
      patch "/api/v1/system/sdwan/ipfix_collectors/#{collector.id}",
            params: { ipfix_collector: { state: "disabled" } }.to_json,
            headers: headers.merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "DELETE /api/v1/system/sdwan/ipfix_collectors/:id" do
    let(:manager) { user_with_permissions("system.sdwan.ipfix.read", "system.sdwan.ipfix.manage", account: account) }
    let(:manager_headers) { auth_headers_for(manager) }

    before { auto_approve_policy! }

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

  # IMP-6bbe5c673c38 — the other half of the verb split this task closed.
  # An operator could inspect, toggle and destroy a collector from the
  # console but could not CREATE one there: creation lived only on the AI
  # surfaces (system_sdwan_create_ipfix_collector, or the
  # SdwanIpfixCollectorComposeExecutor skill), so standing up flow export
  # meant leaving the console.
  #
  # The new arm is GATED — Sdwan::Executors::CreateIpfixCollector performs
  # the write, exactly as PortMappingsController#create does. Filling a
  # parity gap with an UNGATED mutating verb would trade one defect for a
  # worse one. The seeded operator-path tier for
  # sdwan.ipfix_collector_create is notify_and_proceed, which resolves to
  # :proceed and answers 201; an account with no seeded operator policy
  # falls through to the require_approval default and gets 202, the same
  # contract every other gated SDWAN create carries.
  describe "POST /api/v1/system/sdwan/ipfix_collectors" do
    let(:manager) { user_with_permissions("system.sdwan.ipfix.read", "system.sdwan.ipfix.manage", account: account) }
    let(:manager_headers) { auth_headers_for(manager) }

    def collector_named(name)
      ::Sdwan::IpfixCollector.find_by(account_id: account.id, name: name)
    end

    it "creates a collector through the executor and answers 201 with the serialized row" do
      auto_approve_policy!

      post "/api/v1/system/sdwan/ipfix_collectors",
           params: { ipfix_collector: { name: "console-made", host: "fd00::20", port: 4739, sampling_rate: 64 } },
           headers: manager_headers, as: :json

      expect(response).to have_http_status(:created)
      expect(json_response_data["ipfix_collector"]["name"]).to eq("console-made")
      expect(json_response_data["ipfix_collector"]["target_endpoint"]).to eq("[fd00::20]:4739")
      expect(collector_named("console-made")).to be_present
      expect(collector_named("console-made").sampling_rate).to eq(64)
    end

    it "defaults port and sampling_rate the way the MCP twin does" do
      auto_approve_policy!

      post "/api/v1/system/sdwan/ipfix_collectors",
           params: { ipfix_collector: { name: "defaults", host: "10.0.0.90" } },
           headers: manager_headers, as: :json

      expect(response).to have_http_status(:created)
      expect(collector_named("defaults").port).to eq(4739)
      expect(collector_named("defaults").sampling_rate).to eq(1)
    end

    # Validate BEFORE the gate: an unsaveable payload keeps its field-level
    # 422 and opens no audit row for an operation that could never run.
    it "refuses an invalid payload with field errors and parks nothing" do
      expect {
        post "/api/v1/system/sdwan/ipfix_collectors",
             params: { ipfix_collector: { name: "", host: "" } },
             headers: manager_headers, as: :json
      }.not_to change(::Ai::DeferredOperation, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(collector_named("")).to be_nil
    end

    it "parks instead of creating when the account's tier requires approval" do
      post "/api/v1/system/sdwan/ipfix_collectors",
           params: { ipfix_collector: { name: "parked", host: "10.0.0.91" } },
           headers: manager_headers, as: :json

      expect(response).to have_http_status(:accepted)
      expect(collector_named("parked")).to be_nil,
                                           "the row was created inline and reported as deferred afterwards"
    end

    it "rejects without sdwan.ipfix.manage permission" do
      post "/api/v1/system/sdwan/ipfix_collectors",
           params: { ipfix_collector: { name: "nope", host: "10.0.0.92" } },
           headers: headers, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(collector_named("nope")).to be_nil
    end
  end

  # IMP-6bbe5c673c38 — #update and #destroy used to write INLINE while their
  # MCP twins had been gated since IMP-97c7b4123d8f. That made the whole gate
  # regime walk-around-able: an operator who hardened
  # sdwan.ipfix_collector_update to require_approval got no protection,
  # because the same JWT performed the identical AASM transition on this
  # route, outside Ai::AutonomyGate.
  #
  # Nothing is stubbed here — these run against the require_approval default a
  # fresh account gets. Each example asserts the same two properties, which is
  # what "gated" has to mean for a write:
  #
  #   1. the answer is 202, the gate's parked shape, not a success body
  #   2. the row is UNCHANGED — not transitioned, not destroyed
  #
  # Property 2 is what a status-code-only assertion would miss: a controller
  # that wrote first and answered 202 afterwards would satisfy (1) alone.
  describe "approval gating on the state toggle and the delete" do
    let(:manager) { user_with_permissions("system.sdwan.ipfix.read", "system.sdwan.ipfix.manage", account: account) }
    let(:manager_headers) { auth_headers_for(manager) }

    def collector!(state: "active")
      ::Sdwan::IpfixCollector.create!(
        account_id: account.id, name: "gated-#{SecureRandom.hex(3)}",
        host: "10.0.0.1", port: 4739, sampling_rate: 1, state: state
      )
    end

    def reloaded(collector)
      ::Sdwan::IpfixCollector.find_by(id: collector.id)
    end

    it "parks the state toggle instead of transitioning the row" do
      collector = collector!(state: "active")

      patch "/api/v1/system/sdwan/ipfix_collectors/#{collector.id}",
            params: { ipfix_collector: { state: "disabled" } }.to_json,
            headers: manager_headers.merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:accepted)
      expect(reloaded(collector).state).to eq("active"),
                                           "the controller transitioned the row and reported 202 afterwards"
    end

    it "applies the toggle in place once the parked operation is approved" do
      collector = collector!(state: "active")

      patch "/api/v1/system/sdwan/ipfix_collectors/#{collector.id}",
            params: { ipfix_collector: { state: "disabled" } }.to_json,
            headers: manager_headers.merge("Content-Type" => "application/json")

      deferred = ::Ai::DeferredOperation.find_by(id: json_response_data["deferred_operation_id"])
      expect(deferred).to be_present, "no deferred operation was parked: #{json_response_data.inspect}"
      expect(deferred.action_category).to eq("sdwan.ipfix_collector_update")
      expect(deferred.executor_class).to eq("Sdwan::Executors::UpdateIpfixCollector")

      deferred.execute_now!

      expect(reloaded(collector)).to be_present, "approval destroyed the row instead of transitioning it"
      expect(reloaded(collector).state).to eq("disabled")
    end

    it "parks the delete instead of destroying the row and its flow samples" do
      collector = collector!
      create_list(:sdwan_flow_sample, 2, account: account, ipfix_collector: collector)

      delete "/api/v1/system/sdwan/ipfix_collectors/#{collector.id}", headers: manager_headers

      expect(response).to have_http_status(:accepted)
      expect(reloaded(collector)).to be_present,
                                     "the controller destroyed the row and reported 202 afterwards"
      expect(::Sdwan::FlowSample.where(ipfix_collector_id: collector.id).count).to eq(2)
    end

    # Refused BEFORE the gate, so an impossible request fails now rather than
    # sitting in an operator's queue until they approve it and watch it fail.
    it "refuses an unknown state without parking anything" do
      collector = collector!

      expect {
        patch "/api/v1/system/sdwan/ipfix_collectors/#{collector.id}",
              params: { ipfix_collector: { state: "haunted" } }.to_json,
              headers: manager_headers.merge("Content-Type" => "application/json")
      }.not_to change(::Ai::DeferredOperation, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(reloaded(collector).state).to eq("active")
    end

    # The permission check runs before the gate too, so a caller without
    # sdwan.ipfix.manage cannot open an audit row it could never execute.
    it "refuses an unpermitted caller without parking anything" do
      collector = collector!

      expect {
        delete "/api/v1/system/sdwan/ipfix_collectors/#{collector.id}", headers: headers
      }.not_to change(::Ai::DeferredOperation, :count)

      expect(response).to have_http_status(:forbidden)
      expect(reloaded(collector)).to be_present
    end
  end
end
