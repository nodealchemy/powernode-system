# frozen_string_literal: true

require "rails_helper"

# APO-4 (DR-1) — the first DISASTER-RECOVERY lane.
#
# Every verb this composes already existed SEPARATELY: pool acquisition
# (System::InstancePoolService#acquire!), volume attach/detach
# (System::VolumeManagementService), SDWAN enrolment (Sdwan::PeerEnroller),
# the VIP holder set (Sdwan::VirtualIp) and the provider terminate
# (System::ProvisioningService.terminate_instance). NOTHING composed them, so
# "this instance is unrecoverable" ended in a runbook a person walked by hand
# while the fleet ran short an instance.
#
# The oracles below are the composition's contract:
#   1. the ADDITIVE half applies as one unit (acquire → volumes → sdwan → vip)
#   2. the REAP is a SEPARATE approval on its own action_category, so a replace
#      that auto-applies never terminates anything
#   3. every step is IDEMPOTENT on operation_id, keyed off the FleetEvent it
#      writes — a re-drive after a partial run must not acquire a SECOND
#      replacement out of the pool
RSpec.describe System::Ai::Skills::ReplaceInstanceExecutor, type: :service do
  let(:account)                { create(:account) }
  let(:node_template)          { create(:system_node_template, account: account) }
  let(:provider_region)        { create(:system_provider_region) }
  let(:provider_instance_type) { create(:system_provider_instance_type) }

  let(:pool) do
    System::InstancePool.create!(
      account: account, node_template: node_template, name: "dr-pool",
      target_size: 2, min_size: 1, max_size: 4, lifecycle_class: "ephemeral",
      status: "active", provider_region: provider_region,
      provider_instance_type: provider_instance_type
    )
  end

  def pool_member(pool_state:, status:)
    node = create(:system_node, account: account, node_template: node_template)
    create(:system_node_instance,
           node: node, name: "m-#{SecureRandom.hex(3)}", variety: "cloud",
           status: status, provider_region: provider_region,
           provider_instance_type: provider_instance_type,
           instance_pool_id: pool.id, pool_state: pool_state,
           pool_warming_started_at: 5.minutes.ago)
  end

  # The instance the sensor classified unrecoverable — a CLAIMED pool member
  # whose VM is terminal at the provider.
  let!(:failed) { pool_member(pool_state: "claimed", status: "error") }
  # The warm spare the DR lane is supposed to reach for.
  let!(:spare)  { pool_member(pool_state: "ready",   status: "running") }

  let!(:volume) do
    create(:system_provider_volume, :attached,
           account: account, provider_region: provider_region, node_instance: failed)
  end

  let(:network)  { create(:sdwan_network, account: account) }
  let!(:old_peer) do
    create(:sdwan_peer, :active, account: account, network: network, node_instance: failed)
  end
  let!(:vip) do
    create(:sdwan_virtual_ip, network: network, account: account,
                              holder_peer_ids: [ old_peer.id ], state: "active")
  end

  # Mock provider — the volume + instance verbs are provider-side, and the DR
  # lane must not depend on a real cloud to be exercised.
  let(:provider) { instance_double(System::Providers::MockProvider, provider_type: "mock") }

  before do
    allow(System::Providers::Registry).to receive(:for_volume).and_return(provider)
    allow(System::Providers::Registry).to receive(:for_instance).and_return(provider)
    allow(provider).to receive(:detach_volume).and_return({ success: true })
    allow(provider).to receive(:attach_volume).and_return({ success: true, device: "/dev/sdf" })
    allow(provider).to receive(:terminate_instance).and_return({ success: true })
  end

  def run(operation_id: "op-1", **extra)
    described_class.new(account: account, agent: nil, user: nil)
                   .execute(gated: true, instance_id: failed.id,
                            operation_id: operation_id, **extra)
  end

  describe "the additive half" do
    it "composes pool acquisition, volume reattach, SDWAN re-enrolment and the VIP move" do
      result = run

      expect(result[:success]).to be(true), "executor failed: #{result[:error]}"
      data = result[:data]

      # 1. pooled replacement
      expect(data[:replacement_instance_id]).to eq(spare.id)
      expect(spare.reload.pool_state).to eq("claimed")

      # 2. volumes follow the workload
      expect(volume.reload.node_instance_id).to eq(spare.id)
      expect(data[:reattached_volume_ids]).to eq([ volume.id ])

      # 3. the replacement is re-enrolled on every network the dead one was on
      new_peer = Sdwan::Peer.find_by(sdwan_network_id: network.id, node_instance_id: spare.id)
      expect(new_peer).to be_present
      expect(data[:enrolled_peer_ids]).to eq([ new_peer.id ])

      # 4. the VIP moves to the replacement's peer rather than staying pinned
      #    to a peer whose instance no longer exists
      expect(vip.reload.holder_peer_ids).to eq([ new_peer.id ])
      expect(data[:moved_virtual_ip_ids]).to eq([ vip.id ])
    end

    it "writes one FleetEvent per step, stamped with the operation_id" do
      run(operation_id: "op-events")

      kinds = System::FleetEvent
                .where(account_id: account.id)
                .where("payload->>'operation_id' = ?", "op-events")
                .pluck(:kind)

      expect(kinds).to include(
        "system.instance_replace.acquire_replacement",
        "system.instance_replace.reattach_volumes",
        "system.instance_replace.reenrol_sdwan",
        "system.instance_replace.move_vips"
      )
    end
  end

  describe "the reap, which is a SEPARATE approval" do
    it "leaves the failed instance ALIVE when the caller does not ask for a reap" do
      result = run

      expect(result.dig(:data, :reaped)).to be(false)
      expect(provider).not_to have_received(:terminate_instance)
      expect(failed.reload.status).to eq("error")
    end

    it "parks its own approval on system.instance_reap instead of terminating inline" do
      result = run(reap: true)

      expect(result[:success]).to be(true), "executor failed: #{result[:error]}"
      expect(result.dig(:data, :reaped)).to be(false)
      expect(result.dig(:data, :reap_decision)).to eq("pending")
      expect(provider).not_to have_received(:terminate_instance)

      op = Ai::DeferredOperation.where(account: account).order(:created_at).last
      expect(op.action_category).to eq("system.instance_reap")
      # The parked row names the REAP executor, not this one: the terminate is
      # gated on its own category on every path, including a retune of
      # system.instance_replace to a proceeding verb.
      expect(op.executor_class).to eq(System::Ai::Skills::ReapInstanceExecutor.name)
    end
  end

  describe "idempotency on operation_id" do
    it "does not acquire a SECOND replacement when the same operation is re-driven" do
      first  = run(operation_id: "op-replay")
      second = run(operation_id: "op-replay")

      expect(first.dig(:data, :replacement_instance_id)).to eq(spare.id)
      expect(second.dig(:data, :replacement_instance_id)).to eq(spare.id)
      expect(second.dig(:data, :replayed_steps)).to include("acquire_replacement")

      # The pool had exactly one ready member; a non-idempotent re-drive would
      # have raised NoReadyMembers (or claimed a second one had there been one).
      expect(pool.node_instances.where(pool_state: "claimed").count).to eq(2) # failed + spare
    end
  end

  # SELF-REVIEW FINDINGS. All three are about what a RE-DRIVE does, which is
  # the whole point of keying steps on an operation_id — a ledger that makes
  # transient failures permanent, or that refuses to finish a replace it
  # already started, is worse than no ledger.
  describe "a re-drive repairs what a partial run left behind" do
    it "does not record a step that FAILED, so the next drive retries it" do
      allow(provider).to receive(:detach_volume).and_return({ success: false, error: "provider timeout" })

      first = run(operation_id: "op-partial")
      expect(first.dig(:data, :partial)).to be(true)
      expect(first.dig(:data, :reattached_volume_ids)).to be_empty
      expect(volume.reload.node_instance_id).to eq(failed.id)

      # Nothing recorded the failed step, so it is not replayed away.
      recorded = System::FleetEvent
                   .where(account_id: account.id, kind: "system.instance_replace.reattach_volumes")
                   .where("payload->>'operation_id' = ?", "op-partial")
      expect(recorded).to be_empty

      # The provider recovers; the same operation_id is re-driven.
      allow(provider).to receive(:detach_volume).and_return({ success: true })
      second = run(operation_id: "op-partial")

      expect(second.dig(:data, :reattached_volume_ids)).to eq([ volume.id ])
      expect(volume.reload.node_instance_id).to eq(spare.id)
      expect(second.dig(:data, :partial)).to be(false)
      # ...and it did NOT acquire a second member to do it.
      expect(second.dig(:data, :replayed_steps)).to include("acquire_replacement")
    end

    it "lets an in-flight operation finish even once the replacement bound is reached" do
      # The acquire for THIS operation is already on the ledger, so finishing
      # it consumes no new pool capacity. Saturate the window with other
      # replaces and re-drive: the bound must gate NEW acquisitions only.
      run(operation_id: "op-inflight")

      System::Fleet::DecisionEngine # keep the constant resolved for clarity
      3.times do |i|
        System::FleetEvent.create!(
          account_id: account.id, kind: "system.instance_replace.acquire_replacement",
          severity: "low", emitted_at: Time.current,
          payload: { "operation_id" => "other-#{i}", "step" => "acquire_replacement" }
        )
      end

      redrive = run(operation_id: "op-inflight")

      expect(redrive[:success]).to be(true), "re-drive was refused: #{redrive[:error]}"
      expect(redrive.dig(:data, :replacement_instance_id)).to eq(spare.id)
    end

    it "still refuses a NEW replace once the bound is reached" do
      4.times do |i|
        System::FleetEvent.create!(
          account_id: account.id, kind: "system.instance_replace.acquire_replacement",
          severity: "low", emitted_at: Time.current,
          payload: { "operation_id" => "other-#{i}", "step" => "acquire_replacement" }
        )
      end

      result = run(operation_id: "op-fresh")

      expect(result[:success]).to be(false)
      expect(result[:error]).to match(/Replacement bound reached/)
      expect(spare.reload.pool_state).to eq("ready")
    end
  end

  describe "the dry-run preview" do
    it "reports whether the pool can actually supply a replacement" do
      preview = run(operation_id: "op-plan", dry_run: true)

      expect(preview[:success]).to be(true), "preview failed: #{preview[:error]}"
      expect(preview.dig(:data, :pool_ready_count)).to eq(1)
      expect(preview.dig(:data, :pool_id)).to eq(pool.id)
      expect(preview.dig(:data, :would_reattach_volume_ids)).to eq([ volume.id ])
    end

    it "says so when the pool is EMPTY, instead of a preview that hides the refusal" do
      spare.update!(pool_state: "draining")

      preview = run(operation_id: "op-plan-empty", dry_run: true)

      expect(preview[:success]).to be(true)
      expect(preview.dig(:data, :pool_ready_count)).to eq(0)
      expect(preview.dig(:data, :blocked)).to be(true)
      expect(preview.dig(:data, :note)).to match(/no ready members/i)
    end
  end

  describe "the lane it is bound to" do
    it "is routed from the APO-2b unrecoverable signal" do
      binding = System::Fleet::DecisionEngine::SIGNAL_BINDINGS["system.instance_unrecoverable"]

      expect(binding[:skill]).to eq(described_class)
      expect(binding[:action_category]).to eq("system.instance_replace")
    end

    it "declares the reap category so an operator can tune it separately (Capacity Manager since HIER-P2DECL)" do
      expect(System::Governance::PolicyDeclarations::CAPACITY_MANAGER_POLICIES)
        .to include("system.instance_reap" => "require_approval")
      expect(System::Governance::PolicyDeclarations.owner_of("system.instance_reap")).to eq("capacity-manager")
    end
  end

  # ── INDEPENDENT REVIEW FINDINGS (IMP-555db48d41f1, Finalize) ───────────
  #
  # Each example below is one reviewed defect in the first implementation.
  # They are grouped by the promise the code made and did not keep, because
  # every one of them is a comment that was TRUE of the mechanism it
  # described and FALSE of the path an operator actually reaches.

  describe "a step whose INPUT came from a failed predecessor" do
    # The ledger's stated safety property — "leaving a failed step unrecorded
    # is safe because each leg is idempotent by its own query" — holds for the
    # volume and enrol legs, which re-derive what is still stranded. It does
    # NOT hold for the VIP move, whose input is the ENROL STEP'S RETURN VALUE.
    # With no peer map to substitute, move_vips! reports no errors and gets
    # recorded, and the re-drive that finally mints the peers replays the
    # empty move forever — the VIP stays pinned to a peer row that disappears
    # with the reap.
    it "does not record the VIP move when the enrolment it depends on failed" do
      allow(Sdwan::PeerEnroller).to receive(:call).and_raise(StandardError, "sdwan control plane down")

      first = run(operation_id: "op-vip-partial")
      expect(first.dig(:data, :moved_virtual_ip_ids)).to be_empty
      expect(vip.reload.holder_peer_ids).to eq([ old_peer.id ])

      recorded = System::FleetEvent
                   .where(account_id: account.id, kind: "system.instance_replace.move_vips")
                   .where("payload->>'operation_id' = ?", "op-vip-partial")
      expect(recorded).to be_empty,
        "the VIP move was recorded on the ledger even though its peer map came from a failed enrol"

      # SDWAN recovers and the same operation is re-driven.
      allow(Sdwan::PeerEnroller).to receive(:call).and_call_original
      second = run(operation_id: "op-vip-partial")

      new_peer = Sdwan::Peer.find_by(sdwan_network_id: network.id, node_instance_id: spare.id)
      expect(new_peer).to be_present
      expect(vip.reload.holder_peer_ids).to eq([ new_peer.id ])
      expect(second.dig(:data, :moved_virtual_ip_ids)).to eq([ vip.id ])
    end
  end

  describe "the DESTRUCTIVE half is unreachable under the additive approval" do
    # `reap_only` used to be a declared, externally passable input on THIS
    # class, whose gate resolves system.instance_replace — so any caller that
    # reached the replace (a composed plan, or a retune of the replace
    # category to a proceeding verb) could terminate an instance under an
    # approval whose card says "replace". The terminate now lives in an
    # executor of its own whose action_category IS system.instance_reap.
    it "terminates nothing when a caller passes reap_only to the replace" do
      result = run(operation_id: "op-reap-only", reap_only: true)

      expect(result[:success]).to be(true), "executor failed: #{result[:error]}"
      expect(provider).not_to have_received(:terminate_instance)
      expect(failed.reload.status).to eq("error")
    end

    it "hands the reap to an executor whose OWN action_category is the reap category" do
      expect(System::Ai::Skills::ReapInstanceExecutor.action_category).to eq("system.instance_reap")
      expect(described_class.action_category).to eq("system.instance_replace")
    end
  end

  describe "the replacement peer inherits the failed peer's routing" do
    # Sdwan::PeerEnroller.call(network:, node_instance:) with no options mints
    # a peer carrying SCHEMA DEFAULTS: not publicly reachable, no advertised
    # LAN subnets, not a BGP route-reflector client, listen_port 51820. A hub
    # replaced by a spoke is a silent topology change, and the VIP is then
    # moved onto that degraded peer.
    it "carries lan_subnets, listen_port and the route-reflector flag across" do
      old_peer.update!(lan_subnets: [ "10.77.0.0/24" ], listen_port: 51_999,
                       bgp_route_reflector_client: true, capabilities: { "role" => "edge" })

      run(operation_id: "op-attrs")

      new_peer = Sdwan::Peer.find_by(sdwan_network_id: network.id, node_instance_id: spare.id)
      expect(new_peer).to be_present
      expect(new_peer.lan_subnets).to eq([ "10.77.0.0/24" ])
      expect(new_peer.listen_port).to eq(51_999)
      expect(new_peer.bgp_route_reflector_client).to be(true)
      expect(new_peer.capabilities["role"]).to eq("edge")
    end

    it "keeps a publicly reachable hub reachable rather than silently demoting it" do
      old_peer.update!(publicly_reachable: true, endpoint_host_v6: "fd00:abcd:1::9",
                       endpoint_port: 51_820)

      run(operation_id: "op-hub")

      new_peer = Sdwan::Peer.find_by(sdwan_network_id: network.id, node_instance_id: spare.id)
      expect(new_peer.publicly_reachable).to be(true)
      expect(new_peer.endpoint_port).to eq(51_820)
    end
  end

  describe "a re-classified failure of the SAME instance" do
    # The operation_id the lane passes is the signal FINGERPRINT, and the
    # sensor builds it as "instance_unrecoverable:<id>:<reason>" with the
    # reason re-derived every tick. A dead instance that reclassifies
    # (host_unreachable while the provider connection is down, then
    # provider_terminal once it recovers) therefore arrives under a NEW
    # operation_id — and the ledger, keyed on operation_id alone, would let it
    # claim a SECOND warm member for a replace that already happened.
    it "adopts the replacement it already claimed instead of claiming another" do
      # A second warm spare, so a non-idempotent second acquire would succeed.
      pool_member(pool_state: "ready", status: "running")

      first  = run(operation_id: "instance_unrecoverable:#{failed.id}:host_unreachable")
      second = run(operation_id: "instance_unrecoverable:#{failed.id}:provider_terminal")

      expect(first.dig(:data, :replacement_instance_id)).to eq(spare.id)
      expect(second[:success]).to be(true), "re-classified drive failed: #{second[:error]}"
      expect(second.dig(:data, :replacement_instance_id)).to eq(spare.id)
      expect(second.dig(:data, :replayed_steps)).to include("acquire_replacement")
      # failed + spare, and nothing else — the second ready member is untouched.
      expect(pool.node_instances.where(pool_state: "claimed").count).to eq(2)
    end
  end

  describe "the claim and its ledger row commit together" do
    # #record_step! is deliberately unrescued — the event IS the ledger — but a
    # raise cannot un-claim a pool member that InstancePoolService#acquire!
    # already committed in a transaction of its own. Without one transaction
    # around both, a failed ledger write leaves a member claimed by an
    # operation nothing recorded, and the next drive claims a second.
    it "rolls the pool claim back when the acquire's ledger write fails" do
      executor = described_class.new(account: account, agent: nil, user: nil)
      allow(executor).to receive(:record_step!).and_raise(StandardError, "ledger write failed")

      result = executor.execute(gated: true, instance_id: failed.id, operation_id: "op-ledger")

      expect(result[:success]).to be(false)
      expect(spare.reload.pool_state).to eq("ready")
    end
  end

  describe "the preview answers CAN THIS RUN AT ALL" do
    it "reports the replacement bound rather than planning a run that will be refused" do
      4.times do |i|
        System::FleetEvent.create!(
          account_id: account.id, kind: "system.instance_replace.acquire_replacement",
          severity: "low", emitted_at: Time.current,
          payload: { "operation_id" => "bound-#{i}", "step" => "acquire_replacement" }
        )
      end

      preview = run(operation_id: "op-plan-bound", dry_run: true)

      expect(preview[:success]).to be(true)
      expect(preview.dig(:data, :blocked)).to be(true)
      expect(preview.dig(:data, :note)).to match(/bound reached/i)
    end
  end

  describe "the autonomy lane asks for the reap approval" do
    # FLEET_SENSORS.md tells the reader the reap "is gated separately on
    # system.instance_reap", which implies an operator is eventually asked.
    # The binding's input_mapper is the only thing that can ask.
    it "maps the unrecoverable signal onto a replace that requests the reap" do
      binding = System::Fleet::DecisionEngine::SIGNAL_BINDINGS["system.instance_unrecoverable"]
      mapped  = binding[:input_mapper].call(
        { fingerprint: "instance_unrecoverable:#{failed.id}:provider_terminal",
          payload: { "instance_id" => failed.id, "reason" => "provider_terminal" } }
      )

      expect(mapped[:instance_id]).to eq(failed.id)
      expect(mapped[:operation_id]).to eq("instance_unrecoverable:#{failed.id}:provider_terminal")
      expect(mapped[:reap]).to be(true),
        "the lane never asks for the reap, so the second approval is never parked"
    end
  end

end
