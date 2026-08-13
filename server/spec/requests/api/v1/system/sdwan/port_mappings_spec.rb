# frozen_string_literal: true

require "rails_helper"

# IMP-bf996c7abcb4 — gated-CRUD wiring, port-mapping resource.
#
# `Sdwan::Executors::CreatePortMapping` and `UpdatePortMapping` were written,
# tenancy-hardened (IMP-2d26f7289c38), and never called: the controller wrote
# through `@network.port_mappings.new(...).save` / `@mapping.update` behind the
# permission check alone. The seeded `sdwan.port_mapping_create` /
# `sdwan.port_mapping_update` intervention policies therefore matched no gate
# call and could not affect anything an operator did.
#
# DELETE on this same controller has been gated since slice 7b, so the
# asymmetry was: removing a DNAT entry needed approval, publishing one to the
# public internet did not.
#
# Response-contract note (202 semantics): a gated create no longer answers 201
# with the row. An operator request carries no agent, and the seeded
# sdwan.port_mapping_* policies are ai_agent_id-scoped to the SDWAN Manager, so
# InterventionPolicyService falls through to its require_approval default: 202
# with the deferred-operation id, and the row appears only at approval time.
# That is why the :proceed examples below have to stub the policy service —
# nothing in a spec account (or in a default deployment's operator path)
# resolves to auto_approve/notify_and_proceed on its own. Field-level
# validation errors are still 422 and still never open a gate row.
RSpec.describe "Api::V1::System::Sdwan::PortMappings", type: :request do
  let(:account) { create(:account) }
  let(:manager) { user_with_permissions("system.sdwan.port_mappings.manage", account: account) }
  let(:reader)  { user_with_permissions("system.sdwan.port_mappings.read", account: account) }
  let(:network) { create(:sdwan_network, account: account) }
  let(:hub)     { create(:sdwan_peer, account: account, network: network) }
  let(:target)  { create(:sdwan_peer, account: account, network: network) }

  def collection_path = "/api/v1/system/sdwan/networks/#{network.id}/port_mappings"

  # Executes the deferred operation the gate parked — the tail of the approval
  # path (Ai::ApprovalRequest ultimately calls execute_now!), not the whole of
  # it. Without this the 202 examples below would be vacuous: on the :pending
  # branch the executor never runs during the request, so "no row was created"
  # is trivially true and proves nothing about the executor.
  def approve_latest_deferred!
    Ai::DeferredOperation.order(created_at: :desc).first.tap(&:execute_now!)
  end

  # Forces the gate's :proceed branch, where the executor runs inline and the
  # controller's on_proceed lambda renders. No InterventionPolicy rows exist in
  # a spec account, so InterventionPolicyService falls through to its
  # require_approval default and nothing else here covers :proceed.
  def auto_approve_policy!
    allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
      { policy: "auto_approve", channels: [], conditions: {}, record: nil }
    )
  end

  describe "POST /api/v1/system/sdwan/networks/:network_id/port_mappings" do
    let(:payload) do
      {
        port_mapping: {
          name: "publish-postgres",
          sdwan_peer_id: hub.id,
          target_peer_id: target.id,
          listen_port: 35_432,
          target_port: 5432,
          protocol: "tcp"
        }
      }
    end

    def post_create(user: manager)
      post collection_path, params: payload, headers: auth_headers_for(user), as: :json
    end

    it "requires system.sdwan.port_mappings.manage" do
      post_create(user: reader)

      expect(response).to have_http_status(:forbidden)
    end

    # The finding: this wrote the DNAT entry inline behind the permission check,
    # so `sdwan.port_mapping_create` never resolved against anything.
    it "defers the create through the autonomy gate instead of writing inline" do
      expect { post_create }.not_to change(::Sdwan::PortMapping, :count)

      expect(response).to have_http_status(:accepted)

      deferred = ::Ai::DeferredOperation.order(created_at: :desc).first
      expect(deferred).to be_present, "POST did not route through the autonomy gate"
      expect(deferred.action_category).to eq("sdwan.port_mapping_create")
      expect(deferred.executor_class).to eq("Sdwan::Executors::CreatePortMapping")
      expect(deferred.params["network_id"]).to eq(network.id)
      expect(deferred.params.dig("attributes", "listen_port")).to eq(35_432)
    end

    # gate! never calls on_proceed on its :pending branch, so the row has to be
    # written by the deferred executor itself.
    it "creates the mapping when the deferred operation is approved" do
      post_create

      expect { approve_latest_deferred! }.to change(::Sdwan::PortMapping, :count).by(1)

      mapping = ::Sdwan::PortMapping.order(created_at: :desc).first
      expect(mapping.sdwan_network_id).to eq(network.id)
      expect(mapping.listen_port).to eq(35_432)
      # The executor takes the account from the resolved network, never from
      # the request (IMP-2d26f7289c38).
      expect(mapping.account_id).to eq(account.id)
    end

    it "creates inline and renders the row when the policy auto-approves" do
      auto_approve_policy!

      post_create

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("data", "port_mapping", "listen_port")).to eq(35_432)
      expect(::Sdwan::PortMapping.count).to eq(1), "answered created over a row that does not exist"
      # 201-with-the-row is also what the UNGATED controller answered, so
      # without this the example cannot tell fixed from unfixed.
      expect(::Ai::DeferredOperation.last&.executor_class).to eq("Sdwan::Executors::CreatePortMapping"),
                                                              "auto-approved create bypassed the gate entirely"
    end

    # Gating must not cost the caller its field-level errors: an invalid
    # payload is rejected before the gate, so no audit row is opened for an
    # operation that could never have run.
    it "still answers 422 with field errors and opens no gate row for an invalid payload" do
      payload[:port_mapping][:listen_port] = 99_999

      post_create

      expect(response).to have_http_status(422)
      expect(response.parsed_body["errors"] || response.parsed_body.dig("error")).to be_present
      expect(::Ai::DeferredOperation.count).to eq(0),
                                               "an unsaveable create still opened an autonomy-gate audit row"
    end
  end

  describe "PATCH /api/v1/system/sdwan/networks/:network_id/port_mappings/:id" do
    let!(:mapping) do
      create(:sdwan_port_mapping, account: account, network: network,
                                  hub_peer: hub, target_peer: target, listen_port: 30_100)
    end

    let(:payload) { { port_mapping: { listen_port: 30_200 } } }

    def member_path = "#{collection_path}/#{mapping.id}"

    def patch_update(user: manager)
      patch member_path, params: payload, headers: auth_headers_for(user), as: :json
    end

    it "requires system.sdwan.port_mappings.manage" do
      patch_update(user: reader)

      expect(response).to have_http_status(:forbidden)
    end

    it "defers the update through the autonomy gate instead of writing inline" do
      patch_update

      expect(response).to have_http_status(:accepted)
      expect(mapping.reload.listen_port).to eq(30_100),
                                            "the DNAT listen port was changed without an approval gate"

      deferred = ::Ai::DeferredOperation.order(created_at: :desc).first
      expect(deferred).to be_present, "PATCH did not route through the autonomy gate"
      expect(deferred.action_category).to eq("sdwan.port_mapping_update")
      expect(deferred.executor_class).to eq("Sdwan::Executors::UpdatePortMapping")
      expect(deferred.params["mapping_id"]).to eq(mapping.id)
    end

    it "applies the update when the deferred operation is approved" do
      patch_update
      approve_latest_deferred!

      expect(mapping.reload.listen_port).to eq(30_200), "approved update left the mapping unchanged"
    end

    it "updates inline and renders the row when the policy auto-approves" do
      auto_approve_policy!

      patch_update

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "port_mapping", "listen_port")).to eq(30_200)
      expect(mapping.reload.listen_port).to eq(30_200), "answered ok over an unchanged mapping"
      # 200-with-the-row is also what the UNGATED controller answered.
      expect(::Ai::DeferredOperation.last&.executor_class).to eq("Sdwan::Executors::UpdatePortMapping"),
                                                              "auto-approved update bypassed the gate entirely"
    end

    it "still answers 422 with field errors and opens no gate row for an invalid payload" do
      payload[:port_mapping][:listen_port] = 0

      patch_update

      expect(response).to have_http_status(422)
      expect(mapping.reload.listen_port).to eq(30_100)
      expect(::Ai::DeferredOperation.count).to eq(0),
                                               "an unsaveable update still opened an autonomy-gate audit row"
    end
  end
end
