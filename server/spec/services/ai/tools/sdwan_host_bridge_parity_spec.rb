# frozen_string_literal: true

require "rails_helper"

# IMP-53a5c597ec8c — the host bridge verbs were split across two surfaces
# with almost no overlap in the middle:
#
#   REST  (host_bridges_controller) — index, show, destroy
#   MCP   (Ai::Tools::SdwanTool)    — create, list, activate, release
#
# Two consequences, both closed by this task. The SEMANTIC one lives in
# spec/requests/api/v1/system/sdwan/host_bridges_spec.rb ("release
# force/drain parity across REST and MCP"): the two surfaces named the same
# act and disagreed about whether it honored the draining grace window.
#
# The MATRIX half is here. `get` is the missing MCP read: an agent holding
# SdwanTool could list every bridge in the account but never fetch one by
# id, so answering "what state is THIS bridge in" — the question every
# activate/release decision turns on — meant paging the whole account's
# list and filtering client-side. The console has had that read since the
# controller shipped.
#
# The REST half of the matrix (create + activate) is exercised in the
# request spec, since those are gated writes and their oracle is what
# reaches the database, not what the tool returns.
RSpec.describe "SdwanTool host bridge verb parity (IMP-53a5c597ec8c)" do
  let(:account) { create(:account) }
  let(:tool)    { Ai::Tools::SdwanTool.new(account: account, internal: true) }

  def call(action, **rest)
    tool.execute(params: { action: action }.merge(rest))
  end

  # Fetch helpers are `def`, not `let` — each probes CURRENT state, and a
  # memoized probe that answered before an arm ran would assert nothing.
  def host_instance
    create(:system_node_instance, account: account)
  end

  def bridge_on(host, state: "active")
    bridge = ::Sdwan::HostBridgeAllocator.allocate!(host: host, kind: "linux")
    bridge.update!(state: state)
    bridge
  end

  describe "system_sdwan_get_host_bridge" do
    it "is advertised, permissioned as a read, and wired to SdwanTool" do
      expect(::Ai::Tools::SdwanTool.action_definitions.keys)
        .to include("system_sdwan_get_host_bridge")

      permissions = ::Ai::Tools::SdwanTool.const_get(:ACTION_PERMISSIONS)
      expect(permissions["system_sdwan_get_host_bridge"]).to eq("system.sdwan.host_bridges.read"),
                                                             "a single-row read must not carry a manage permission"

      expect(::Ai::Tools::PlatformApiToolRegistry::TOOLS["system_sdwan_get_host_bridge"])
        .to eq("Ai::Tools::SdwanTool")
    end

    it "returns the full row for one bridge by id" do
      host = host_instance
      bridge = bridge_on(host)

      r = call("system_sdwan_get_host_bridge", id: bridge.id)

      expect(r[:success]).to be true
      payload = r[:data][:host_bridge]
      expect(payload[:id]).to eq(bridge.id)
      expect(payload[:node_instance_id]).to eq(host.id)
      expect(payload[:bridge_name]).to eq(bridge.bridge_name)
      expect(payload[:state]).to eq("active")
      expect(payload[:kind]).to eq("linux")
    end

    # The whole reason this verb has to exist: the state a release or
    # activate decision turns on has to be readable for ONE row.
    it "reflects the state the row is actually in, not the state it was created in" do
      host = host_instance
      bridge = bridge_on(host, state: "active")

      ::Sdwan::HostBridgeAllocator.release!(bridge)

      expect(call("system_sdwan_get_host_bridge", id: bridge.id)[:data][:host_bridge][:state])
        .to eq("draining")
    end

    # Not compared against `list` — both arms call the same
    # serialize_host_bridge, so equality between them is a tautology that
    # cannot fail. What is worth pinning is that the read carries the fields
    # an activate/release decision needs, against the DATABASE row.
    it "carries the lifecycle fields a release decision turns on" do
      host = host_instance
      bridge = bridge_on(host)
      bridge.update!(draining_at: 2.hours.ago)
      row = ::Sdwan::HostBridge.find(bridge.id)

      payload = call("system_sdwan_get_host_bridge", id: bridge.id)[:data][:host_bridge]

      expect(payload[:short_id]).to eq(row.short_id)
      expect(payload[:draining_at]).to eq(row.draining_at.iso8601)
      expect(payload[:applied_at]).to eq(row.applied_at&.iso8601)
      expect(payload[:kind]).to eq(row.kind)
    end

    it "refuses a bridge belonging to another account" do
      other_account = create(:account)
      other_host = create(:system_node_instance, account: other_account)
      foreign = ::Sdwan::HostBridgeAllocator.allocate!(host: other_host, kind: "linux", account: other_account)

      r = call("system_sdwan_get_host_bridge", id: foreign.id)

      expect(r[:success]).to be false
    end
  end

  # The force/drain default is declared ONCE, on the executor, and read by
  # every surface that names the verb. These examples pin the declaration
  # itself so a surface that reimplemented the coercion inline would not be
  # able to drift from it silently.
  describe "Sdwan::Executors::ReleaseHostBridge.force?" do
    it "defaults to DRAIN when the caller expresses no opinion" do
      expect(::Sdwan::Executors::ReleaseHostBridge::DEFAULT_FORCE).to be(false)
      expect(::Sdwan::Executors::ReleaseHostBridge.force?(nil)).to be(false)
      expect(::Sdwan::Executors::ReleaseHostBridge.force?("")).to be(false)
    end

    # REST params arrive as STRINGS, MCP params as real booleans. One
    # coercion answers both, so ?force=true and force: true mean the same
    # thing on either surface.
    it "reads both the REST string form and the MCP boolean form" do
      expect(::Sdwan::Executors::ReleaseHostBridge.force?(true)).to be(true)
      expect(::Sdwan::Executors::ReleaseHostBridge.force?("true")).to be(true)
      expect(::Sdwan::Executors::ReleaseHostBridge.force?("1")).to be(true)
      expect(::Sdwan::Executors::ReleaseHostBridge.force?(false)).to be(false)
      expect(::Sdwan::Executors::ReleaseHostBridge.force?("false")).to be(false)
      expect(::Sdwan::Executors::ReleaseHostBridge.force?("0")).to be(false)
    end

    # The FAILURE DIRECTION is the point. ActiveModel::Type::Boolean has a
    # closed FALSE_VALUES set and casts everything outside it to true, so
    # each of these would have selected the DESTRUCTIVE arm. On a verb whose
    # forced branch tears a bridge off a live host, an unparseable input must
    # fall to the default — and the MCP surface is driven by a model, which
    # makes "no" and "False" entirely plausible inputs.
    it "falls back to the default on any value it cannot parse, never to force" do
      [ "False", "no", "No", "n", "off ", " ", [], {}, "maybe", 2 ].each do |raw|
        expect(::Sdwan::Executors::ReleaseHostBridge.force?(raw)).to be(false),
                                                                    "#{raw.inspect} selected the destructive arm"
      end
    end
  end

  # IMP-53a5c597ec8c — two states where the DRAIN edge is wrong, fixed in
  # the allocator so every surface inherits the guard rather than one call
  # site holding it.
  describe "Sdwan::HostBridgeAllocator#release! state guards" do
    def state_of(bridge)
      ::Sdwan::HostBridge.find(bridge.id).state
    end

    def compilable?(bridge)
      ::Sdwan::HostBridge.where(id: bridge.id).compilable.exists?
    end

    # The sharp one. `pending` is NOT in `compilable`, but `draining` IS, and
    # start_drain accepts from: pending — so draining a never-applied bridge
    # would ADD it to the compiler's emit set and the agent would CREATE the
    # bridge the caller just asked to release. Deleting would provision.
    it "removes a never-applied pending bridge outright instead of draining it into existence" do
      host = host_instance
      bridge = ::Sdwan::HostBridgeAllocator.allocate!(host: host, kind: "linux")
      expect(state_of(bridge)).to eq("pending")
      expect(compilable?(bridge)).to be(false)

      ::Sdwan::HostBridgeAllocator.release!(bridge)

      expect(state_of(bridge)).to eq("removed")
      expect(compilable?(bridge)).to be(false),
                                     "releasing a pending bridge made the compiler start emitting it"
    end

    # start_drain has no edge from removed and the model is
    # whiny_transitions: false, so this used to write nothing while the
    # caller was told the release succeeded.
    it "leaves an already-removed bridge alone rather than silently no-opping mid-transition" do
      host = host_instance
      bridge = ::Sdwan::HostBridgeAllocator.allocate!(host: host, kind: "linux")
      bridge.mark_active!
      ::Sdwan::HostBridgeAllocator.release!(bridge, force: true)
      removed_at = ::Sdwan::HostBridge.find(bridge.id).removed_at

      ::Sdwan::HostBridgeAllocator.release!(bridge)

      expect(state_of(bridge)).to eq("removed")
      expect(::Sdwan::HostBridge.find(bridge.id).removed_at).to eq(removed_at)
    end

    it "still drains an ACTIVE bridge, which is the case the window exists for" do
      host = host_instance
      bridge = ::Sdwan::HostBridgeAllocator.allocate!(host: host, kind: "linux")
      bridge.mark_active!

      ::Sdwan::HostBridgeAllocator.release!(bridge)

      expect(state_of(bridge)).to eq("draining")
      expect(compilable?(bridge)).to be(true)
    end
  end
end
