# frozen_string_literal: true

require "rails_helper"

# Phase O6 of the OVS+OVN dual-profile networking roadmap.
RSpec.describe "Api::V1::System::Sdwan::HostBridges", type: :request do
  let(:user)    { user_with_permissions("system.sdwan.host_bridges.read") }
  let(:account) { user.account }
  let(:headers) { auth_headers_for(user) }

  let(:platform)   { create(:system_node_platform, account: account) }
  let(:template)   { create(:system_node_template, account: account, node_platform: platform) }
  let(:node_a)     { create(:system_node, account: account, node_template: template, name: "n-a") }
  let(:node_b)     { create(:system_node, account: account, node_template: template, name: "n-b") }
  let(:instance_a) { create(:system_node_instance, :running, node: node_a) }
  let(:instance_b) { create(:system_node_instance, :running, node: node_b) }

  before do
    Sdwan::HostBridge.where(account_id: account.id).delete_all
  end

  describe "GET /api/v1/system/sdwan/host_bridges" do
    it "returns an empty list when no bridges exist" do
      get "/api/v1/system/sdwan/host_bridges", headers: headers
      expect(response).to have_http_status(:ok)
      expect(json_response_data["host_bridges"]).to eq([])
      expect(json_response_data["count"]).to eq(0)
    end

    it "lists bridges scoped to the current account only" do
      ::Sdwan::HostBridgeAllocator.allocate!(host: instance_a, kind: "linux")
      other_account = create(:account)
      other_node = create(:system_node, account: other_account, node_template: template)
      other_instance = create(:system_node_instance, :running, node: other_node)
      ::Sdwan::HostBridgeAllocator.allocate!(host: other_instance, kind: "linux", account: other_account)

      get "/api/v1/system/sdwan/host_bridges", headers: headers
      expect(response).to have_http_status(:ok)
      ids = json_response_data["host_bridges"].map { |b| b["node_instance_id"] }
      expect(ids).to contain_exactly(instance_a.id)
    end

    it "includes node_instance_name + network_profile in each row" do
      ::Sdwan::HostBridgeAllocator.allocate!(host: instance_a, kind: "linux")
      get "/api/v1/system/sdwan/host_bridges", headers: headers
      row = json_response_data["host_bridges"].first
      expect(row["node_instance_name"]).to eq(instance_a.name)
      expect(row["network_profile"]).to eq("lightweight")
      expect(row["bridge_name"]).to start_with("pwnbr-")
    end

    it "filters by node_instance_id" do
      ::Sdwan::HostBridgeAllocator.allocate!(host: instance_a, kind: "linux")
      ::Sdwan::HostBridgeAllocator.allocate!(host: instance_b, kind: "linux")

      get "/api/v1/system/sdwan/host_bridges",
          params: { node_instance_id: instance_a.id }, headers: headers
      ids = json_response_data["host_bridges"].map { |b| b["node_instance_id"] }
      expect(ids).to contain_exactly(instance_a.id)
      expect(json_response_data["filters"]["node_instance_id"]).to eq(instance_a.id)
    end

    it "filters by state" do
      bridge = ::Sdwan::HostBridgeAllocator.allocate!(host: instance_a, kind: "linux")
      ::Sdwan::HostBridgeAllocator.allocate!(host: instance_b, kind: "linux")
      bridge.mark_active!

      get "/api/v1/system/sdwan/host_bridges",
          params: { state: "active" }, headers: headers
      states = json_response_data["host_bridges"].map { |b| b["state"] }
      expect(states).to eq([ "active" ])
    end

    it "filters by kind" do
      ::Sdwan::HostBridgeAllocator.allocate!(host: instance_a, kind: "linux")
      instance_b.update!(network_profile: "heavyweight")
      ::Sdwan::HostBridgeAllocator.allocate!(host: instance_b)

      get "/api/v1/system/sdwan/host_bridges",
          params: { kind: "ovs" }, headers: headers
      kinds = json_response_data["host_bridges"].map { |b| b["kind"] }
      expect(kinds).to eq([ "ovs" ])
    end

    it "rejects without the read permission" do
      no_perm_user = user_with_permissions("system.sdwan.networks.read")
      get "/api/v1/system/sdwan/host_bridges", headers: auth_headers_for(no_perm_user)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET /api/v1/system/sdwan/host_bridges/:id" do
    it "returns the full bridge shape with timestamps" do
      bridge = ::Sdwan::HostBridgeAllocator.allocate!(host: instance_a, kind: "linux")
      bridge.mark_active!

      get "/api/v1/system/sdwan/host_bridges/#{bridge.id}", headers: headers
      expect(response).to have_http_status(:ok)
      payload = json_response_data["host_bridge"]
      expect(payload["id"]).to eq(bridge.id)
      expect(payload["state"]).to eq("active")
      expect(payload["applied_at"]).to be_present
      expect(payload["created_at"]).to be_present
    end

    it "returns 404 for a bridge in a different account" do
      other_account = create(:account)
      other_node = create(:system_node, account: other_account, node_template: template)
      other_instance = create(:system_node_instance, :running, node: other_node)
      bridge = ::Sdwan::HostBridgeAllocator.allocate!(host: other_instance, kind: "linux", account: other_account)

      get "/api/v1/system/sdwan/host_bridges/#{bridge.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  # IMP-53a5c597ec8c — POST is NEW. Allocation existed only on the AI
  # surfaces (system_sdwan_create_host_bridge and the
  # SdwanHostBridgeComposeExecutor skill), so a console operator could see
  # bridges and delete them but never stand one up. This is API-surface
  # parity, not yet an operator-experience fix: no console form posts here
  # yet, and the SDWAN hub still points operators at the MCP action.
  #
  # It is GATED through the existing Sdwan::Executors::CreateHostBridge,
  # matching IpfixCollectorsController#create — closing a parity gap by
  # adding an UNGATED mutating verb would trade one defect for a worse one.
  # gate_create! is the wrong helper here: it needs a caller-built unsaved
  # candidate, and a HostBridge cannot be built without the short_id the
  # allocator mints under a per-host row lock. So the validation the caller
  # can do (host in account, kind in KINDS) runs first and the allocation
  # itself goes through a bare gate!.
  describe "POST /api/v1/system/sdwan/host_bridges" do
    let(:manager) { user_with_permissions("system.sdwan.host_bridges.read", "system.sdwan.host_bridges.manage", account: account) }
    let(:manager_headers) { auth_headers_for(manager) }

    def auto_approve_policy!
      allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
        { policy: "auto_approve", channels: [], conditions: {}, record: nil }
      )
    end

    def bridges_on(host)
      ::Sdwan::HostBridge.where(account_id: account.id, node_instance_id: host.id)
    end

    it "allocates through the executor and answers 201 with the serialized row" do
      auto_approve_policy!

      post "/api/v1/system/sdwan/host_bridges",
           params: { node_instance_id: instance_a.id, kind: "linux" }.to_json,
           headers: manager_headers.merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:created)
      payload = json_response_data["host_bridge"]
      expect(payload["node_instance_id"]).to eq(instance_a.id)
      expect(payload["bridge_name"]).to start_with("pwnbr-")
      expect(payload["kind"]).to eq("linux")
      expect(bridges_on(instance_a).count).to eq(1)
    end

    it "defaults kind from the host's network_profile the way the MCP twin does" do
      auto_approve_policy!
      instance_a.update!(network_profile: "heavyweight")

      post "/api/v1/system/sdwan/host_bridges",
           params: { node_instance_id: instance_a.id }.to_json,
           headers: manager_headers.merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:created)
      expect(json_response_data["host_bridge"]["kind"]).to eq("ovs")
    end

    # Refused BEFORE the gate — an impossible request must fail now, not sit
    # in an operator's queue until they approve it and watch it fail. The
    # wording is shared verbatim with the MCP twin.
    it "refuses an unknown kind without parking anything" do
      expect {
        post "/api/v1/system/sdwan/host_bridges",
             params: { node_instance_id: instance_a.id, kind: "not-a-kind" }.to_json,
             headers: manager_headers.merge("Content-Type" => "application/json")
      }.not_to change(::Ai::DeferredOperation, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(bridges_on(instance_a)).to be_empty
    end

    it "parks the allocation instead of minting a row when policy requires approval" do
      post "/api/v1/system/sdwan/host_bridges",
           params: { node_instance_id: instance_a.id, kind: "linux" }.to_json,
           headers: manager_headers.merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:accepted)
      expect(bridges_on(instance_a)).to be_empty,
                                        "the controller allocated the bridge and reported 202 afterwards"
    end

    it "refuses a host in a different account" do
      other_account = create(:account)
      other_node = create(:system_node, account: other_account, node_template: template)
      other_instance = create(:system_node_instance, :running, node: other_node)

      post "/api/v1/system/sdwan/host_bridges",
           params: { node_instance_id: other_instance.id }.to_json,
           headers: manager_headers.merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:not_found)
    end

    it "refuses an unpermitted caller without parking anything" do
      expect {
        post "/api/v1/system/sdwan/host_bridges",
             params: { node_instance_id: instance_a.id }.to_json,
             headers: headers.merge("Content-Type" => "application/json")
      }.not_to change(::Ai::DeferredOperation, :count)

      expect(response).to have_http_status(:forbidden)
    end
  end

  # IMP-53a5c597ec8c — activate is NEW on REST. The MCP twin's own comment
  # records why the verb has to exist at all: `compilable` emits active and
  # draining only, so a bridge left in `pending` is INVISIBLE to the
  # topology compiler. Without this route a console operator who allocated
  # a bridge had no way to make it take effect — the MCP action or `rails
  # runner` were the only paths. Gated on sdwan.host_bridge_update through
  # Sdwan::Executors::ActivateHostBridge, the same executor the MCP arm uses.
  describe "POST /api/v1/system/sdwan/host_bridges/:id/activate" do
    let(:manager) { user_with_permissions("system.sdwan.host_bridges.read", "system.sdwan.host_bridges.manage", account: account) }
    let(:manager_headers) { auth_headers_for(manager) }

    def auto_approve_policy!
      allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
        { policy: "auto_approve", channels: [], conditions: {}, record: nil }
      )
    end

    def state_of(bridge)
      ::Sdwan::HostBridge.find(bridge.id).state
    end

    it "activates a pending bridge and makes it visible to the compiler" do
      auto_approve_policy!
      bridge = ::Sdwan::HostBridgeAllocator.allocate!(host: instance_a, kind: "linux")
      expect(::Sdwan::HostBridgeResolver.bridge_present?(instance_a)).to be(false)

      post "/api/v1/system/sdwan/host_bridges/#{bridge.id}/activate", headers: manager_headers

      expect(response).to have_http_status(:ok)
      expect(json_response_data["host_bridge"]["state"]).to eq("active")
      expect(state_of(bridge)).to eq("active")
      expect(::Sdwan::HostBridgeResolver.bridge_present?(instance_a)).to be(true)
    end

    # Same refusal wording as Ai::Tools::SdwanTool#activate_host_bridge, so
    # the two surfaces naming one operation cannot disagree.
    it "refuses activating a removed bridge without parking anything" do
      bridge = ::Sdwan::HostBridgeAllocator.allocate!(host: instance_a, kind: "linux")
      bridge.mark_removed!

      expect {
        post "/api/v1/system/sdwan/host_bridges/#{bridge.id}/activate", headers: manager_headers
      }.not_to change(::Ai::DeferredOperation, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(json_response["error"].to_s).to match(/readopt/)
      expect(state_of(bridge)).to eq("removed")
    end

    it "parks the transition instead of applying it when policy requires approval" do
      bridge = ::Sdwan::HostBridgeAllocator.allocate!(host: instance_a, kind: "linux")

      post "/api/v1/system/sdwan/host_bridges/#{bridge.id}/activate", headers: manager_headers

      expect(response).to have_http_status(:accepted)
      expect(state_of(bridge)).to eq("pending"),
                                  "the controller transitioned the row and reported 202 afterwards"
    end

    it "rejects without sdwan.host_bridges.manage permission" do
      bridge = ::Sdwan::HostBridgeAllocator.allocate!(host: instance_a, kind: "linux")
      post "/api/v1/system/sdwan/host_bridges/#{bridge.id}/activate", headers: headers
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "DELETE /api/v1/system/sdwan/host_bridges/:id" do
    let(:manager) { user_with_permissions("system.sdwan.host_bridges.read", "system.sdwan.host_bridges.manage", account: account) }
    let(:manager_headers) { auth_headers_for(manager) }

    def auto_approve_policy!
      allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
        { policy: "auto_approve", channels: [], conditions: {}, record: nil }
      )
    end

    # IMP-53a5c597ec8c CHANGED THIS BEHAVIOUR. This route used to call
    # HostBridgeAllocator.release!(force: true) unconditionally, with no way
    # for a caller to ask for anything else. A bare DELETE now DRAINS.
    it "drains the bridge by default rather than hard-releasing it" do
      auto_approve_policy!
      bridge = ::Sdwan::HostBridgeAllocator.allocate!(host: instance_a, kind: "linux")
      bridge.mark_active!

      delete "/api/v1/system/sdwan/host_bridges/#{bridge.id}", headers: manager_headers

      expect(response).to have_http_status(:ok)
      expect(json_response_data["deleted"]).to be true
      expect(json_response_data["forced"]).to be false
      expect(::Sdwan::HostBridge.find(bridge.id).state).to eq("draining")
    end

    it "hard-releases when the caller explicitly opts in with force=true" do
      auto_approve_policy!
      bridge = ::Sdwan::HostBridgeAllocator.allocate!(host: instance_a, kind: "linux")
      bridge.mark_active!

      delete "/api/v1/system/sdwan/host_bridges/#{bridge.id}",
             params: { force: true }.to_json,
             headers: manager_headers.merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:ok)
      expect(json_response_data["forced"]).to be true
      expect(::Sdwan::HostBridge.find(bridge.id).state).to eq("removed")
    end

    # REST params arrive as STRINGS while MCP params arrive as real
    # booleans. One coercion site (Sdwan::Executors::ReleaseHostBridge.force?)
    # answers both, so ?force=true from a browser and force: true from an
    # agent mean the same thing — the IPFIX `.to_i` lesson applied to a flag.
    it "accepts force as a query-string boolean" do
      auto_approve_policy!
      bridge = ::Sdwan::HostBridgeAllocator.allocate!(host: instance_a, kind: "linux")
      bridge.mark_active!

      delete "/api/v1/system/sdwan/host_bridges/#{bridge.id}?force=true", headers: manager_headers

      expect(response).to have_http_status(:ok)
      expect(::Sdwan::HostBridge.find(bridge.id).state).to eq("removed")
    end

    it "treats force=false as the default drain" do
      auto_approve_policy!
      bridge = ::Sdwan::HostBridgeAllocator.allocate!(host: instance_a, kind: "linux")
      bridge.mark_active!

      delete "/api/v1/system/sdwan/host_bridges/#{bridge.id}?force=false", headers: manager_headers

      expect(::Sdwan::HostBridge.find(bridge.id).state).to eq("draining")
    end

    # IMP-53a5c597ec8c absorbs offer 01a02b9a-0266 and the residual
    # IMP-97c7b4123d8f recorded in db/seeds/system_sdwan_manager_agent.rb:
    # this route wrote INLINE while its MCP twin had been gated since that
    # task. That made the whole regime walk-around-able — an operator who
    # hardened sdwan.host_bridge_delete got no protection, because the same
    # JWT carrying system.sdwan.host_bridges.manage performed the identical
    # release one route over, outside Ai::AutonomyGate. A gate a caller can
    # walk around is not a gate.
    #
    # Nothing is stubbed here — this runs against the require_approval
    # default a fresh account gets.
    it "parks the release instead of performing it" do
      bridge = ::Sdwan::HostBridgeAllocator.allocate!(host: instance_a, kind: "linux")
      bridge.mark_active!

      delete "/api/v1/system/sdwan/host_bridges/#{bridge.id}", headers: manager_headers

      expect(response).to have_http_status(:accepted)
      expect(::Sdwan::HostBridge.find(bridge.id).state).to eq("active"),
                                                          "the controller released the row and reported 202 afterwards"
    end

    it "carries the force flag the caller asked for into the parked operation" do
      bridge = ::Sdwan::HostBridgeAllocator.allocate!(host: instance_a, kind: "linux")
      bridge.mark_active!

      delete "/api/v1/system/sdwan/host_bridges/#{bridge.id}",
             params: { force: true }.to_json,
             headers: manager_headers.merge("Content-Type" => "application/json")

      deferred = ::Ai::DeferredOperation.find_by(id: json_response_data["deferred_operation_id"])
      expect(deferred).to be_present, "no deferred operation was parked: #{json_response_data.inspect}"
      expect(deferred.action_category).to eq("sdwan.host_bridge_delete")
      expect(deferred.executor_class).to eq("Sdwan::Executors::ReleaseHostBridge")
      expect(deferred.params["force"]).to be(true)

      deferred.execute_now!

      expect(::Sdwan::HostBridge.find(bridge.id).state).to eq("removed")
    end

    it "rejects without sdwan.host_bridges.manage permission" do
      bridge = ::Sdwan::HostBridgeAllocator.allocate!(host: instance_a, kind: "linux")
      expect {
        delete "/api/v1/system/sdwan/host_bridges/#{bridge.id}", headers: headers
      }.not_to change(::Ai::DeferredOperation, :count)
      expect(response).to have_http_status(:forbidden)
    end
  end

  # ── IMP-53a5c597ec8c — the parity oracle ────────────────────────────────
  #
  # ONE verb, ONE default, both surfaces. Before this task the same act had
  # opposite safety postures depending on who asked:
  #
  #   REST  host_bridges#destroy   → release!(force: true)  — hard-forced
  #   MCP   release_host_bridge    → force defaults false   — honors drain
  #
  # So an OPERATOR delete skipped a drain window an AGENT release honored.
  # The default is now DRAIN on both — the safe one — with force an explicit
  # opt-in reachable from either surface.
  #
  # The oracle is the drain window ITSELF, not a 200 and not an accepted
  # `force` key. What draining buys is that the row stays `compilable`, so
  # the topology compiler keeps emitting the bridge and
  # Sdwan::HostBridgeResolver keeps answering for the host — in-flight taps
  # survive with the bridge name they were provisioned against. A hard
  # release drops the row out of `compilable` and the resolver raises
  # NoBridgeForHost: the dependent breaks. Those observables, not the
  # status code, are what the two surfaces have to agree on.
  #
  # Both surfaces are exercised in the SAME example. A spec that exercised
  # one would prove nothing about parity, which is the whole point here.
  describe "release force/drain parity across REST and MCP" do
    let(:manager) { user_with_permissions("system.sdwan.host_bridges.read", "system.sdwan.host_bridges.manage", account: account) }
    let(:manager_headers) { auth_headers_for(manager) }

    def auto_approve_policy!
      allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
        { policy: "auto_approve", channels: [], conditions: {}, record: nil }
      )
    end

    def mcp_tool
      ::Ai::Tools::SdwanTool.new(account: account, internal: true)
    end

    # Fetch helpers are `def`, never `let`: each is a probe of CURRENT
    # database state, and a memoized probe that answered before the release
    # ran would make the oracle assert nothing.
    def fresh_host(label)
      node = create(:system_node, account: account, node_template: template, name: "hb-#{label}")
      create(:system_node_instance, :running, node: node)
    end

    def active_bridge_on(host)
      bridge = ::Sdwan::HostBridgeAllocator.allocate!(host: host, kind: "linux")
      bridge.mark_active!
      bridge
    end

    # The three observables that distinguish a drain from a hard release.
    # `state` is the row; `compilable` is what the topology compiler emits;
    # `dependent_resolves` is whether a VM being provisioned on this host
    # can still be told which bridge to attach to.
    def release_outcome(bridge, host)
      row = ::Sdwan::HostBridge.find(bridge.id)
      {
        state: row.state,
        compilable: ::Sdwan::HostBridge.for_host(host).compilable.exists?(id: row.id),
        dependent_resolves: ::Sdwan::HostBridgeResolver.bridge_present?(host)
      }
    end

    def rest_release(bridge, force: nil)
      if force.nil?
        delete "/api/v1/system/sdwan/host_bridges/#{bridge.id}", headers: manager_headers
      else
        delete "/api/v1/system/sdwan/host_bridges/#{bridge.id}",
               params: { force: force }.to_json,
               headers: manager_headers.merge("Content-Type" => "application/json")
      end
    end

    def mcp_release(bridge, force: nil)
      args = { action: "system_sdwan_release_host_bridge", id: bridge.id }
      args[:force] = force unless force.nil?
      mcp_tool.execute(params: args)
    end

    it "drains on BOTH surfaces when no force is given, and the dependents survive" do
      auto_approve_policy!
      rest_host = fresh_host("rest-default")
      mcp_host  = fresh_host("mcp-default")
      rest_bridge = active_bridge_on(rest_host)
      mcp_bridge  = active_bridge_on(mcp_host)

      rest_release(rest_bridge)
      mcp_release(mcp_bridge)

      drained = { state: "draining", compilable: true, dependent_resolves: true }
      expect(release_outcome(rest_bridge, rest_host)).to eq(drained),
                                                         "REST hard-released a bridge the agent surface would have drained"
      expect(release_outcome(mcp_bridge, mcp_host)).to eq(drained)
    end

    it "hard-releases on BOTH surfaces when force: true is given, and the dependents go" do
      auto_approve_policy!
      rest_host = fresh_host("rest-forced")
      mcp_host  = fresh_host("mcp-forced")
      rest_bridge = active_bridge_on(rest_host)
      mcp_bridge  = active_bridge_on(mcp_host)

      rest_release(rest_bridge, force: true)
      mcp_release(mcp_bridge, force: true)

      forced = { state: "removed", compilable: false, dependent_resolves: false }
      expect(release_outcome(rest_bridge, rest_host)).to eq(forced)
      expect(release_outcome(mcp_bridge, mcp_host)).to eq(forced)
    end

    # The two properties above stated as one: whatever a caller passes, the
    # surface they happen to be holding must not change the answer — AND the
    # two answers must actually differ from each other, so a regime that
    # forced (or drained) everything cannot pass by being uniformly wrong.
    it "answers identically on both surfaces for the same input, and the two inputs differ" do
      auto_approve_policy!

      outcomes = [ [ :default, nil ], [ :forced, true ] ].to_h do |label, force|
        rest_host = fresh_host("pair-rest-#{label}")
        mcp_host  = fresh_host("pair-mcp-#{label}")
        rest_bridge = active_bridge_on(rest_host)
        mcp_bridge  = active_bridge_on(mcp_host)

        rest_release(rest_bridge, force: force)
        mcp_release(mcp_bridge, force: force)

        [ label, { rest: release_outcome(rest_bridge, rest_host),
                   mcp:  release_outcome(mcp_bridge, mcp_host) } ]
      end

      expect(outcomes[:default][:rest]).to eq(outcomes[:default][:mcp]),
                                           "the two surfaces disagree about an unforced release"
      expect(outcomes[:forced][:rest]).to eq(outcomes[:forced][:mcp]),
                                          "the two surfaces disagree about a forced release"
      expect(outcomes[:default][:rest]).not_to eq(outcomes[:forced][:rest]),
                                               "force made no difference at all — the oracle is vacuous"
      expect(outcomes[:default][:rest][:state]).to eq("draining")
      expect(outcomes[:forced][:rest][:state]).to eq("removed")
    end
  end
end
