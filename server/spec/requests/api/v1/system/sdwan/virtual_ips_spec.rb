# frozen_string_literal: true

require "rails_helper"

# IMP-6c482005db87 — gated-CRUD wiring, VIP create.
#
# `Sdwan::Executors::CreateVirtualIp` was written, tenancy-hardened
# (IMP-134062908364), and card-labeled (IMP-3a563becb7d7) — but had no gate!
# call site: VirtualIpsController#create wrote through
# `@network.virtual_ips.new(...).save!` behind the permission check alone, so
# the seeded `sdwan.virtual_ip_create` intervention policy matched nothing an
# operator did — while DELETE and manual failover on this same controller have
# been gated since slice 9b.
#
# The create ceremony travels WITH the write: the controller used to activate
# the VIP (state → "active" when holders are named) and open the slice-9b
# initial assignment row inline after save. On the gate's :pending branch the
# executor is the only writer (gate! never calls on_proceed on :pending), so
# both moved into CreateVirtualIp#perform — the approval-path VIP must be
# indistinguishable from the inline-path VIP, or gating silently strips the
# audit trail ("no phantom current state without a history row").
#
# Response contract mirrors port_mappings_spec.rb (IMP-bf996c7abcb4): bare
# account → require_approval default → 202 + deferred-operation id; seeded
# agent-less operator row (IMP-187124ca2984) → notify_and_proceed → 201 with
# the serialized row. Field-level validation stays 422 and opens no gate row.
RSpec.describe "Api::V1::System::Sdwan::VirtualIps", type: :request do
  let(:account) { create(:account) }
  let(:manager) { user_with_permissions("system.sdwan.vips.manage", account: account) }
  let(:reader)  { user_with_permissions("system.sdwan.vips.read", account: account) }
  let(:network) { create(:sdwan_network, account: account) }
  let(:holder)  { create(:sdwan_peer, account: account, network: network) }

  def collection_path = "/api/v1/system/sdwan/networks/#{network.id}/virtual_ips"

  describe "POST /api/v1/system/sdwan/networks/:network_id/virtual_ips" do
    let(:payload) do
      {
        virtual_ip: {
          name: "svc-vip",
          cidr: "fd00:beef::1/128",
          holder_peer_ids: [ holder.id ]
        }
      }
    end

    def post_create(user: manager)
      post collection_path, params: payload, headers: auth_headers_for(user), as: :json
    end

    it "requires system.sdwan.vips.manage" do
      post_create(user: reader)

      expect(response).to have_http_status(:forbidden)
    end

    # The finding: this wrote the VIP inline behind the permission check, so
    # `sdwan.virtual_ip_create` never resolved against anything.
    it "defers the create through the autonomy gate instead of writing inline" do
      expect { post_create }.not_to change(::Sdwan::VirtualIp, :count)

      expect(response).to have_http_status(:accepted)

      deferred = ::Ai::DeferredOperation.order(created_at: :desc).first
      expect(deferred).to be_present, "POST did not route through the autonomy gate"
      expect(deferred.action_category).to eq("sdwan.virtual_ip_create")
      expect(deferred.executor_class).to eq("Sdwan::Executors::CreateVirtualIp")
      expect(deferred.params["network_id"]).to eq(network.id)
      expect(deferred.params.dig("attributes", "name")).to eq("svc-vip")
      expect(deferred.params.dig("attributes", "holder_peer_ids")).to eq([ holder.id ])
      # IMP-4a5094b22df0 — INVERTED, same rationale as the firewall-rule twin:
      # the card anchors on the operation's account, so the caller-shaped
      # tenancy key is gone from the params the gate replays. Sdwan::VirtualIp
      # derives account_id from its network in a before_validation, and the
      # controller's pre-gate validation probe still merges it.
      expect(deferred.params.dig("attributes", "account_id")).to be_nil
    end

    # The approval-path VIP must carry the same ceremony the inline path
    # performed: activation and the initial assignment audit row, attributed
    # to the requesting operator.
    it "creates an ACTIVE vip with its initial assignment row when approved" do
      post_create

      expect { approve_latest_deferred! }.to change(::Sdwan::VirtualIp, :count).by(1)

      vip = ::Sdwan::VirtualIp.order(created_at: :desc).first
      expect(vip.sdwan_network_id).to eq(network.id)
      expect(vip.account_id).to eq(account.id)
      expect(vip.state).to eq("active"), "a holder-bearing VIP must activate exactly as the inline path did"

      assignment = vip.assignments.first
      expect(assignment).to be_present, "approved create left phantom holder state with no assignment history row"
      expect(vip.assignments.count).to eq(1)
      expect(assignment.sdwan_peer_id).to eq(holder.id)
      expect(assignment.reason).to eq("initial")
      expect(assignment.released_at).to be_nil
      expect(assignment.triggered_by_user_id).to eq(manager.id),
                                                 "the assignment must attribute the REQUESTING operator across the approval window"
    end

    it "creates inline and renders the row under the seeded operator policy" do
      seed_operator_policy!("sdwan.virtual_ip_create")

      post_create

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("data", "virtual_ip", "name")).to eq("svc-vip")
      expect(response.parsed_body.dig("data", "virtual_ip", "state")).to eq("active")
      vip = ::Sdwan::VirtualIp.order(created_at: :desc).first
      expect(vip).to be_present, "answered created over a row that does not exist"
      expect(vip.assignments.count).to eq(1), "inline :proceed create lost the initial assignment row"
      # 201-with-the-row is also what the UNGATED controller answered, so
      # without this the example cannot tell fixed from unfixed.
      expect(::Ai::DeferredOperation.last&.executor_class).to eq("Sdwan::Executors::CreateVirtualIp"),
                                                              "notify_and_proceed create bypassed the gate entirely"
    end

    it "still answers 422 with field errors and opens no gate row for an invalid payload" do
      # anycast with a single holder violates anycast_requires_holder_set.
      payload[:virtual_ip][:anycast] = true

      post_create

      expect(response).to have_http_status(422)
      expect(::Sdwan::VirtualIp.count).to eq(0)
      expect(::Ai::DeferredOperation.count).to eq(0),
                                               "an unsaveable create still opened an autonomy-gate audit row"
    end
  end

  # IMP-d952c791e264 — this verb pre-checked NOTHING. Its MCP twin mirrored
  # Sdwan::VirtualIp#failover!'s two StateError guards so a doomed failover
  # fails loud instead of parking an approval that can only fail at execution;
  # the REST surface parked all of them. Both surfaces now ask the model's one
  # precondition predicate, which also catches the case neither copy had:
  # a standby whose peer row was deleted (failover_holder_peer_ids is a bare
  # uuid[] with no FK and Sdwan::Executors::DeletePeer never scrubs it).
  describe "POST /api/v1/system/sdwan/networks/:network_id/virtual_ips/:id/failover" do
    let(:standby) { create(:sdwan_peer, account: account, network: network) }
    let(:vip) do
      create(:sdwan_virtual_ip, account: account, network: network, state: "active",
             holder_peer_ids: [ holder.id ], failover_holder_peer_ids: [ standby.id ])
    end

    def post_failover(body = {}, user: manager)
      post "#{collection_path}/#{vip.id}/failover",
           params: body, headers: auth_headers_for(user), as: :json
    end

    # Positive control for all four refusals below: a failover the model
    # accepts still parks exactly as it always did.
    it "parks a healthy failover through the autonomy gate" do
      expect { post_failover }.to change(::Ai::DeferredOperation, :count).by(1)

      expect(response).to have_http_status(:accepted)
      deferred = ::Ai::DeferredOperation.order(created_at: :desc).first
      expect(deferred.action_category).to eq("system.sdwan_vip_failover")
      expect(deferred.executor_class).to eq("Sdwan::Executors::FailoverVirtualIp")
      expect(deferred.params["vip_id"]).to eq(vip.id)
    end

    it "refuses a tombstone-standby failover with 422 and opens no gate row" do
      dead = create(:sdwan_peer, account: account, network: network)
      vip.update!(failover_holder_peer_ids: [ dead.id ])
      dead.destroy!

      expect { post_failover }.not_to change(::Ai::DeferredOperation, :count)

      expect(response).to have_http_status(422)
      expect(response.parsed_body["error"]).to include(dead.id),
                                               "the refusal must name the dead standby the operator has to remove"
      expect(vip.reload.holder_peer_ids).to eq([ holder.id ])
    end

    # The named target is what Sdwan::Executors::FailoverVirtualIp#prefer_target!
    # promotes, so a live head does not make a dead target safe.
    it "refuses when the operator names a deleted target peer" do
      dead = create(:sdwan_peer, account: account, network: network)
      vip.update!(failover_holder_peer_ids: [ standby.id, dead.id ])
      dead.destroy!

      expect { post_failover({ target_peer_id: dead.id }) }
        .not_to change(::Ai::DeferredOperation, :count)

      expect(response).to have_http_status(422)
      expect(response.parsed_body["error"]).to include(dead.id)
    end

    it "refuses an anycast failover with 422 and opens no gate row" do
      vip.update!(anycast: true, holder_peer_ids: [ holder.id, standby.id ])

      expect { post_failover }.not_to change(::Ai::DeferredOperation, :count)

      expect(response).to have_http_status(422)
      expect(response.parsed_body["error"]).to match(/anycast/)
    end

    it "refuses a candidate-less failover with 422 and opens no gate row" do
      vip.update!(failover_holder_peer_ids: [])

      expect { post_failover }.not_to change(::Ai::DeferredOperation, :count)

      expect(response).to have_http_status(422)
      expect(response.parsed_body["error"]).to match(/no failover candidates/)
    end

    # The permission check must still run BEFORE the precondition, or the
    # refusal becomes a probe that tells an unauthorized caller which VIPs
    # have live standbys.
    it "requires system.sdwan.vips.manage before answering a precondition" do
      vip.update!(failover_holder_peer_ids: [])

      post_failover(user: reader)

      expect(response).to have_http_status(:forbidden)
    end
  end
end
