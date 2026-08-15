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
# Response-contract note — BOTH branches are reachable for an operator, and
# which one they get is decided by whether their account carries an operator
# policy for the category.
#
# An operator request carries no agent (Ai::GatedActions#gate! passes no
# `agent:`). With no matching policy row, InterventionPolicyService falls
# through to its require_approval default and the answer is 202 with the
# deferred-operation id, the row appearing only at approval time — that is the
# state of a bare spec account, and of any account whose policies were never
# seeded. IMP-187124ca2984 then had the SDWAN seed mirror the recorded per-verb
# table onto agent-less rows, so a seeded account resolves
# sdwan.port_mapping_{create,update,delete} to notify_and_proceed and gets the
# :proceed branch: 201/200 with the serialized row, written by the executor
# inside the gate.
#
# The :proceed examples below therefore build that row rather than stubbing
# InterventionPolicyService — the resolution they would stub out IS the
# mechanism the operator-path ruling turns on. Field-level validation errors are
# still 422 either way, and still never open a gate row.
RSpec.describe "Api::V1::System::Sdwan::PortMappings", type: :request do
  let(:account) { create(:account) }
  let(:manager) { user_with_permissions("system.sdwan.port_mappings.manage", account: account) }
  let(:reader)  { user_with_permissions("system.sdwan.port_mappings.read", account: account) }
  let(:network) { create(:sdwan_network, account: account) }
  let(:hub)     { create(:sdwan_peer, account: account, network: network) }
  let(:target)  { create(:sdwan_peer, account: account, network: network) }

  def collection_path = "/api/v1/system/sdwan/networks/#{network.id}/port_mappings"

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

    it "creates inline and renders the row under the seeded operator policy" do
      seed_operator_policy!("sdwan.port_mapping_create")

      post_create

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("data", "port_mapping", "listen_port")).to eq(35_432)
      expect(::Sdwan::PortMapping.count).to eq(1), "answered created over a row that does not exist"
      # 201-with-the-row is also what the UNGATED controller answered, so
      # without this the example cannot tell fixed from unfixed.
      expect(::Ai::DeferredOperation.last&.executor_class).to eq("Sdwan::Executors::CreatePortMapping"),
                                                              "notify_and_proceed create bypassed the gate entirely"
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

    it "updates inline and renders the row under the seeded operator policy" do
      seed_operator_policy!("sdwan.port_mapping_update")

      patch_update

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "port_mapping", "listen_port")).to eq(30_200)
      expect(mapping.reload.listen_port).to eq(30_200), "answered ok over an unchanged mapping"
      # 200-with-the-row is also what the UNGATED controller answered.
      expect(::Ai::DeferredOperation.last&.executor_class).to eq("Sdwan::Executors::UpdatePortMapping"),
                                                              "notify_and_proceed update bypassed the gate entirely"
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
