# frozen_string_literal: true

require "rails_helper"

# Phase-0 hardening specs for the provision happy-path's failure + retry
# semantics. The provider adapter is stubbed so we exercise ProvisioningService's
# own state-management (no real cloud calls).
RSpec.describe System::ProvisioningService do
  let(:account)       { create(:account) }
  let(:node)          { create(:system_node, account: account) }
  let(:region)        { create(:system_provider_region) }
  let(:instance_type) { create(:system_provider_instance_type) }
  let(:adapter)       { instance_double("System::Providers::BaseProvider", provider_type: "mock", supports?: true) }

  before do
    allow(System::Providers::Registry).to receive(:for_node).and_return(adapter)
  end

  def provision(operation_id: nil, options: {})
    described_class.provision_instance(
      node: node,
      provider_region_id: region.id,
      provider_instance_type_id: instance_type.id,
      operation_id: operation_id,
      options: options
    )
  end

  # Audit F4-06 — capability gate: refuse before creating the NodeInstance
  # row when the adapter has no instance surface.
  describe "capability gate" do
    it "returns a structured error without creating an instance row when unsupported" do
      allow(adapter).to receive(:supports?).with(:instances).and_return(false)

      result = nil
      expect { result = provision }.not_to change(System::NodeInstance, :count)

      expect(result.success?).to be(false)
      expect(result.error).to match(/does not support instance/i)
    end
  end

  describe "failure recovery — no orphaned :pending instances" do
    it "transitions the instance to :error when the provider raises a ProviderError" do
      allow(adapter).to receive(:create_instance)
        .and_raise(System::Providers::BaseProvider::ProviderError, "cloud exploded")

      result = provision

      expect(result.success?).to be(false)
      expect(System::NodeInstance.where(node: node, status: "pending")).to be_empty
      instance = System::NodeInstance.where(node: node).order(:created_at).last
      expect(instance).not_to be_nil
      expect(instance.status).to eq("error")
    end

    it "transitions the instance to :error on an unexpected StandardError" do
      allow(adapter).to receive(:create_instance).and_raise(StandardError, "kaboom")

      provision

      expect(System::NodeInstance.where(node: node, status: "pending")).to be_empty
      expect(System::NodeInstance.where(node: node).order(:created_at).last.status).to eq("error")
    end

    it "transitions the instance to :error when the provider reports success: false" do
      allow(adapter).to receive(:create_instance).and_return(success: false, error: "quota exceeded")

      result = provision

      expect(result.success?).to be(false)
      expect(System::NodeInstance.where(node: node, status: "pending")).to be_empty
      expect(System::NodeInstance.where(node: node).order(:created_at).last.status).to eq("error")
    end

    it "refuses a provider 'success' that carries no cloud_instance_id (F1 phantom shape)" do
      # dryrun 20260809a: a row that reaches a live status with no provider
      # identity is a phantom nothing can sync, reap, or terminate. Whatever
      # the adapter thought it did, without an id the platform must treat the
      # provision as failed — loudly — not mint a running instance.
      allow(adapter).to receive(:create_instance)
        .and_return(success: true, cloud_instance_id: nil, status: "running")

      result = provision

      expect(result.success?).to be(false)
      expect(result.error).to match(/cloud_instance_id/i)
      expect(System::NodeInstance.where(node: node).order(:created_at).last.status).to eq("error")
    end
  end

  # Cloud-resource leak (IMP-f21484318518): the cloud VM is created before the
  # row is updated with its id. If a post-create step (e.g. update!) raises, the
  # rescue only marks the row :error — the just-created, billable VM is left
  # running with its id never persisted, so the reaper can't reclaim it. The fix
  # captures the cloud id at create time and best-effort terminates it on failure.
  describe "compensating rollback — orphaned cloud VM on post-create failure" do
    it "terminates the just-created cloud instance when a post-create step (update!) raises" do
      allow(adapter).to receive(:create_instance)
        .and_return(success: true, cloud_instance_id: "i-orphan-1", status: "running")
      # The cloud VM is live, but persisting its id onto the row fails.
      allow_any_instance_of(System::NodeInstance)
        .to receive(:update!).and_raise(StandardError, "db write failed")

      # Compensating action: the live cloud instance must be terminated by id.
      expect(adapter).to receive(:terminate_instance).with("i-orphan-1").and_return(success: true)

      result = provision

      # ...and the row is still driven to the terminal :error state.
      expect(result.success?).to be(false)
      expect(System::NodeInstance.where(node: node, status: "pending")).to be_empty
      expect(System::NodeInstance.where(node: node).order(:created_at).last.status).to eq("error")
    end

    it "does not mask the original error when the compensating terminate itself fails" do
      allow(adapter).to receive(:create_instance)
        .and_return(success: true, cloud_instance_id: "i-orphan-2", status: "running")
      allow_any_instance_of(System::NodeInstance)
        .to receive(:update!).and_raise(StandardError, "original failure")
      allow(adapter).to receive(:terminate_instance)
        .and_raise(StandardError, "terminate also failed")

      result = provision

      expect(result.success?).to be(false)
      expect(result.error).to eq("original failure")
      expect(System::NodeInstance.where(node: node).order(:created_at).last.status).to eq("error")
    end
  end

  describe "idempotency — repeated operation_id does not duplicate" do
    before do
      allow(adapter).to receive(:create_instance)
        .and_return(success: true, cloud_instance_id: "i-123", status: "running")
    end

    it "reuses the existing instance for a repeated operation_id" do
      first  = provision(operation_id: "op-abc-123")
      second = provision(operation_id: "op-abc-123")

      expect(first.success?).to be(true)
      expect(second.success?).to be(true)
      expect(System::NodeInstance.where(node: node).count).to eq(1)
      expect(second.data[:instance].id).to eq(first.data[:instance].id)
    end

    it "creates distinct instances for distinct operation_ids" do
      provision(operation_id: "op-1")
      provision(operation_id: "op-2")

      expect(System::NodeInstance.where(node: node).count).to eq(2)
    end

    it "stamps the operation_id onto the instance config" do
      result = provision(operation_id: "op-xyz")
      expect(result.data[:instance].config["operation_id"]).to eq("op-xyz")
    end

    # F1-07: an errored instance keeps its operation_id; reusing it on retry
    # returns a dead instance (no cloud VM) that poisons fleet enrollment.
    it "does not reuse an errored instance — a retry provisions fresh" do
      allow(adapter).to receive(:create_instance)
        .and_return({ success: false, error: "quota exceeded" },
                    { success: true, cloud_instance_id: "i-456", status: "running" })

      first = provision(operation_id: "op-retry-1")
      expect(first.success?).to be(false)
      expect(first.data[:instance].status).to eq("error")

      second = provision(operation_id: "op-retry-1")

      expect(second.success?).to be(true)
      expect(second.data[:instance].id).not_to eq(first.data[:instance].id)
      expect(second.data[:instance].status).not_to eq("error")
    end
  end

  # Layer-1 fix (campaign 019f3458): TemplateApplyService previously had zero
  # callers in the real provisioning path, so a node's actual module
  # assignments never reflected its template's full closure. Wired into the
  # one choke point every provider adapter flows through.
  describe "template application (layer-1 fix — TemplateApplyService wiring)" do
    let(:node_module) { create(:system_node_module, account: account) }

    before do
      create(:system_template_module, node_template: node.node_template, node_module: node_module)
      allow(adapter).to receive(:create_instance)
        .and_return(success: true, cloud_instance_id: "i-tmpl-1", status: "running")
    end

    it "materializes NodeModuleAssignment rows from the node_template's expansion closure" do
      result = provision

      expect(result.success?).to be(true)
      expect(node.node_module_assignments.pluck(:node_module_id)).to contain_exactly(node_module.id)
    end

    it "does not fail an otherwise-successful provision when TemplateApplyService reports ok: false" do
      allow_any_instance_of(System::TemplateApplyService).to receive(:apply!)
        .and_return(System::TemplateApplyService::Result.new(
          ok: false, created: [], skipped: [], purged: [], warnings: [], errors: [ "boom" ]
        ))

      result = provision

      expect(result.success?).to be(true)
      expect(node.node_module_assignments).to be_empty
    end

    it "does not fail an otherwise-successful provision when TemplateApplyService raises" do
      allow_any_instance_of(System::TemplateApplyService).to receive(:apply!).and_raise(StandardError, "kaboom")

      result = provision

      expect(result.success?).to be(true)
    end
  end

  # Campaign 019f3458 — a template's config["boot_mode"] (e.g. "direct_kernel"
  # for the pivot-boot path) previously only reached the provider via
  # SpawnProvisioner explicitly threading it into `options`; every other
  # caller of provision_instance (e.g. pool replenishment) passed no options
  # at all, so the provider silently fell back to its own default (cloud_init
  # on Proxmox) regardless of what the template declared. build_provider_params
  # now falls back to the template's stored boot_mode, mirroring the existing
  # init_script fallthrough.
  describe "boot_mode threading (template config -> provider params)" do
    it "passes the template's config boot_mode through to the provider params" do
      node.node_template.update!(config: { "boot_mode" => "direct_kernel" })
      allow(adapter).to receive(:create_instance)
        .and_return(success: true, cloud_instance_id: "i-boot-1", status: "running")

      provision

      expect(adapter).to have_received(:create_instance)
        .with(hash_including(boot_mode: "direct_kernel"))
    end

    it "does not force a boot_mode when the template config has none" do
      expect(node.node_template.config["boot_mode"]).to be_nil
      captured = nil
      allow(adapter).to receive(:create_instance) do |params|
        captured = params
        { success: true, cloud_instance_id: "i-boot-2", status: "running" }
      end

      provision

      expect(captured).not_to have_key(:boot_mode)
    end

    it "prefers an explicit options[:boot_mode] override over the template's config" do
      node.node_template.update!(config: { "boot_mode" => "direct_kernel" })
      allow(adapter).to receive(:create_instance)
        .and_return(success: true, cloud_instance_id: "i-boot-3", status: "running")

      described_class.provision_instance(
        node: node,
        provider_region_id: region.id,
        provider_instance_type_id: instance_type.id,
        options: { boot_mode: "uefi_disk" }
      )

      expect(adapter).to have_received(:create_instance)
        .with(hash_including(boot_mode: "uefi_disk"))
    end
  end

  # RCP campaign 019f9250, P1-a prerequisite fix — build_provider_params previously
  # never threaded options[:vmid]/[:storage]/[:cidata_iso_storage] to the top-level
  # params keys ProxmoxProvider#create_vm_instance / #create_uefi_disk_vm_instance /
  # #stage_cidata_iso actually read, so a caller could never pin a specific PVE
  # VMID or storage pool (e.g. a node-local, non-shared pool) — every provision
  # silently auto-selected (cluster/nextid; first *shared* storage with the right
  # content type). Verified via code + live-cluster recon that no existing caller
  # (pool replenishment, federation spawn, MCP tools, orchestrators) ever passed
  # these options, so the regression spec below documents that the fix is
  # opt-in-only and leaves every pre-existing call shape unchanged.
  describe "placement pin threading (options[:vmid]/[:storage]/[:cidata_iso_storage] -> provider params)" do
    it "passes options[:vmid]/[:storage]/[:cidata_iso_storage] through to the provider params" do
      allow(adapter).to receive(:create_instance)
        .and_return(success: true, cloud_instance_id: "i-pin-1", status: "running")

      described_class.provision_instance(
        node: node,
        provider_region_id: region.id,
        provider_instance_type_id: instance_type.id,
        options: { vmid: 9100, storage: "local-data", cidata_iso_storage: "local" }
      )

      expect(adapter).to have_received(:create_instance)
        .with(hash_including(vmid: 9100, storage: "local-data", cidata_iso_storage: "local"))
    end

    it "pins independently — storage alone, without vmid or cidata_iso_storage" do
      captured = nil
      allow(adapter).to receive(:create_instance) do |params|
        captured = params
        { success: true, cloud_instance_id: "i-pin-2", status: "running" }
      end

      described_class.provision_instance(
        node: node,
        provider_region_id: region.id,
        provider_instance_type_id: instance_type.id,
        options: { storage: "local-data" }
      )

      expect(captured[:storage]).to eq("local-data")
      expect(captured).not_to have_key(:vmid)
      expect(captured).not_to have_key(:cidata_iso_storage)
    end

    # Regression guard: every real caller in the tree today (InstancePoolService,
    # Federation::SpawnProvisioner, agent_fleet_mission_service, system_fleet_tool,
    # platform_deployment_orchestrator, the internal nodes_controller, ...) never
    # passes vmid/storage/cidata_iso_storage — this must keep resolving exactly as
    # before (keys absent, provider adapter falls through to its own
    # cluster/nextid + first-shared-storage discovery), not merely "falsy".
    it "does not set vmid/storage/cidata_iso_storage keys when options omits them entirely" do
      captured = nil
      allow(adapter).to receive(:create_instance) do |params|
        captured = params
        { success: true, cloud_instance_id: "i-pin-3", status: "running" }
      end

      provision

      expect(captured).not_to have_key(:vmid)
      expect(captured).not_to have_key(:storage)
      expect(captured).not_to have_key(:cidata_iso_storage)
    end

    it "does not set the keys when options is passed but doesn't include them" do
      captured = nil
      allow(adapter).to receive(:create_instance) do |params|
        captured = params
        { success: true, cloud_instance_id: "i-pin-4", status: "running" }
      end

      described_class.provision_instance(
        node: node,
        provider_region_id: region.id,
        provider_instance_type_id: instance_type.id,
        options: { hostname: "unrelated-option" }
      )

      expect(captured).not_to have_key(:vmid)
      expect(captured).not_to have_key(:storage)
      expect(captured).not_to have_key(:cidata_iso_storage)
    end
  end

  describe "fleet-event observability" do
    it "emits a system.instance_provisioned event on success" do
      allow(adapter).to receive(:create_instance)
        .and_return(success: true, cloud_instance_id: "i-1", status: "running")

      provision

      ev = System::FleetEvent.where(account: account, kind: "system.instance_provisioned").last
      expect(ev).not_to be_nil
      expect(ev.severity).to eq("low")
      expect(ev.node_instance_id).to be_present
      expect(ev.source).to eq("provisioning_service")
    end

    it "emits a system.instance_provision_failed event (severity high) when the provider raises" do
      allow(adapter).to receive(:create_instance)
        .and_raise(System::Providers::BaseProvider::ProviderError, "boom")

      provision

      ev = System::FleetEvent.where(account: account, kind: "system.instance_provision_failed").last
      expect(ev).not_to be_nil
      expect(ev.severity).to eq("high")
      expect(ev.payload["error"]).to eq("boom")
    end
  end

  # Audit finding F4-02: terminating a not-yet-up instance destroyed the
  # cloud resource but left the row wedged in a non-terminal status, and a
  # provider-side NotFound made retries error instead of finalizing.
  describe "#terminate_instance" do
    let(:instance) do
      create(:system_node_instance, node: node, status: "starting",
             config: { "cloud_instance_id" => "i-123" })
    end

    before do
      allow(System::Providers::Registry).to receive(:for_instance).and_return(adapter)
    end

    def terminate
      described_class.terminate_instance(instance: instance)
    end

    it "terminates an instance still in :starting" do
      allow(adapter).to receive(:terminate_instance).with("i-123").and_return({ success: true })

      result = terminate

      expect(result.success?).to be(true)
      expect(instance.reload.status).to eq("terminated")
    end

    it "treats a provider NotFound result as already-terminated (idempotent retry)" do
      allow(adapter).to receive(:terminate_instance)
        .and_return({ success: false, error_code: "NotFound", error: "Instance not found" })

      result = terminate

      expect(result.success?).to be(true)
      expect(instance.reload.status).to eq("terminated")
    end

    it "treats a raised ResourceNotFoundError as already-terminated (idempotent retry)" do
      allow(adapter).to receive(:terminate_instance)
        .and_raise(System::Providers::BaseProvider::ResourceNotFoundError, "no such instance")

      result = terminate

      expect(result.success?).to be(true)
      expect(instance.reload.status).to eq("terminated")
    end

    it "warns and skips re-metering when the row is already terminated" do
      instance.update_columns(status: "terminated")
      allow(adapter).to receive(:terminate_instance).and_return({ success: true })
      allow(Rails.logger).to receive(:warn)
      expect_any_instance_of(described_class).not_to receive(:record_meter_event)

      result = terminate

      expect(result.success?).to be(true)
      expect(Rails.logger).to have_received(:warn).with(/already|cannot transition/i)
    end

    it "returns an error and leaves the status unchanged on non-NotFound provider failures" do
      allow(adapter).to receive(:terminate_instance)
        .and_return({ success: false, error: "rate limited" })

      result = terminate

      expect(result.success?).to be(false)
      expect(instance.reload.status).to eq("starting")
    end

    # F4-09 — codify the F4-02 fix across the full status matrix: terminate
    # must drive ANY non-terminal status to "terminated", not only the
    # steady-state ones. Pre-fix, a not-yet-up instance (pending/starting)
    # destroyed the cloud resource but left the row wedged.
    %w[running stopped error pending].each do |from_status|
      it "terminates an instance from :#{from_status}" do
        from = create(:system_node_instance, node: node, status: from_status,
                      config: { "cloud_instance_id" => "i-#{from_status}" })
        allow(adapter).to receive(:terminate_instance)
          .with("i-#{from_status}").and_return({ success: true })

        result = described_class.terminate_instance(instance: from)

        expect(result.success?).to be(true)
        expect(from.reload.status).to eq("terminated")
      end
    end
  end

  # Increment 13 — SDWAN provision-time auto-enrollment. Opt-in is per
  # NodeTemplate#config["sdwan_network_id"] (pool metadata overrides when the
  # node belongs to a pool). ProvisioningService.provision_instance /
  # terminate_instance are the single choke points every provisioning path
  # (InstancePoolService, MCP system_fleet_tool, agent_fleet_mission_service,
  # federation spawner, ...) already funnels through — wiring enrollment here
  # covers pool AND non-pool instances without touching each caller.
  describe "SDWAN provision-time auto-enrollment" do
    let(:sdwan_account) { account }
    let(:network) { create(:sdwan_network, account: sdwan_account) }

    before do
      allow(adapter).to receive(:create_instance)
        .and_return(success: true, cloud_instance_id: "i-sdwan-1", status: "running")
    end

    context "when the node_template declares sdwan_network_id" do
      before { node.node_template.update!(config: { "sdwan_network_id" => network.id }) }

      it "enrolls an Sdwan::Peer for the provisioned instance" do
        result = provision

        instance = result.data[:instance]
        peer = Sdwan::Peer.find_by(node_instance_id: instance.id, sdwan_network_id: network.id)
        expect(peer).not_to be_nil
      end

      it "still returns a successful provision result" do
        result = provision
        expect(result.success?).to be(true)
      end

      # First-enrollee-becomes-hub (019fe647 topology decision, 2026-08-09):
      # a network with no publicly-reachable peer cannot punch NAT for
      # spokes, and mission instances are ephemeral — so the first instance
      # to enroll on a hub-less network takes the hub role (endpoint = its
      # provisioned address), self-healing per run. Hubs require an endpoint,
      # so with no address known the peer stays a spoke and promotion is the
      # failover sensor's job.
      it "enrolls the FIRST peer on a hub-less network as the hub, endpointed at its address" do
        allow(adapter).to receive(:create_instance)
          .and_return(success: true, cloud_instance_id: "i-sdwan-hub", status: "running",
                      private_ip_address: "10.125.7.31")
        result = provision
        peer = Sdwan::Peer.find_by(node_instance_id: result.data[:instance].id)
        expect(peer.publicly_reachable).to be(true)
        expect(peer.endpoint_host).to eq("10.125.7.31")
        expect(peer.endpoint_port).to eq(51820)
      end

      it "enrolls as a spoke when no address is known at enroll time (sensor promotes later)" do
        result = provision # default stub returns no private_ip_address
        peer = Sdwan::Peer.find_by(node_instance_id: result.data[:instance].id)
        expect(peer).not_to be_nil
        expect(peer.publicly_reachable).to be(false)
      end

      it "enrolls subsequent peers as spokes once a hub exists" do
        hub_instance = create(:system_node_instance, node: node, status: "running")
        Sdwan::PeerEnroller.call(network: network, node_instance: hub_instance,
                                 publicly_reachable: true,
                                 endpoint_host: "10.125.7.1", endpoint_port: 51820)

        allow(adapter).to receive(:create_instance)
          .and_return(success: true, cloud_instance_id: "i-sdwan-2", status: "running",
                      private_ip_address: "10.125.7.32")
        result = provision
        peer = Sdwan::Peer.find_by(node_instance_id: result.data[:instance].id)
        expect(peer.publicly_reachable).to be(false)
      end
    end

    context "when neither template nor pool declares sdwan_network_id" do
      it "does not create any Sdwan::Peer" do
        expect { provision }.not_to change(Sdwan::Peer, :count)
      end
    end

    context "when the instance belongs to a pool whose metadata declares sdwan_network_id" do
      let(:pool_region)   { create(:system_provider_region) }
      let(:pool_type)     { create(:system_provider_instance_type) }
      let(:pool) do
        System::InstancePool.create!(
          account: account, node_template: node.node_template, name: "sdwan-pool",
          target_size: 1, min_size: 0, max_size: 2, lifecycle_class: "ephemeral",
          status: "active", provider_region: pool_region, provider_instance_type: pool_type,
          metadata: { "sdwan_network_id" => network.id }
        )
      end

      before { node.update!(config: { "instance_pool_id" => pool.id }) }

      it "enrolls via the pool's metadata even though the template has no flag" do
        result = provision

        instance = result.data[:instance]
        expect(Sdwan::Peer.exists?(node_instance_id: instance.id, sdwan_network_id: network.id)).to be(true)
      end

      it "pool metadata takes precedence over a conflicting template flag" do
        other_network = create(:sdwan_network, account: account)
        node.node_template.update!(config: { "sdwan_network_id" => other_network.id })

        result = provision

        instance = result.data[:instance]
        expect(Sdwan::Peer.exists?(node_instance_id: instance.id, sdwan_network_id: network.id)).to be(true)
        expect(Sdwan::Peer.exists?(node_instance_id: instance.id, sdwan_network_id: other_network.id)).to be(false)
      end
    end

    context "when PeerEnroller raises" do
      before do
        node.node_template.update!(config: { "sdwan_network_id" => network.id })
        allow(Sdwan::PeerEnroller).to receive(:call).and_raise(StandardError, "enroll boom")
      end

      it "does not fail the provision" do
        result = provision
        expect(result.success?).to be(true)
      end

      it "logs the failure instead of raising" do
        allow(Rails.logger).to receive(:error)
        provision
        expect(Rails.logger).to have_received(:error).with(/SDWAN auto-enroll failed/)
      end
    end

    it "is idempotent — never enrolls a second peer for the same instance+network" do
      node.node_template.update!(config: { "sdwan_network_id" => network.id })
      result = provision
      instance = result.data[:instance]

      expect do
        described_class.new.send(:auto_enroll_sdwan_peer!, instance, node)
      end.not_to change(Sdwan::Peer, :count)
    end
  end

  describe "SDWAN detach on terminate" do
    let(:network) { create(:sdwan_network, account: account) }
    let(:instance) do
      create(:system_node_instance, node: node, status: "running",
             config: { "cloud_instance_id" => "i-detach-1" })
    end

    before do
      allow(System::Providers::Registry).to receive(:for_instance).and_return(adapter)
      allow(adapter).to receive(:terminate_instance).and_return({ success: true })
      Sdwan::PeerEnroller.call(network: network, node_instance: instance)
    end

    def terminate
      described_class.terminate_instance(instance: instance)
    end

    it "detaches the peer on successful terminate" do
      expect { terminate }.to change(Sdwan::Peer, :count).by(-1)
    end

    it "still finalizes termination when there is no SDWAN peer" do
      Sdwan::PeerDetacher.call(node_instance: instance) # pre-clear
      result = terminate
      expect(result.success?).to be(true)
      expect(instance.reload.status).to eq("terminated")
    end

    it "does not fail termination when detach raises" do
      allow(Sdwan::PeerDetacher).to receive(:call).and_raise(StandardError, "detach boom")

      result = terminate

      expect(result.success?).to be(true)
      expect(instance.reload.status).to eq("terminated")
    end

    it "also detaches on the idempotent NotFound (already-gone) terminate path" do
      allow(adapter).to receive(:terminate_instance)
        .and_return({ success: false, error_code: "NotFound", error: "gone" })

      expect { terminate }.to change(Sdwan::Peer, :count).by(-1)
    end
  end

  # RCP v2 (campaign 019f9250, increment p0c) — INV-1: no self-management.
  # Nil-safe/inert by default (see System::Autonomy::SelfManagementFence) —
  # these specs prove BOTH halves: zero behavior change while unconfigured,
  # and a hard refusal once self_hosting_node_id names the target.
  describe "INV-1 self-management fence" do
    describe "#provision_instance" do
      it "does not raise when self_hosting_node_id is unconfigured (today's default on every plane)" do
        allow(adapter).to receive(:create_instance).and_return(success: true, cloud_instance_id: "i-1", status: "running")

        expect { provision }.not_to raise_error
      end

      it "raises SelfManagementViolation before creating any instance row when the target node is self-hosting" do
        SiteSetting.set("self_hosting_node_id", node.id)

        expect { provision }
          .to raise_error(System::Autonomy::SelfManagementFence::SelfManagementViolation, /INV-1/)
          .and change(System::NodeInstance, :count).by(0)
      end

      it "is unaffected when a DIFFERENT node is configured as self-hosting" do
        SiteSetting.set("self_hosting_node_id", create(:system_node, account: account).id)
        allow(adapter).to receive(:create_instance).and_return(success: true, cloud_instance_id: "i-1", status: "running")

        expect { provision }.not_to raise_error
      end
    end

    describe "#terminate_instance" do
      let(:instance) do
        create(:system_node_instance, node: node, status: "starting", config: { "cloud_instance_id" => "i-123" })
      end

      before { allow(System::Providers::Registry).to receive(:for_instance).and_return(adapter) }

      it "does not raise when unconfigured" do
        allow(adapter).to receive(:terminate_instance).and_return({ success: true })
        expect { described_class.terminate_instance(instance: instance) }.not_to raise_error
      end

      it "raises SelfManagementViolation for an instance on the self-hosting node, before calling the provider" do
        SiteSetting.set("self_hosting_node_id", node.id)
        expect(adapter).not_to receive(:terminate_instance)

        expect { described_class.terminate_instance(instance: instance) }
          .to raise_error(System::Autonomy::SelfManagementFence::SelfManagementViolation, /terminate/)
        expect(instance.reload.status).to eq("starting") # unchanged
      end
    end
  end

  # RCP v2 (campaign 019f9250, increment p0c) — INV-2 (no boot-time network
  # dependency) + INV-6 (member storage = local disk). Opt-in via
  # options[:rcp_member_provisioning] — everything above in this file
  # (the entire default provisioning path) is unaffected by these checks.
  describe "INV-2/INV-6 rcp_member_provisioning opt-in" do
    let(:proxmox_connection) { instance_double("System::ProviderConnection", config: {}, provider: nil) }
    let(:proxmox_adapter) do
      instance_double("System::Providers::ProxmoxProvider",
        provider_type: "proxmox", supports?: true, connection: proxmox_connection)
    end

    before do
      allow(System::Providers::Registry).to receive(:for_node).and_return(proxmox_adapter)
    end

    it "does not check anything when the option is omitted (default path unaffected)" do
      allow(proxmox_adapter).to receive(:create_instance).and_return(success: true, cloud_instance_id: "i-1", status: "running")
      expect(System::Autonomy::BootPathInvariantCheck).not_to receive(:violation_for)

      result = provision
      expect(result.success?).to be(true)
    end

    it "rejects a uefi_disk provision whose connection has no cidata_transport iso opt-in" do
      template = create(:system_node_template, account: account, config: { "boot_mode" => "uefi_disk" })
      member_node = create(:system_node, account: account, node_template: template)

      result = described_class.provision_instance(
        node: member_node, provider_region_id: region.id, provider_instance_type_id: instance_type.id,
        options: { rcp_member_provisioning: true, user_data: "#cloud-config\n" }
      )

      expect(result.success?).to be(false)
      expect(result.error).to match(/NFS/)
      expect(System::NodeInstance.where(node: member_node)).to be_empty
    end

    it "allows a uefi_disk provision once the connection opts into the ISO transport" do
      allow(proxmox_connection).to receive(:config).and_return({ "cidata_transport" => "iso" })
      allow(proxmox_adapter).to receive(:create_instance).and_return(success: true, cloud_instance_id: "i-1", status: "running")
      template = create(:system_node_template, account: account, config: { "boot_mode" => "uefi_disk" })
      member_node = create(:system_node, account: account, node_template: template)

      result = described_class.provision_instance(
        node: member_node, provider_region_id: region.id, provider_instance_type_id: instance_type.id,
        options: { rcp_member_provisioning: true, user_data: "#cloud-config\n" }
      )

      expect(result.success?).to be(true)
    end

    it "rejects when the resolved storage cannot be verified as local (fails closed under strict mode)" do
      allow(proxmox_connection).to receive(:config).and_return({ "default_storage" => "dsm-data" })
      # A plain (non-verifying) double with no list_volume_types defined at
      # all — respond_to?(:list_volume_types) is naturally false, exercising
      # StorageLocalityCheck's "adapter doesn't support the query" branch
      # without needing to override #respond_to? on a verified double.
      no_query_adapter = double("adapter", provider_type: "proxmox", supports?: true, connection: proxmox_connection) # rubocop:disable RSpec/VerifiedDoubles
      allow(System::Providers::Registry).to receive(:for_node).and_return(no_query_adapter)

      result = provision(options: { rcp_member_provisioning: true })

      expect(result.success?).to be(false)
      expect(result.error).to match(/could not verify/)
    end

    it "allows provisioning once storage is confirmed local via a live list_volume_types answer" do
      allow(proxmox_connection).to receive(:config).and_return({ "default_storage" => "dna-data" })
      allow(proxmox_adapter).to receive(:list_volume_types).and_return([
        { cloud_id: "dna-data", name: "dna-data", plugin_type: "zfspool", shared: false }
      ])
      allow(proxmox_adapter).to receive(:create_instance).and_return(success: true, cloud_instance_id: "i-1", status: "running")

      result = provision(options: { rcp_member_provisioning: true })

      expect(result.success?).to be(true)
    end
  end
end
