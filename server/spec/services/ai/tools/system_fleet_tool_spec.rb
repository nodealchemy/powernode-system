# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M5 — SystemFleetTool MCP surface.
# Mirrors the trading_*_tool_spec.rb shape: invoke .execute(params:) directly,
# assert success_result/error_result content.
RSpec.describe Ai::Tools::SystemFleetTool do
  let(:account)  { create(:account) }
  let(:platform_record) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform_record) }
  # Behaviour specs below exercise the tool as an in-process system caller, so
  # they declare that with `internal: true`. A bare userless construction is no
  # longer a permission bypass — see "principal authorization (IMP-9030413bc292)".
  let(:tool)     { described_class.new(account: account, internal: true) }

  def call(action, **rest)
    tool.execute(params: { action: action }.merge(rest))
  end

  # Forces Ai::AutonomyGate's :proceed branch, where the executor runs inline.
  # Approval-gated tool actions resolve to require_approval by default (no
  # seeded policy in a spec account), so anything asserting the post-action
  # state — rather than the deferral itself — has to opt into this.
  def auto_approve_policy!
    allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
      { policy: "auto_approve", channels: [], conditions: {}, record: nil }
    )
  end

  describe ".action_definitions" do
    it "registers all 17 system_* actions" do
      keys = described_class.action_definitions.keys
      expect(keys.size).to be >= 17
      expect(keys).to all(start_with("system_"))
    end

    # Audit F8-05 — the 5 storage-migration lifecycle actions were dispatched
    # and permission-mapped but had no action_definitions entries, so the
    # registry fell back to the generic 14-param union schema and their real
    # contracts (id/status/active_only/reason/bytes_*) were undiscoverable.
    it "documents the 5 storage-migration lifecycle action contracts (F8-05)" do
      defs = described_class.action_definitions

      list = defs.fetch("system_list_storage_migrations")
      expect(list[:parameters].keys).to include(:status, :node_instance_id, :active_only)

      expect(defs.fetch("system_get_storage_migration")[:parameters][:id][:required]).to be true
      expect(defs.fetch("system_approve_storage_migration")[:parameters][:id][:required]).to be true

      cancel = defs.fetch("system_cancel_storage_migration")
      expect(cancel[:parameters][:id][:required]).to be true
      expect(cancel[:parameters].keys).to include(:reason)

      progress = defs.fetch("system_report_storage_migration_progress")
      expect(progress[:parameters][:id][:required]).to be true
      expect(progress[:parameters].keys).to include(:status, :bytes_copied, :bytes_total, :bytes_verified, :note)
    end

    # IMP-b2f80e6d1c65 — same shape as the F8-05 gap above: these 5 actions
    # had ACTION_PERMISSIONS + a dispatch branch but no PlatformApiToolRegistry
    # key and no action_definitions entry, so they were reachable only by
    # smuggling the action into another tool's name (closed by e6c3e6e4d).
    it "documents the ops-hold + publish-target action contracts (IMP-b2f80e6d1c65)" do
      defs = described_class.action_definitions

      hold = defs.fetch("system_instance_hold")
      expect(hold[:parameters][:instance_id][:required]).to be true
      expect(hold[:parameters][:reason][:required]).to be true
      expect(hold[:parameters].keys).to include(:ttl_hours)

      expect(defs.fetch("system_instance_release_hold")[:parameters][:instance_id][:required]).to be true
      expect(defs.fetch("system_instance_hold_status")[:parameters][:instance_id][:required]).to be true

      target = defs.fetch("system_module_publish_target")
      expect(target[:parameters][:module_name][:required]).to be true
      expect(target[:parameters].keys).to include(:gitea_repo)

      integrity = defs.fetch("system_module_publication_integrity")
      expect(integrity[:parameters][:module_name][:required]).to be false
    end
  end

  # Audit F4-13 — the explicit instance_id path skipped the liveness + GPU
  # gating the discovery path applies, so deploys landed on terminated or
  # GPU-less instances and registered dead inference endpoints.
  describe "deploy_inference_server target validation (F4-13)" do
    let(:gpu_type) do
      create(:system_provider_instance_type, account: account, gpu_count: 1,
             gpu_type: "H100", gpu_memory_mb: 81_920)
    end
    let(:cpu_type) { create(:system_provider_instance_type, account: account, gpu_count: 0) }

    before do
      allow(::System::InferenceDeploymentService).to receive(:deploy!)
        .and_return(::System::InferenceDeploymentService::Result.new(instance_id: "x"))
    end

    it "rejects an explicit terminated instance" do
      dead = create(:system_node_instance, account: account, status: "terminated",
                    provider_instance_type: gpu_type)

      r = call("system_deploy_inference_server", instance_id: dead.id)

      expect(r[:success]).to be false
      expect(r[:error]).to include("terminated")
      expect(::System::InferenceDeploymentService).not_to have_received(:deploy!)
    end

    it "rejects an explicit GPU-less instance" do
      cpu = create(:system_node_instance, account: account, status: "running",
                   provider_instance_type: cpu_type)

      r = call("system_deploy_inference_server", instance_id: cpu.id)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/GPU/i)
      expect(::System::InferenceDeploymentService).not_to have_received(:deploy!)
    end

    it "force: true bypasses the gating for intentional deploys" do
      cpu = create(:system_node_instance, account: account, status: "running",
                   provider_instance_type: cpu_type)

      r = call("system_deploy_inference_server", instance_id: cpu.id, force: true)

      expect(r[:success]).to be true
      expect(::System::InferenceDeploymentService).to have_received(:deploy!)
    end
  end

  # Audit F8-07 — MCP/REST update-parity gaps: pools and nodes had no
  # update action (an agent couldn't tune pool min/max or rename/disable a
  # node), despite both having REST update endpoints.
  describe "update parity (F8-07)" do
    let(:node_template) { create(:system_node_template, account: account) }

    describe "system_update_instance_pool" do
      let(:pool) do
        ::System::InstancePool.create!(
          account: account, node_template: node_template, name: "tune-me",
          target_size: 2, min_size: 1, max_size: 5, lifecycle_class: "ephemeral",
          status: "active", provider_region: create(:system_provider_region),
          provider_instance_type: create(:system_provider_instance_type)
        )
      end

      it "tunes min/max/target size" do
        r = call("system_update_instance_pool", id: pool.id, min_size: 0, max_size: 8, target_size: 4)
        expect(r[:success]).to be true
        pool.reload
        expect([ pool.min_size, pool.max_size, pool.target_size ]).to eq([ 0, 8, 4 ])
      end

      it "surfaces a validation error without raising" do
        r = call("system_update_instance_pool", id: pool.id, min_size: 10, max_size: 2)
        expect(r[:success]).to be false
        expect(r[:error]).to be_present
      end

      it "does not touch a pool from another account" do
        other = create(:account)
        foreign = ::System::InstancePool.create!(
          account: other, node_template: create(:system_node_template, account: other),
          name: "foreign", target_size: 1, min_size: 0, max_size: 3, lifecycle_class: "ephemeral",
          status: "active", provider_region: create(:system_provider_region),
          provider_instance_type: create(:system_provider_instance_type)
        )
        r = call("system_update_instance_pool", id: foreign.id, target_size: 9)
        expect(r[:success]).to be false
        expect(foreign.reload.target_size).to eq(1)
      end

      it "maps to system.instances.create" do
        expect(described_class::ACTION_PERMISSIONS.fetch("system_update_instance_pool")).to eq("system.instances.create")
      end
    end

    describe "system_update_node" do
      let(:node) { create(:system_node, account: account, node_template: node_template, name: "old-name") }

      it "renames and disables the node" do
        r = call("system_update_node", node_id: node.id, name: "new-name", enabled: false, description: "tuned")
        expect(r[:success]).to be true
        node.reload
        expect(node.name).to eq("new-name")
        expect(node.enabled).to be false
        expect(node.description).to eq("tuned")
      end

      it "does not touch a node from another account" do
        foreign = create(:system_node, account: create(:account), name: "theirs")
        r = call("system_update_node", node_id: foreign.id, name: "hijacked")
        expect(r[:success]).to be false
        expect(foreign.reload.name).to eq("theirs")
      end

      it "maps to system.nodes.update" do
        expect(described_class::ACTION_PERMISSIONS.fetch("system_update_node")).to eq("system.nodes.update")
      end

      it "does NOT accept ssh key material as a tool parameter (crypto-safety)" do
        params = described_class.action_definitions.fetch("system_update_node")[:parameters].keys
        expect(params).not_to include(:ssh_key, :ssh_host_key)
      end
    end
  end

  # Audit F4-11 — system_create_volume silently bound every volume to the
  # account's OLDEST provider/region (order(:created_at).first) with no way
  # to choose; on multi-provider accounts volumes landed on an arbitrary
  # provider, corrupting Registry.for_volume adapter resolution.
  describe "system_create_volume provider binding (F4-11)" do
    def create_nfs_volume(name, **rest)
      call("system_create_volume", name: name, size_gb: 10, transport: "nfs",
           nfs_server: "nas.local", nfs_export_path: "/exports/#{name}", **rest)
    end

    # NOTE: AccountBootstrapService gives every account a default provider
    # + region on creation, so adding two more yields a 3-provider account.
    context "with multiple providers" do
      let!(:provider_a) { create(:system_provider, account: account, name: "pve") }
      let!(:region_a)   { create(:system_provider_region, account: account, provider: provider_a) }
      let!(:provider_b) { create(:system_provider, account: account, name: "qemu") }
      let!(:region_b)   { create(:system_provider_region, account: account, provider: provider_b) }

      it "errors with the candidate list instead of guessing" do
        r = create_nfs_volume("vol-ambiguous")

        expect(r[:success]).to be false
        expect(r[:error]).to include("provider_id")
        expect(r[:error]).to include(provider_a.id)
        expect(r[:error]).to include(provider_b.id)
        expect(System::ProviderVolume.where(account: account).count).to eq(0)
      end

      it "binds to an explicit provider_region_id" do
        r = create_nfs_volume("vol-region", provider_region_id: region_b.id)

        expect(r[:success]).to be true
        v = System::ProviderVolume.find(r[:data][:volume][:id])
        expect(v.provider_region_id).to eq(region_b.id)
      end

      it "binds to an explicit provider_id via its region" do
        r = create_nfs_volume("vol-provider", provider_id: provider_b.id)

        expect(r[:success]).to be true
        v = System::ProviderVolume.find(r[:data][:volume][:id])
        expect(v.provider_region_id).to eq(region_b.id)
      end

      it "rejects a provider_id outside the account" do
        foreign = create(:system_provider)

        r = create_nfs_volume("vol-foreign", provider_id: foreign.id)

        expect(r[:success]).to be false
        expect(System::ProviderVolume.where(account: account).count).to eq(0)
      end
    end

    context "with only the bootstrap default provider" do
      it "keeps the implicit binding" do
        bootstrap_provider = System::Provider.where(account: account).order(:created_at).first
        bootstrap_region = System::ProviderRegion.where(provider: bootstrap_provider).order(:created_at).first
        expect(bootstrap_region).to be_present # AccountBootstrapService default

        r = create_nfs_volume("vol-implicit")

        expect(r[:success]).to be true
        v = System::ProviderVolume.find(r[:data][:volume][:id])
        expect(v.provider_region_id).to eq(bootstrap_region.id)
      end
    end
  end

  # Audit IMP-298803318cfd — delete_volume's attach-guard only blocked on the
  # block-volume FK (node_instance_id). Network-FS volumes (NFS/SMB/iSCSI) are
  # pools: their per-consumer binding is recorded ONLY in
  # NodeInstance.config["storage_volume"]["volume_id"] and the attach path
  # never sets node_instance_id. So a shared volume actively mounted by live
  # instances passed the guard and got destroy!-ed — breaking live mounts and
  # orphaning data.
  describe "delete_volume network-FS attach-guard (IMP-298803318cfd)" do
    let(:nfs_type) do
      create(:system_provider_volume_type, account: account, volume_type: "nfs")
    end
    let(:nfs_volume) do
      create(:system_provider_volume, account: account, volume_type: nfs_type)
    end

    it "blocks deletion when an instance references it via config[\"storage_volume\"]" do
      create(:system_node_instance, account: account,
             config: { "storage_volume" => { "volume_id" => nfs_volume.id, "transport" => "nfs" } })

      r = call("system_delete_volume", id: nfs_volume.id)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/attached/i)
      expect(System::ProviderVolume.exists?(nfs_volume.id)).to be true
    end

    it "allows deletion of an unreferenced network-FS volume" do
      r = call("system_delete_volume", id: nfs_volume.id)

      expect(r[:success]).to be true
      expect(System::ProviderVolume.exists?(nfs_volume.id)).to be false
    end

    it "still blocks a block-attached volume via node_instance_id (existing behavior)" do
      block_instance = create(:system_node_instance, account: account)
      block_volume = create(:system_provider_volume, :attached, account: account,
                            node_instance: block_instance)

      r = call("system_delete_volume", id: block_volume.id)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/attached/i)
      expect(System::ProviderVolume.exists?(block_volume.id)).to be true
    end
  end

  # Audit IMP-dc49b9151852 — attach_volume ignored ProviderVolume#attach_to!'s
  # return value and unconditionally stamped the instance's config binding, so
  # a volume stuck in creating/error status "attached" successfully while the
  # row never flipped to in-use — the agent mounts a device that was never
  # attached. Attaching a second volume also silently clobbered the single
  # storage_volume binding instead of refusing, and detach_volume's network-FS
  # path cleared the binding without checking it belonged to the given volume.
  describe "attach_volume / detach_volume binding integrity (IMP-dc49b9151852)" do
    let(:instance) { create(:system_node_instance, account: account) }

    describe "block-volume attach" do
      it "does not strand the instance when the volume is not available (status creating)" do
        volume = create(:system_provider_volume, account: account, status: "creating")

        r = call("system_attach_volume", volume_id: volume.id, node_instance_id: instance.id)

        expect(r[:success]).to be false
        expect(instance.reload.config["storage_volume"]).to be_nil
        expect(volume.reload.node_instance_id).to be_nil
        expect(volume.status).to eq("creating")
      end

      it "does not strand the instance when the volume is in error status" do
        volume = create(:system_provider_volume, account: account, status: "error")

        r = call("system_attach_volume", volume_id: volume.id, node_instance_id: instance.id)

        expect(r[:success]).to be false
        expect(instance.reload.config["storage_volume"]).to be_nil
        expect(volume.reload.node_instance_id).to be_nil
      end

      it "attaches a genuinely available volume and records the FK" do
        volume = create(:system_provider_volume, account: account, status: "available")

        r = call("system_attach_volume", volume_id: volume.id, node_instance_id: instance.id)

        expect(r[:success]).to be true
        expect(volume.reload.node_instance_id).to eq(instance.id)
        expect(instance.reload.config.dig("storage_volume", "volume_id")).to eq(volume.id)
      end
    end

    describe "clobber guard" do
      it "refuses to overwrite an existing storage_volume binding with a different volume" do
        first = create(:system_provider_volume, account: account, status: "available")
        second = create(:system_provider_volume, account: account, status: "available")
        call("system_attach_volume", volume_id: first.id, node_instance_id: instance.id)

        r = call("system_attach_volume", volume_id: second.id, node_instance_id: instance.id)

        expect(r[:success]).to be false
        expect(instance.reload.config.dig("storage_volume", "volume_id")).to eq(first.id)
        expect(second.reload.node_instance_id).to be_nil
      end
    end

    describe "network-FS detach" do
      let(:nfs_type) { create(:system_provider_volume_type, account: account, volume_type: "nfs") }
      let(:bound_volume) { create(:system_provider_volume, account: account, volume_type: nfs_type) }
      let(:other_volume) { create(:system_provider_volume, account: account, volume_type: nfs_type) }

      it "refuses to clear the binding when it references a different volume" do
        instance.update!(config: { "storage_volume" => { "volume_id" => bound_volume.id, "transport" => "nfs" } })

        r = call("system_detach_volume", volume_id: other_volume.id, node_instance_id: instance.id)

        expect(r[:success]).to be false
        expect(instance.reload.config.dig("storage_volume", "volume_id")).to eq(bound_volume.id)
      end

      it "clears the binding when it references the given volume" do
        instance.update!(config: { "storage_volume" => { "volume_id" => bound_volume.id, "transport" => "nfs" } })

        r = call("system_detach_volume", volume_id: bound_volume.id, node_instance_id: instance.id)

        expect(r[:success]).to be true
        expect(instance.reload.config["storage_volume"]).to be_nil
      end
    end
  end

  # Audit F4-08 — agents could provision, terminate, and drain but not
  # start/stop/reboot, even though InstanceControlService and the AASM fully
  # support these operations. For GPU-cost-sensitive missions stop/start is
  # the single biggest missing cost-control lever on the MCP surface.
  describe "instance control actions (F4-08)" do
    let(:control_node) { create(:system_node, account: account, node_template: template) }
    let(:instance) { create(:system_node_instance, :running, node: control_node) }

    it "documents the three control action contracts" do
      defs = described_class.action_definitions
      %w[system_start_instance system_stop_instance system_reboot_instance].each do |action|
        d = defs.fetch(action)
        expect(d[:parameters][:instance_id][:required]).to be true
        expect(d[:parameters].keys).to include(:operation_id, :force)
      end
    end

    it "maps the three actions to system.instances.control" do
      %w[system_start_instance system_stop_instance system_reboot_instance].each do |action|
        expect(described_class::ACTION_PERMISSIONS.fetch(action)).to eq("system.instances.control")
      end
    end

    %w[start stop reboot].each do |op|
      it "dispatches system_#{op}_instance through InstanceControlService" do
        expect(::System::InstanceControlService).to receive(:execute)
          .with(instance: instance, action: op, operation_id: "op-1", force: true)
          .and_return(::System::Runtime::Result.ok(data: { status: "ok" }))

        r = call("system_#{op}_instance", instance_id: instance.id, operation_id: "op-1", force: true)

        expect(r[:success]).to be true
        expect(r[:data][:instance]).to be_present
        expect(r[:data][:action]).to eq(op)
      end
    end

    it "surfaces control failures as error results" do
      allow(::System::InstanceControlService).to receive(:execute)
        .and_return(::System::Runtime::Result.err(error: "Cannot stop instance in pending status"))

      r = call("system_stop_instance", instance_id: instance.id)

      expect(r[:success]).to be false
      expect(r[:error]).to include("Cannot stop")
    end
  end

  describe "GPU discovery (audit P6)" do
    let(:gpu_type) { create(:system_provider_instance_type, account: account, gpu_count: 8, gpu_type: "H100", gpu_memory_mb: 81_920) }
    let(:cpu_type) { create(:system_provider_instance_type, account: account, gpu_count: 0) }

    it "system_list_instance_types_by_gpu returns only GPU SKUs, filtered by type" do
      gpu_type
      cpu_type
      r = call("system_list_instance_types_by_gpu", gpu_type: "h100")
      expect(r[:success]).to be true
      expect(r[:data][:instance_types].map { |t| t[:id] }).to eq([ gpu_type.id ])
      expect(r[:data][:instance_types].first[:gpu_type]).to eq("H100")
    end

    it "system_find_node_with_gpu finds GPU-bearing live instances and excludes CPU-only" do
      gpu_node = create(:system_node_instance, account: account, status: "running", provider_instance_type: gpu_type)
      create(:system_node_instance, account: account, status: "running", provider_instance_type: cpu_type)
      r = call("system_find_node_with_gpu", gpu_type: "H100", min_gpu_memory_mb: 40_000)
      expect(r[:success]).to be true
      expect(r[:data][:instances].map { |i| i[:id] }).to eq([ gpu_node.id ])
      expect(r[:data][:instances].first[:gpu_count]).to eq(8)
    end

    it "system_find_node_with_gpu resolves a config['gpu'] agent hint" do
      hinted = create(:system_node_instance, account: account, status: "running", provider_instance_type: cpu_type,
                                             config: { "gpu" => { "count" => 1, "type" => "RTX4090", "memory_mb" => 24_576 } })
      r = call("system_find_node_with_gpu")
      expect(r[:data][:instances].map { |i| i[:id] }).to include(hinted.id)
    end
  end

  describe "Inference deployment (L1)" do
    let(:gpu_type) do
      create(:system_provider_instance_type, account: account, gpu_count: 1, gpu_type: "Quadro RTX 4000", gpu_memory_mb: 8192)
    end

    before do
      create(:system_node_module, account: account, name: "gpu-nvidia-runtime", variety: "subscription",
                                  config: { "gpu_runtime" => { "container_runtime" => "nvidia" } })
      create(:system_node_module, account: account, name: "inference-ollama", variety: "subscription",
                                  config: { "inference" => { "api_port" => 11_434, "default_model" => "llama3.1:8b" } })
    end

    it "system_deploy_inference_server assigns modules + registers a provider on a GPU node" do
      inst = create(:system_node_instance, account: account, status: "running", provider_instance_type: gpu_type)
      r = call("system_deploy_inference_server", instance_id: inst.id, endpoint_override: "http://10.0.0.9:11434")
      expect(r[:success]).to be true
      dep = r[:data][:deployment]
      expect(dep[:module_assignment_ids].size).to eq(2)
      expect(dep[:endpoint]).to eq("http://10.0.0.9:11434")
      expect(Ai::Provider.find(dep[:provider_id]).provider_type).to eq("ollama")
    end

    it "auto-selects a GPU node when no instance_id is given" do
      inst = create(:system_node_instance, account: account, status: "running", provider_instance_type: gpu_type)
      r = call("system_deploy_inference_server", min_gpu_memory_mb: 4000, endpoint_override: "http://10.0.0.9:11434")
      expect(r[:success]).to be true
      expect(r[:data][:deployment][:instance_id]).to eq(inst.id)
    end

    it "errors when no GPU-capable instance is found" do
      r = call("system_deploy_inference_server", min_gpu_memory_mb: 4000, endpoint_override: "http://10.0.0.9:11434")
      expect(r[:success]).to be false
    end
  end

  describe "Instance MCP grants (L2)" do
    it "system_grant_instance_mcp_tools grants tool patterns to an announced instance" do
      inst = create(:system_node_instance, account: account, status: "running")
      System::NodeInstancePeer.create!(node_instance: inst, account: inst.node.account,
                                       handle: "a-#{SecureRandom.hex(3)}", status: "active",
                                       trust_score: 0.5, daily_decision_budget: 10)
      r = call("system_grant_instance_mcp_tools", instance_id: inst.id,
                                                  tool_patterns: %w[platform.system_*_read platform.health])
      expect(r[:success]).to be true
      expect(r[:data][:granted_mcp_tools]).to contain_exactly("platform.system_*_read", "platform.health")
      expect(System::NodeInstancePeer.find_by(node_instance_id: inst.id).granted_mcp_tools).to include("platform.health")
    end

    it "errors when the instance has not announced as a peer" do
      inst = create(:system_node_instance, account: account, status: "running")
      r = call("system_grant_instance_mcp_tools", instance_id: inst.id, tool_patterns: %w[platform.health])
      expect(r[:success]).to be false
    end
  end

  describe "A2A peer skills + discovery + authorization (L2.5)" do
    def announce(handle:, declared_skills: [], enabled: true, status: "active")
      inst = create(:system_node_instance, account: account, status: "running")
      peer = System::NodeInstancePeer.create!(
        node_instance: inst, account: inst.node.account,
        handle: "#{handle}-#{SecureRandom.hex(2)}", status: status, enabled: enabled,
        trust_score: 0.5, daily_decision_budget: 10, declared_skills: declared_skills
      )
      [ inst, peer ]
    end

    it "system_grant_instance_peer_skills grants peer-skill patterns to an announced instance" do
      inst, = announce(handle: "caller")
      r = call("system_grant_instance_peer_skills", instance_id: inst.id, skill_patterns: %w[embed-* summarize])
      expect(r[:success]).to be true
      expect(r[:data][:granted_peer_skills]).to contain_exactly("embed-*", "summarize")
      expect(System::NodeInstancePeer.find_by(node_instance_id: inst.id).granted_peer_skills).to include("summarize")
    end

    it "system_discover_peers lists online enabled peers + their offered skills (excluding the caller)" do
      caller_inst, = announce(handle: "caller")
      _target_inst, = announce(handle: "target", declared_skills: [ { "name" => "embed" } ])
      announce(handle: "offline", status: "disconnected")

      r = call("system_discover_peers", instance_id: caller_inst.id)
      expect(r[:success]).to be true
      handles = r[:data][:peers].map { |p| p[:handle] }
      expect(handles.any? { |h| h.start_with?("target-") }).to be true
      expect(handles.any? { |h| h.start_with?("caller-") }).to be false
      target_entry = r[:data][:peers].find { |p| p[:handle].start_with?("target-") }
      expect(target_entry[:offered_skills]).to eq(%w[embed])
    end

    it "system_authorize_peer_call authorizes a granted call and denies an ungranted one" do
      caller_inst, caller_peer = announce(handle: "caller")
      target_inst, = announce(handle: "target", declared_skills: [ { "name" => "embed-text" } ])
      caller_peer.grant_peer_skills!(%w[embed-*])

      ok = call("system_authorize_peer_call", caller_instance_id: caller_inst.id,
                                              target_instance_id: target_inst.id, skill: "embed-text")
      expect(ok[:success]).to be true
      expect(ok[:data][:authorized]).to be true

      denied = call("system_authorize_peer_call", caller_instance_id: caller_inst.id,
                                                  target_instance_id: target_inst.id, skill: "translate")
      expect(denied[:data][:authorized]).to be false
    end
  end

  describe "Agent fleet missions (L3)" do
    let(:user) { create(:user, account: account, permissions: %w[system.node_instances.manage system.node_instances.read]) }
    let(:fleet_tool) { described_class.new(account: account, user: user) }
    let(:node) { create(:system_node, account: account) }
    let!(:fleet_template) do
      create(:ai_mission_template, name: "system_agent_fleet", template_type: "system",
                                   mission_type: "agent_fleet",
                                   phases: [
                                     { "order" => 0, "key" => "plan_fleet",      "requires_approval" => false, "job_class" => "AiAgentFleetPlanJob" },
                                     { "order" => 1, "key" => "review_fleet",    "requires_approval" => true,  "job_class" => nil, "gate_name" => "fleet_review" },
                                     { "order" => 2, "key" => "provision_fleet", "requires_approval" => false, "job_class" => "AiAgentFleetProvisionJob" },
                                     { "order" => 3, "key" => "delegate",        "requires_approval" => false, "job_class" => "AiAgentFleetDelegateJob" },
                                     { "order" => 4, "key" => "aggregate",       "requires_approval" => false, "job_class" => "AiAgentFleetAggregateJob" },
                                     { "order" => 5, "key" => "reap",            "requires_approval" => false, "job_class" => "AiAgentFleetReapJob" }
                                   ],
                                   approval_gates: %w[review_fleet],
                                   rejection_mappings: { "review_fleet" => "plan_fleet" })
    end

    before { allow(WorkerJobService).to receive(:enqueue_job) } # don't dispatch the real plan_fleet job

    it "system_launch_agent_fleet creates + starts a mission stopped at plan_fleet" do
      spec = { "size" => 1, "source" => "provision", "node_id" => node.id,
               "provider_region_id" => "r", "provider_instance_type_id" => "t",
               "subtasks" => [], "delegation" => "hybrid" }
      r = fleet_tool.execute(params: { action: "system_launch_agent_fleet", fleet_spec: spec })
      expect(r[:success]).to be true
      expect(r[:data][:current_phase]).to eq("plan_fleet")
      expect(r[:data][:status]).to eq("active")
      mission = Ai::Mission.find(r[:data][:mission_id])
      expect(mission.mission_type).to eq("agent_fleet")
      expect(mission.configuration.dig("fleet_spec", "size")).to eq(1)
    end

    it "system_launch_agent_fleet requires a user context" do
      r = call("system_launch_agent_fleet", fleet_spec: { "size" => 1 })
      expect(r[:success]).to be false
    end

    it "system_agent_fleet_status summarizes the fleet" do
      mission = create(:ai_mission, account: account, mission_type: "agent_fleet",
                                    mission_template: fleet_template,
                                    configuration: { "fleet" => { "members" => [ { "x" => 1 }, { "x" => 2 } ],
                                                                   "report" => { "completed" => 2 } } })
      r = fleet_tool.execute(params: { action: "system_agent_fleet_status", mission_id: mission.id })
      expect(r[:success]).to be true
      expect(r[:data][:fleet][:member_count]).to eq(2)
      expect(r[:data][:fleet][:report]["completed"]).to eq(2)
    end

    # F1-08: a leaked member (terminate_failed) must be distinguishable from
    # a clean reap, and agents need a lifecycle lever to clean up stuck fleets.
    it "system_agent_fleet_status surfaces per-member reap actions and incompleteness" do
      mission = create(:ai_mission, account: account, mission_type: "agent_fleet",
                                    mission_template: fleet_template,
                                    error_message: "reap incomplete: 1 member(s) failed to terminate",
                                    configuration: { "fleet" => {
                                      "members" => [ { "slot" => 0 } ],
                                      "reaped" => [ { "instance_id" => "i-1", "action" => "terminate_failed" } ]
                                    } })

      r = fleet_tool.execute(params: { action: "system_agent_fleet_status", mission_id: mission.id })

      expect(r[:data][:fleet][:reaped]).to eq([ { "instance_id" => "i-1", "action" => "terminate_failed" } ])
      expect(r[:data][:fleet][:reap_incomplete]).to be true
      expect(r[:data][:error_message]).to match(/reap incomplete/)
    end

    it "system_reap_agent_fleet re-runs reap for a stuck fleet" do
      instance = create(:system_node_instance, :running, node: node)
      mission = create(:ai_mission, account: account, mission_type: "agent_fleet",
                                    mission_template: fleet_template,
                                    configuration: { "fleet" => {
                                      "plan" => { "size" => 1, "source" => "provision", "reap" => true },
                                      "members" => [ { "slot" => 0, "instance_id" => instance.id, "peer_id" => nil } ]
                                    } })
      allow(::System::ProvisioningService).to receive(:terminate_instance)
        .and_return(double(success?: true, error: nil))

      r = fleet_tool.execute(params: { action: "system_reap_agent_fleet", mission_id: mission.id })

      expect(r[:success]).to be true
      expect(r[:data][:reap][:ok]).to be true
      expect(r[:data][:reap][:reaped].first["action"]).to eq("terminated")
    end
  end

  describe "A2A capability token (L2.5)" do
    let(:user) { create(:user, account: account, permissions: %w[system.node_instances.manage]) }
    let(:cap_tool) { described_class.new(account: account, user: user) }

    def cap_peer(handle:, declared_skills: [], granted: [])
      inst = create(:system_node_instance, account: account, status: "running")
      System::NodeInstancePeer.create!(
        node_instance: inst, account: account, handle: "#{handle}-#{SecureRandom.hex(2)}",
        status: "active", enabled: true, trust_score: 0.5, daily_decision_budget: 10,
        declared_skills: declared_skills
      ).tap { |p| p.grant_peer_skills!(granted) if granted.any? }
      inst
    end

    it "system_mint_peer_capability_token mints a signed token when authorized" do
      caller_inst = cap_peer(handle: "caller", granted: %w[embed-*])
      target_inst = cap_peer(handle: "target", declared_skills: [ { "name" => "embed-text" } ])
      r = cap_tool.execute(params: { action: "system_mint_peer_capability_token",
                                     caller_instance_id: caller_inst.id, target_instance_id: target_inst.id, skill: "embed-text" })
      expect(r[:success]).to be true
      expect(r[:data][:token][:sub]).to eq(caller_inst.id)
      expect(r[:data][:token][:aud]).to eq(target_inst.id)
      expect(r[:data][:token][:signature]).to be_present
      expect(r[:data][:token][:public_key]).to be_present
    end

    it "denies minting when the caller is not granted the skill" do
      caller_inst = cap_peer(handle: "caller") # no grant
      target_inst = cap_peer(handle: "target", declared_skills: [ { "name" => "embed-text" } ])
      r = cap_tool.execute(params: { action: "system_mint_peer_capability_token",
                                     caller_instance_id: caller_inst.id, target_instance_id: target_inst.id, skill: "embed-text" })
      expect(r[:success]).to be false
      expect(r[:error]).to match(/not authorized/)
    end
  end

  describe "Isolation tiers (L0)" do
    it "system_list_isolation_tiers returns the catalog + default" do
      r = call("system_list_isolation_tiers")
      expect(r[:success]).to be true
      expect(r[:data][:default]).to eq("native")
      tiers = r[:data][:tiers].map { |t| t["tier"] }
      expect(tiers).to include("native", "gvisor", "kata", "firecracker", "vm")
      native = r[:data][:tiers].find { |t| t["tier"] == "native" }
      expect(native["docker_runtime"]).to eq("runc")
    end
  end

  describe "Nodes — create / list / get" do
    it "system_create_node creates a node bound to the template" do
      r = call("system_create_node", name: "fleet-node-1", template_id: template.id)
      expect(r[:success]).to be true
      expect(r.dig(:data, :node, :name)).to eq("fleet-node-1")
    end

    # IMP-a5dcb7cfca0a — create takes the same surface as REST create
    # (node_params minus ssh key material), mirroring the F8-07 slice update
    # already has. Before this, an agent had to create then immediately
    # update to set any of these.
    it "system_create_node accepts the full REST create surface" do
      r = call("system_create_node", name: "fleet-node-2", template_id: template.id,
               description: "edge cell", enabled: false,
               public_address: "203.0.113.9", config: { "zone" => "edge-1" })
      expect(r[:success]).to be true
      node = System::Node.find(r.dig(:data, :node, :id))
      expect(node.description).to eq("edge cell")
      expect(node.enabled).to be false
      expect(node.public_address).to eq("203.0.113.9")
      expect(node.config).to include("zone" => "edge-1")
    end

    # Pin (not a fix): validation failures already come back as a clean
    # envelope via the call-level RecordInvalid rescue — the finding's
    # raw-error claim was wrong, and this stops it being re-filed.
    it "system_create_node returns a clean envelope on validation failure" do
      r = call("system_create_node", name: "", template_id: template.id)
      expect(r[:success]).to be false
      expect(r[:error]).to be_present
    end

    it "system_list_nodes returns account-scoped nodes" do
      n1 = create(:system_node, account: account, node_template: template, name: "a")
      n2 = create(:system_node, account: account, node_template: template, name: "b")
      r = call("system_list_nodes")
      expect(r[:success]).to be true
      ids = r[:data][:nodes].map { |n| n[:id] }
      expect(ids).to include(n1.id, n2.id)
    end

    it "system_get_node returns a node with full payload" do
      n = create(:system_node, account: account, node_template: template, name: "g")
      r = call("system_get_node", node_id: n.id)
      expect(r.dig(:data, :node, :id)).to eq(n.id)
      expect(r.dig(:data, :node, :ssh_key_fingerprint)).to be_present
    end

    it "system_get_node returns error for unknown id" do
      r = call("system_get_node", node_id: SecureRandom.uuid)
      expect(r[:success]).to be false
    end
  end

  describe "Templates" do
    let!(:other_account_template) { create(:system_node_template, account: create(:account)) }

    # IMP-bc6621864e93 — system_delete_template had zero coverage on either
    # surface; the in-use guard exists twice (inline count pre-check here,
    # dependent: :restrict_with_error on the model for REST) and neither
    # refusal path was tested anywhere.
    it "system_delete_template deletes an unused template and reports its name" do
      t2 = create(:system_node_template, account: account,
                  node_platform: platform_record, name: "delete-me")
      r = call("system_delete_template", template_id: t2.id)
      expect(r[:success]).to be true
      expect(r.dig(:data, :deleted)).to be true
      expect(r.dig(:data, :name)).to eq("delete-me")
      expect(System::NodeTemplate.exists?(t2.id)).to be false
    end

    it "system_delete_template refuses while nodes use the template, naming the count" do
      create(:system_node, account: account, node_template: template, name: "still-here")
      r = call("system_delete_template", template_id: template.id)
      expect(r[:success]).to be false
      expect(r[:error]).to include("in use by 1 node")
      expect(System::NodeTemplate.exists?(template.id)).to be true
    end

    it "system_delete_template does not reach another account's template" do
      # The call-level RecordNotFound rescue converts the scoped miss into a
      # clean envelope — the row must survive untouched.
      r = call("system_delete_template", template_id: other_account_template.id)
      expect(r[:success]).to be false
      expect(System::NodeTemplate.exists?(other_account_template.id)).to be true
    end

    # IMP-259f180d9af6 — clone is the primitive that completes the reuse-first
    # loop: system_discover_templates finds a near-match and, without this, the
    # agent had to rebuild it create_template + N assigns.
    it "system_clone_template copies the source and its module joins" do
      mod = create(:system_node_module, account: account, node_platform: platform_record,
                   category: category, name: "cloneable-mod")
      System::TemplateModule.create!(node_template: template, node_module: mod, enabled: true)

      r = call("system_clone_template", template_id: template.id, name: "cloned-template")
      expect(r[:success]).to be true
      clone = System::NodeTemplate.find(r.dig(:data, :template, :id))
      expect(clone.name).to eq("cloned-template")
      expect(clone.id).not_to eq(template.id)
      expect(clone.node_modules).to include(mod)
      expect(clone.account_id).to eq(account.id)
    end

    it "system_clone_template defaults the name when none is given" do
      r = call("system_clone_template", template_id: template.id)
      expect(r[:success]).to be true
      expect(r.dig(:data, :template, :name)).to eq("#{template.name}-copy")
    end

    it "system_clone_template surfaces the composition report rather than hiding it" do
      # The report rides the payload only when non-empty; a clean clone must
      # not invent the key.
      r = call("system_clone_template", template_id: template.id, name: "clean-clone")
      expect(r[:success]).to be true
      expect(r[:data]).not_to have_key(:composition_report)
    end

    it "system_clone_template does not reach another account's template" do
      r = call("system_clone_template", template_id: other_account_template.id, name: "nope")
      expect(r[:success]).to be false
      expect(r[:error]).to match(/couldn't find|not found/i)
    end

    it "system_list_templates is account-scoped" do
      template_id = template.id # force lazy let creation before the call
      r = call("system_list_templates")
      ids = r[:data][:templates].map { |t| t[:id] }
      expect(ids).to include(template_id)
      expect(ids).not_to include(other_account_template.id)
    end

    it "system_assign_module_to_template wires a TemplateModule" do
      mod = create(:system_node_module, account: account, node_platform: platform_record,
                   category: category, variety: "subscription", name: "tplmod")
      r = call("system_assign_module_to_template", template_id: template.id, module_id: mod.id)
      expect(r[:success]).to be true
      expect(System::TemplateModule.where(node_template: template, node_module: mod)).to exist
    end

    it "system_create_template builds an account-scoped NodeTemplate" do
      r = call("system_create_template", name: "edge-template", node_platform_id: platform_record.id,
                                         description: "edge nodes", enabled: true, admin_user: "ops",
                                         config: { "tier" => "edge" })
      expect(r[:success]).to be true
      expect(r.dig(:data, :template, :name)).to eq("edge-template")
      created = System::NodeTemplate.find(r.dig(:data, :template, :id))
      expect(created.account_id).to eq(account.id)
      expect(created.admin_user).to eq("ops")
      expect(created.config["tier"]).to eq("edge")
    end

    it "system_create_template returns an error when the model fails validation" do
      r = call("system_create_template", name: template.name, node_platform_id: platform_record.id)
      expect(r[:success]).to be false
    end
  end

  # === Template write surface (IMP-5c340c72ff9a) ===
  # The declared schema disagreed with the model on node_platform_id, and
  # system_update_template accepted only name + description — so config,
  # enabled, public and admin_user were settable at create time and unfixable
  # afterwards over MCP.
  describe "Template write surface" do
    describe "system_create_template — node_platform_id" do
      it "declares node_platform_id required, matching the model's belongs_to" do
        parameters = described_class.action_definitions["system_create_template"][:parameters]
        expect(parameters[:node_platform_id][:required]).to be true
      end

      it "refuses a create without node_platform_id and names the missing parameter" do
        # Materialize the account first: its bootstrap seeds a default template
        # catalog on first reference, which would otherwise land inside the
        # delta below and read as "the refused create persisted something".
        tool
        result = nil

        expect do
          result = call("system_create_template", name: "no-platform-#{SecureRandom.hex(3)}")
        end.not_to change { System::NodeTemplate.count }

        expect(result[:success]).to be false
        expect(result[:error]).to match(/node_platform_id/i)
      end
    end

    describe "system_update_template — mutable fields" do
      it "documents every field the model treats as mutable" do
        parameters = described_class.action_definitions["system_update_template"][:parameters]
        expect(parameters.keys)
          .to include(:name, :description, :enabled, :public, :node_platform_id, :admin_user, :config)
      end

      it "round-trips config, enabled, public, admin_user and node_platform_id" do
        retarget = create(:system_node_platform, account: account)

        result = call("system_update_template", template_id: template.id,
                                                description: "retuned",
                                                enabled: false, public: true, admin_user: "ops",
                                                node_platform_id: retarget.id,
                                                config: { "init_script" => "bootstrap.sh",
                                                          "boot_mode" => "uefi" })

        expect(result[:success]).to be true
        template.reload
        expect(template.description).to eq("retuned")
        expect(template.enabled).to be false
        expect(template.public).to be true
        expect(template.admin_user).to eq("ops")
        expect(template.node_platform_id).to eq(retarget.id)
        expect(template.config["init_script"]).to eq("bootstrap.sh")
        expect(template.config["boot_mode"]).to eq("uefi")
      end

      it "returns an error result rather than raising when the update is invalid" do
        clash = create(:system_node_template, account: account, node_platform: platform_record,
                                              name: "clash-#{SecureRandom.hex(3)}")

        result = call("system_update_template", template_id: template.id, name: clash.name)

        expect(result[:success]).to be false
        expect(result[:error]).to match(/update failed/i)
      end
    end
  end

  # === TemplateModule join attributes (IMP-5c340c72ff9a) ===
  # priority, enabled, config and recommends_override were unreachable from
  # every write API, which made the documented-correct removal (disable, never
  # destroy — destroying nullifies source_template_module_id and orphans
  # derived assignments) literally inexpressible.
  describe "TemplateModule join attributes" do
    let(:join_cat_a) { create(:system_node_module_category, account: account, name: "join-a-#{SecureRandom.hex(3)}") }
    let(:join_cat_b) { create(:system_node_module_category, account: account, name: "join-b-#{SecureRandom.hex(3)}") }

    def join_module(name, category: join_cat_a, variety: "subscription")
      create(:system_node_module, account: account, node_platform: platform_record,
             category: category, variety: variety, name: "#{name}-#{SecureRandom.hex(3)}")
    end

    def assign(node_module, **rest)
      call("system_assign_module_to_template",
           template_id: template.id, module_id: node_module.id, **rest)
    end

    def update_join(node_module, **rest)
      call("system_update_template_module",
           template_id: template.id, module_id: node_module.id, **rest)
    end

    it "documents the join attributes on both the assign and update actions" do
      defs = described_class.action_definitions

      assign_params = defs.fetch("system_assign_module_to_template")[:parameters]
      expect(assign_params.keys).to include(:priority, :enabled, :config, :recommends_override)

      update_params = defs.fetch("system_update_template_module")[:parameters]
      expect(update_params[:template_id][:required]).to be true
      expect(update_params[:module_id][:required]).to be true
      expect(update_params.keys).to include(:priority, :enabled, :config, :recommends_override)
    end

    it "gates the update action on the same permission as assign/unassign" do
      expect(described_class::ACTION_PERMISSIONS["system_update_template_module"])
        .to eq(described_class::ACTION_PERMISSIONS["system_assign_module_to_template"])
    end

    it "persists priority, enabled, config and recommends_override at assign time" do
      mod = join_module("attrs")

      result = assign(mod, priority: 40, enabled: false, config: { "port" => 8080 },
                           recommends_override: { "excluded" => [ "docs" ] })

      expect(result[:success]).to be true
      join = System::TemplateModule.find(result.dig(:data, :template_module_id))
      expect(join.priority).to eq(40)
      expect(join.enabled).to be false
      expect(join.config["port"]).to eq(8080)
      expect(join.recommends_override["excluded"]).to eq([ "docs" ])
    end

    it "updates priority, config and recommends_override on an existing join" do
      mod = join_module("update-attrs")
      expect(assign(mod)[:success]).to be true

      result = update_join(mod, priority: 7, config: { "threads" => 4 },
                                recommends_override: { "included" => [ "extras" ] })

      expect(result[:success]).to be true
      join = System::TemplateModule.find_by!(node_template: template, node_module: mod)
      expect(join.priority).to eq(7)
      expect(join.config["threads"]).to eq(4)
      expect(join.recommends_override["included"]).to eq([ "extras" ])
    end

    it "disables a join without destroying it — the documented-correct removal" do
      mod = join_module("soft-remove")
      expect(assign(mod)[:success]).to be true
      join = System::TemplateModule.find_by!(node_template: template, node_module: mod)

      result = nil
      expect do
        result = update_join(mod, enabled: false)
      end.not_to change { System::TemplateModule.where(node_template: template).count }

      expect(result[:success]).to be true
      expect(join.reload.enabled).to be false
      expect(result.dig(:data, :template_module, :enabled)).to be false
    end

    it "404s the update when the module is not assigned to the template" do
      result = update_join(join_module("never-assigned"), enabled: false)

      expect(result[:success]).to be false
      expect(result[:error]).to match(/not assigned|no assignment/i)
    end

    # === Conflict-guard integrity ===
    # TemplateExpansionService only ships ENABLED joins, so a disabled join
    # cannot collide with anything — and enabling one is the moment it starts
    # shipping, which is where the guard has to run.
    it "accepts a disabled assignment that would collide if it were enabled" do
      first  = join_module("dis-first", variety: "instance")
      second = join_module("dis-second", variety: "instance")
      expect(assign(first)[:success]).to be true

      result = assign(second, enabled: false)

      expect(result[:success]).to be true
      expect(System::TemplateModule.find_by(node_template: template, node_module: second).enabled).to be false
    end

    it "runs the conflict guard when a disabled join is enabled, and leaves it disabled" do
      first  = join_module("enable-first", variety: "instance")
      second = join_module("enable-second", variety: "instance")
      expect(assign(first)[:success]).to be true
      expect(assign(second, enabled: false)[:success]).to be true

      result = update_join(second, enabled: true)

      expect(result[:success]).to be false
      expect(result[:error]).to include(first.name).and include(second.name)
      expect(System::TemplateModule.find_by(node_template: template, node_module: second).enabled).to be false
    end

    it "drops a disabled join out of the conflict baseline for later assignments" do
      first  = join_module("baseline-first", variety: "instance")
      second = join_module("baseline-second", variety: "instance")
      expect(assign(first)[:success]).to be true
      expect(assign(second)[:success]).to be false

      expect(update_join(first, enabled: false)[:success]).to be true

      expect(assign(second)[:success]).to be true
    end

    it "still refuses an ENABLED assignment that collides — the guard is not bypassed" do
      first  = join_module("guard-first", variety: "instance")
      second = join_module("guard-second", variety: "instance")
      expect(assign(first)[:success]).to be true

      result = nil
      expect do
        result = assign(second, priority: 10, config: { "x" => 1 })
      end.not_to change { System::TemplateModule.where(node_template: template).count }

      expect(result[:success]).to be false
      expect(result[:error]).to include(first.name).and include(second.name)
    end

    it "re-enables a join that introduces no conflict" do
      mod = join_module("reenable")
      expect(assign(mod, enabled: false)[:success]).to be true

      result = update_join(mod, enabled: true)

      expect(result[:success]).to be true
      expect(System::TemplateModule.find_by(node_template: template, node_module: mod).enabled).to be true
    end

    # === String-boolean cast integrity ===
    # `enabled` is cast via ActiveModel::Type::Boolean before the conflict
    # guard above ever sees it, so a caller that sends the STRING "true"/
    # "false" (a common shape for MCP clients that stringify params) must be
    # normalized identically to a real boolean — never treated as truthy
    # because it's a non-empty string.
    it "refuses enabling a conflicting join when enabled arrives as the string 'true'" do
      first  = join_module("cast-true-first", variety: "instance")
      second = join_module("cast-true-second", variety: "instance")
      expect(assign(first)[:success]).to be true
      expect(assign(second, enabled: false)[:success]).to be true

      result = update_join(second, enabled: "true")

      expect(result[:success]).to be false
      expect(result[:error]).to include(first.name).and include(second.name)
      expect(System::TemplateModule.find_by(node_template: template, node_module: second).enabled).to be false
    end

    it "stages a disabled join when enabled arrives as the string 'false'" do
      first  = join_module("cast-false-first", variety: "instance")
      second = join_module("cast-false-second", variety: "instance")
      expect(assign(first)[:success]).to be true

      result = assign(second, enabled: "false")

      expect(result[:success]).to be true
      expect(System::TemplateModule.find_by(node_template: template, node_module: second).enabled).to be false
    end
  end

  # === Template composition analysis (IMP-20b3eb50da30) ===
  # compose_preview — the design-time conflict/footprint/graph analysis — was
  # REST-only, so an agent composing a template could not see what the operator
  # UI sees. The MCP action mirrors NodeTemplatesController#compose_preview and
  # persists nothing; the assignment write path now refuses the error-severity
  # conflicts that analysis reports instead of leaving a disabled React button
  # as the only enforcement.
  describe "Template composition analysis" do
    let(:cat_a) { create(:system_node_module_category, account: account, name: "cat-a-#{SecureRandom.hex(3)}") }
    let(:cat_b) { create(:system_node_module_category, account: account, name: "cat-b-#{SecureRandom.hex(3)}") }

    # Names that won't collide with the account bootstrap's default catalog.
    def composition_module(name, category: cat_a, variety: "subscription")
      create(:system_node_module, account: account, node_platform: platform_record,
             category: category, variety: variety, name: "#{name}-#{SecureRandom.hex(3)}")
    end

    describe "system_compose_preview_template" do
      it "returns modules, conflicts, footprint, dependency_graph, warnings and errors" do
        a = composition_module("preview-a")
        b = composition_module("preview-b", category: cat_b)

        r = call("system_compose_preview_template", module_ids: [ a.id, b.id ])

        expect(r[:success]).to be true
        expect(r[:data].keys).to include(:modules, :conflicts, :footprint, :dependency_graph, :warnings, :errors)
        expect(r.dig(:data, :modules).map { |m| m[:id] }).to match_array([ a.id, b.id ])
        expect(r.dig(:data, :footprint, :module_count)).to eq(2)
        expect(r.dig(:data, :dependency_graph, :nodes).map { |n| n[:id] }).to match_array([ a.id, b.id ])
      end

      it "persists nothing" do
        a = composition_module("inert-a", variety: "instance")
        b = composition_module("inert-b", variety: "instance")

        expect do
          call("system_compose_preview_template", module_ids: [ a.id, b.id ])
        end.not_to change { [ System::TemplateModule.count, System::NodeTemplate.count, System::NodeModule.count ] }
      end

      it "reports an instance-variety collision at error severity" do
        a = composition_module("coll-a", variety: "instance")
        b = composition_module("coll-b", variety: "instance")

        r = call("system_compose_preview_template", module_ids: [ a.id, b.id ])

        collision = r.dig(:data, :conflicts).find { |c| c[:kind] == "instance_variety_collision" }
        expect(collision).to be_present
        expect(collision[:severity]).to eq("error")
      end

      it "errors when module_ids is empty" do
        r = call("system_compose_preview_template", module_ids: [])
        expect(r[:success]).to be false
        expect(r[:error]).to match(/module_ids/i)
      end

      it "errors when no module matches, so a foreign id leaks no existence" do
        foreign = create(:system_node_module, account: create(:account))

        r = call("system_compose_preview_template", module_ids: [ foreign.id ])

        expect(r[:success]).to be false
        expect(r[:error]).to match(/no matching modules/i)
      end

      it "is gated on system.templates.read — it reads, it never writes" do
        expect(described_class::ACTION_PERMISSIONS["system_compose_preview_template"])
          .to eq("system.templates.read")
      end

      it "is documented in action_definitions so its contract is discoverable" do
        definition = described_class.action_definitions["system_compose_preview_template"]
        expect(definition).to be_present
        expect(definition[:parameters][:module_ids][:required]).to be true
      end
    end

    describe "system_assign_module_to_template conflict enforcement" do
      def assign(node_module)
        call("system_assign_module_to_template", template_id: template.id, module_id: node_module.id)
      end

      it "blocks an instance-variety collision and names both modules" do
        first  = composition_module("inst-first", variety: "instance")
        second = composition_module("inst-second", variety: "instance")
        expect(assign(first)[:success]).to be true

        result = nil
        expect do
          result = assign(second)
        end.not_to change { System::TemplateModule.where(node_template: template).count }

        expect(result[:success]).to be false
        expect(result[:error]).to include(first.name).and include(second.name)
        expect(result[:error]).to match(/instance-variety|instance_variety/i)
      end

      it "blocks a declared Conflicts: relation against an already-assigned module" do
        installed = composition_module("conf-installed")
        incoming  = composition_module("conf-incoming", category: cat_b)
        create(:system_module_dependency, node_module: incoming, dependency: installed,
               dependency_type: "conflicts", required: false)
        expect(assign(installed)[:success]).to be true

        result = nil
        expect do
          result = assign(incoming)
        end.not_to change { System::TemplateModule.where(node_template: template).count }

        expect(result[:success]).to be false
        expect(result[:error]).to include(incoming.name).and include(installed.name)
      end

      it "returns protected_spec warnings alongside a successful assignment" do
        claimer = composition_module("warn-claimer")
        claimer.update!(protected_spec: "/etc/shadow")
        broad = composition_module("warn-broad", category: cat_b)
        broad.update!(file_spec: "/etc/**")
        expect(assign(claimer)[:success]).to be true

        result = assign(broad)

        expect(result[:success]).to be true
        expect(System::TemplateModule.where(node_template: template, node_module: broad)).to exist
        warning = Array(result.dig(:data, :warnings)).first
        expect(warning[:kind]).to eq("protected_spec_overlap")
        expect(warning[:severity]).to eq("warning")
      end

      it "leaves a clean assignment's payload byte-for-byte unchanged" do
        mod = composition_module("clean")

        result = assign(mod)

        expect(result[:success]).to be true
        expect(result[:data].keys).to match_array(%i[assigned template_module_id])
      end
    end
  end

  # === Template blast radius (IMP-4d76a6b76146) ===
  # TemplateApprovalPolicy classifies a template mutation by how much LIVE fleet
  # it reaches, but its only callers were fulfill_capability_request (which
  # always passes template: nil) and TemplateClosureDriftSensor (which sees the
  # damage a tick later). A direct join mutation over MCP consulted it nowhere,
  # so an assignment onto a template carrying running instances propagated on
  # the next apply with no classification recorded anywhere.
  #
  # The gate RECORDS rather than refuses — see record_template_blast_radius for
  # the full reasoning. These examples pin both halves of that: the record is
  # made when there is live fleet, and NOTHING changes when there isn't.
  describe "Template mutation blast radius" do
    let(:br_category) { create(:system_node_module_category, account: account, name: "br-cat-#{SecureRandom.hex(3)}") }

    def br_module(name)
      create(:system_node_module, account: account, node_platform: platform_record,
             category: br_category, variety: "subscription", name: "#{name}-#{SecureRandom.hex(3)}")
    end

    def live_node!(count = 1)
      count.times do
        node = create(:system_node, account: account, node_template: template)
        create(:system_node_instance, :running, node: node)
      end
    end

    def events
      System::FleetEvent.where(account: account, kind: "system.template_mutation")
    end

    context "when the template carries live fleet" do
      before { live_node! }

      it "lets the assignment through but reports the blast radius it will reach on next apply" do
        mod = br_module("live-assign")

        result = call("system_assign_module_to_template", template_id: template.id, module_id: mod.id)

        expect(result[:success]).to be true
        expect(System::TemplateModule.where(node_template: template, node_module: mod)).to exist
        radius = result.dig(:data, :blast_radius)
        expect(radius[:requires_approval]).to be true
        expect(radius[:provisioned_node_count]).to eq(1)
        expect(radius[:reason]).to match(/propagates to live fleet/)
      end

      it "records a durable FleetEvent naming the template, the module and the count" do
        mod = br_module("live-event")

        expect do
          call("system_assign_module_to_template", template_id: template.id, module_id: mod.id)
        end.to change { events.count }.by(1)

        event = events.order(:created_at).last
        expect(event.severity).to eq("medium")
        expect(event.node_module_id).to eq(mod.id)
        expect(event.correlation_id).to eq("template_mutation:#{template.id}")
        expect(event.payload["change"]).to eq("module_assigned")
        expect(event.payload["template_id"]).to eq(template.id)
        expect(event.payload["node_module_name"]).to eq(mod.name)
        expect(event.payload["provisioned_node_count"]).to eq(1)
      end

      it "counts every live node on the template, not just the first" do
        live_node!(2)
        mod = br_module("live-count")

        result = call("system_assign_module_to_template", template_id: template.id, module_id: mod.id)

        expect(result.dig(:data, :blast_radius, :provisioned_node_count)).to eq(3)
      end

      # The conflict guard and the blast-radius record are DIFFERENT checks: a
      # refused assignment never reaches the write, so it reaches no fleet and
      # leaves no mutation record either.
      it "records nothing when the composition-conflict guard refuses the assignment" do
        first  = br_module("conflict-first")
        second = create(:system_node_module, account: account, node_platform: platform_record,
                        category: br_category, variety: "instance", name: "conf-inst-a-#{SecureRandom.hex(3)}")
        third  = create(:system_node_module, account: account, node_platform: platform_record,
                        category: br_category, variety: "instance", name: "conf-inst-b-#{SecureRandom.hex(3)}")
        expect(call("system_assign_module_to_template", template_id: template.id, module_id: first.id)[:success]).to be true
        expect(call("system_assign_module_to_template", template_id: template.id, module_id: second.id)[:success]).to be true

        result = nil
        expect do
          result = call("system_assign_module_to_template", template_id: template.id, module_id: third.id)
        end.not_to change { events.where("payload->>'node_module_name' = ?", third.name).count }

        expect(result[:success]).to be false
      end

      # A disabled join is not expanded onto any instance, so it reaches no live
      # node — the same reasoning that lets it skip the conflict check.
      it "stays silent for an assignment that does not ship" do
        mod = br_module("disabled-assign")

        result = nil
        expect do
          result = call("system_assign_module_to_template",
                        template_id: template.id, module_id: mod.id, enabled: false)
        end.not_to change { events.count }

        expect(result[:success]).to be true
        expect(result[:data]).not_to have_key(:blast_radius)
      end

      it "records DISABLING a shipping join — it takes the module off live fleet" do
        mod = br_module("disable-join")
        call("system_assign_module_to_template", template_id: template.id, module_id: mod.id)

        result = nil
        expect do
          result = call("system_update_template_module",
                        template_id: template.id, module_id: mod.id, enabled: false)
        end.to change { events.count }.by(1)

        expect(result.dig(:data, :blast_radius, :requires_approval)).to be true
        expect(events.order(:created_at).last.payload["change"]).to eq("module_disabled")
      end

      it "records ENABLING a staged join" do
        mod = br_module("enable-join")
        call("system_assign_module_to_template", template_id: template.id, module_id: mod.id, enabled: false)

        expect do
          call("system_update_template_module", template_id: template.id, module_id: mod.id, enabled: true)
        end.to change { events.count }.by(1)

        expect(events.order(:created_at).last.payload["change"]).to eq("module_enabled")
      end

      it "stays silent for an edit to a join that neither shipped before nor ships after" do
        mod = br_module("inert-edit")
        call("system_assign_module_to_template", template_id: template.id, module_id: mod.id, enabled: false)

        result = nil
        expect do
          result = call("system_update_template_module",
                        template_id: template.id, module_id: mod.id, priority: 90)
        end.not_to change { events.count }

        expect(result[:success]).to be true
        expect(result[:data]).not_to have_key(:blast_radius)
      end

      it "records the unassignment of a shipping join — the most destructive join mutation" do
        mod = br_module("unassign-live")
        call("system_assign_module_to_template", template_id: template.id, module_id: mod.id)

        result = nil
        expect do
          result = call("system_unassign_module_from_template", template_id: template.id, module_id: mod.id)
        end.to change { events.count }.by(1)

        expect(result.dig(:data, :blast_radius, :provisioned_node_count)).to eq(1)
        expect(events.order(:created_at).last.payload["change"]).to eq("module_unassigned")
      end

      it "stays silent unassigning a join that was never shipping" do
        mod = br_module("unassign-disabled")
        call("system_assign_module_to_template", template_id: template.id, module_id: mod.id, enabled: false)

        result = nil
        expect do
          result = call("system_unassign_module_from_template", template_id: template.id, module_id: mod.id)
        end.not_to change { events.count }

        expect(result[:success]).to be true
        expect(result[:data]).not_to have_key(:blast_radius)
      end

      # One correlation_id per template is the only template mutation history
      # that exists today — system_inspect_correlation walks it in emission
      # order. Template versioning proper is a separate piece of work.
      it "files every mutation on one template under a single correlation_id" do
        first  = br_module("corr-first")
        second = br_module("corr-second")
        call("system_assign_module_to_template", template_id: template.id, module_id: first.id)
        call("system_assign_module_to_template", template_id: template.id, module_id: second.id)
        call("system_unassign_module_from_template", template_id: template.id, module_id: first.id)

        chain = events.where(correlation_id: "template_mutation:#{template.id}").order(:created_at)
        expect(chain.count).to eq(3)
        expect(chain.map { |e| e.payload["change"] })
          .to eq(%w[module_assigned module_assigned module_unassigned])
      end
    end

    context "when the template carries no live fleet" do
      it "leaves the assign payload byte-for-byte unchanged and records nothing" do
        mod = br_module("no-fleet-assign")

        result = nil
        expect do
          result = call("system_assign_module_to_template", template_id: template.id, module_id: mod.id)
        end.not_to change { System::FleetEvent.where(account: account).count }

        expect(result[:data].keys).to match_array(%i[assigned template_module_id])
      end

      # A node with only a TERMINATED instance is not live fleet — the tool must
      # agree with TemplateApprovalPolicy's own LIVE_INSTANCE_SCOPE rather than
      # deriving a second opinion about what "provisioned" means.
      it "does not count a node whose only instance is terminated" do
        node = create(:system_node, account: account, node_template: template)
        create(:system_node_instance, node: node, status: "terminated")
        mod = br_module("terminated-only")

        result = nil
        expect do
          result = call("system_assign_module_to_template", template_id: template.id, module_id: mod.id)
        end.not_to change { System::FleetEvent.where(account: account).count }

        expect(result[:data]).not_to have_key(:blast_radius)
      end
    end
  end

  # IMP-244e1127d759 — system_module_diff had zero coverage. The diff MATH is
  # covered by module_diff_service_spec; what lives ONLY in this handler is
  # the account-scoping join on both version lookups (the code that stops a
  # caller diffing another tenant's versions) and the response envelope,
  # including mount_changes, which nothing asserted anywhere.
  describe "system_module_diff" do
    let(:diff_mod) do
      create(:system_node_module, account: account, node_platform: platform_record,
             category: category, name: "diffable")
    end
    let(:ver_a) do
      System::NodeModuleVersion.create!(node_module: diff_mod, version_number: 1,
                                        mask: [], file_spec: [], package_spec: [], config: {})
    end
    let(:ver_b) do
      System::NodeModuleVersion.create!(node_module: diff_mod, version_number: 2,
                                        mask: [], file_spec: [], package_spec: [], config: {})
    end

    it "returns the full six-field envelope, mount_changes included" do
      r = call("system_module_diff", version_a_id: ver_a.id, version_b_id: ver_b.id)
      expect(r[:success]).to be true
      expect(r[:data].keys).to include(:unchanged, :fingerprint_a, :fingerprint_b,
                                       :file_changes, :package_changes, :mount_changes)
    end

    it "cannot diff another account's module versions" do
      other_account = create(:account)
      other_mod = create(:system_node_module, account: other_account)
      other_ver = System::NodeModuleVersion.create!(node_module: other_mod, version_number: 1,
                                                    mask: [], file_spec: [], package_spec: [], config: {})
      r = call("system_module_diff", version_a_id: ver_a.id, version_b_id: other_ver.id)
      expect(r[:success]).to be false
      # The scoped .find misses and the call-level RecordNotFound rescue turns
      # it into a clean envelope — the isolation, not a raw crash.
      expect(r[:error]).to match(/couldn't find|not found/i)
    end
  end

  # IMP-0cea3952202c — AI-first parity: an agent could DELETE a module it had
  # no way to author or repair, system.modules.create was registered but
  # referenced by no MCP action, and mark_canary had no inverse.
  describe "Modules — create / update / unmark canary" do
    it "system_create_module authors a module from the REST create surface" do
      r = call("system_create_module", name: "authored-1", node_platform_id: platform_record.id,
               category_id: category.id, variety: "subscription",
               description: "authored over MCP", priority: 40,
               package_spec: "curl\njq", config: { "zone" => "edge" })
      expect(r[:success]).to be true
      m = System::NodeModule.find(r.dig(:data, :node_module, :id))
      expect(m.name).to eq("authored-1")
      expect(m.description).to eq("authored over MCP")
      expect(m.priority).to eq(40)
      expect(m.config).to include("zone" => "edge")
      expect(m.account_id).to eq(account.id)
    end

    it "system_create_module returns a clean envelope on validation failure" do
      r = call("system_create_module", name: "", node_platform_id: platform_record.id)
      expect(r[:success]).to be false
      expect(r[:error]).to be_present
    end

    it "system_update_module edits an existing module" do
      m = create(:system_node_module, account: account, node_platform: platform_record,
                 category: category, name: "editable", description: "before")
      r = call("system_update_module", module_id: m.id, description: "after", enabled: false)
      expect(r[:success]).to be true
      m.reload
      expect(m.description).to eq("after")
      expect(m.enabled).to be false
    end

    it "system_update_module refuses an empty edit" do
      m = create(:system_node_module, account: account, node_platform: platform_record,
                 category: category, name: "untouched")
      r = call("system_update_module", module_id: m.id)
      expect(r[:success]).to be false
    end

    it "system_update_module does not reach another account's module" do
      other = create(:system_node_module, account: create(:account))
      r = call("system_update_module", module_id: other.id, description: "hijack")
      expect(r[:success]).to be false
      expect(other.reload.description).not_to eq("hijack")
    end

    it "system_unmark_module_canary clears the flag mark_canary sets" do
      m = create(:system_node_module, account: account, node_platform: platform_record,
                 category: category, name: "canary-target")
      call("system_module_mark_canary", module_id: m.id)
      expect(System::Honeypot::CanaryModuleService.canary?(node_module: m.reload)).to be true

      r = call("system_unmark_module_canary", module_id: m.id)
      expect(r[:success]).to be true
      expect(System::Honeypot::CanaryModuleService.canary?(node_module: m.reload)).to be false
    end
  end

  describe "Modules + Versions" do
    let!(:mod) do
      create(:system_node_module,
             account: account, node_platform: platform_record, category: category,
             variety: "subscription", name: "modlist-1")
    end
    let!(:v1) do
      System::NodeModuleVersion.create!(
        node_module: mod, version_number: 1, mask: [], file_spec: [], package_spec: [], config: {}
      )
    end

    it "system_list_modules returns account modules" do
      r = call("system_list_modules")
      ids = r[:data][:modules].map { |m| m[:id] }
      expect(ids).to include(mod.id)
    end

    it "system_list_module_versions returns versions newest-first" do
      v2 = System::NodeModuleVersion.create!(
        node_module: mod, version_number: 2, mask: [], file_spec: [], package_spec: [], config: {}
      )
      r = call("system_list_module_versions", module_id: mod.id)
      numbers = r[:data][:versions].map { |v| v[:version_number] }
      expect(numbers).to eq([ 2, 1 ])
      _ = v2
    end

    it "system_promote_module_version transitions through the lifecycle" do
      r = call("system_promote_module_version", module_version_id: v1.id, target_state: "staging")
      expect(r[:success]).to be true
      expect(r.dig(:data, :version, :promotion_state)).to eq("staging")
    end

    it "system_promote_module_version rejects invalid transitions" do
      r = call("system_promote_module_version", module_version_id: v1.id, target_state: "live")
      expect(r[:success]).to be false
      expect(r[:error]).to include("cannot transition from built to live")
    end
  end

  describe "Instances" do
    let(:node) { create(:system_node, account: account, node_template: template, name: "ifn") }
    let!(:running_instance) { create(:system_node_instance, :running, node: node) }

    it "system_list_instances filters by node_id" do
      other_node = create(:system_node, account: account, node_template: template, name: "other")
      _other_inst = create(:system_node_instance, :running, node: other_node)
      r = call("system_list_instances", node_id: node.id)
      expect(r[:data][:instances].map { |i| i[:id] }).to eq([ running_instance.id ])
    end

    it "system_get_instance returns the full payload" do
      r = call("system_get_instance", instance_id: running_instance.id)
      expect(r.dig(:data, :instance, :status)).to eq("running")
      expect(r.dig(:data, :instance)).to have_key(:running_module_digests)
    end

    it "system_update_instance updates mutable metadata + IP fields" do
      r = call("system_update_instance", instance_id: running_instance.id,
                                         name: "renamed-instance", private_ip_address: "10.0.5.5",
                                         vpn_ip_address: "100.64.0.5", config: { "label" => "edge" })
      expect(r[:success]).to be true
      expect(r.dig(:data, :instance, :name)).to eq("renamed-instance")
      expect(r.dig(:data, :instance, :private_ip)).to eq("10.0.5.5")

      running_instance.reload
      expect(running_instance.name).to eq("renamed-instance")
      expect(running_instance.vpn_ip_address).to eq("100.64.0.5")
      expect(running_instance.config["label"]).to eq("edge")
      expect(running_instance.status).to eq("running") # status not touched by update_instance
    end

    it "system_update_instance returns an error for an unknown instance id" do
      r = call("system_update_instance", instance_id: SecureRandom.uuid, name: "nope")
      expect(r[:success]).to be false
    end
  end

  # F8-02: every ACTION_PERMISSIONS slug must be grantable — the audit found
  # mission-core actions mapped to "system.node_instances.control", which has
  # no Permission record anywhere, permanently denying all non-super-admins.
  describe "delegation-action permission slugs" do
    let(:operator) { create(:user, account: account, permissions: %w[system.node_instances.manage]) }
    let(:operator_tool) { described_class.new(account: account, user: operator) }

    %w[system_grant_instance_mcp_tools system_grant_instance_peer_skills
       system_launch_agent_fleet system_mint_peer_capability_token
       system_refresh_instance_modules].each do |action|
      it "permits #{action} for a holder of system.node_instances.manage" do
        expect(operator_tool.send(:action_permitted?, action)).to be true
      end
    end

    # Campaign 019f5885 inc3 — CI runner lease actions map to 3 brand-new
    # permission slugs (added to CORE_PERMISSIONS, not reused from an
    # existing family). F8-02's failure mode was a slug with NO Permission
    # record anywhere; assert both halves — the slug is really in the
    # catalog (grantable at all) AND holding it actually satisfies
    # action_permitted? (the mapping itself is correct).
    {
      "system_lease_ci_runner"       => "system.ci_runner_leases.create",
      "system_release_ci_runner"     => "system.ci_runner_leases.update",
      "system_list_ci_runner_leases" => "system.ci_runner_leases.read"
    }.each do |action, permission_slug|
      it "#{action} maps to a real, grantable #{permission_slug} permission" do
        expect(described_class::ACTION_PERMISSIONS.fetch(action)).to eq(permission_slug)
        expect(::Permissions.permission_exists?(permission_slug)).to be true

        holder = create(:user, account: account, permissions: [ permission_slug ])
        holder_tool = described_class.new(account: account, user: holder)
        expect(holder_tool.send(:action_permitted?, action)).to be true
      end
    end
  end

  # IMP-9030413bc292 — action_permitted? used to read `@user.nil?` as
  # "internal/system caller" and return true. That premise (MCP callers always
  # carry a user) predates instance principals: an mTLS node cert authenticates
  # with NO user, so every per-action permission in ACTION_PERMISSIONS was
  # skipped and the peer's per-tool grant glob was the only remaining control.
  # The bypass is now two EXPLICIT signals; a bare userless call fails closed.
  describe "principal authorization (IMP-9030413bc292)" do
    # Worker-only by design: system.module_builds.dispatch is granted to no
    # role except system_worker, and the tool itself says so in
    # WORKER_ONLY_ACTIONS — the sharpest example of a tier the old bypass
    # skipped. That's a statement about role GRANTS, not effective access —
    # see "system.admin short-circuits WORKER_ONLY_ACTIONS" below for the
    # super_admin exception and why the plain admin role isn't one.
    let(:worker_only_action) { "system_dispatch_module_build_batch" }
    let(:gated_action)       { "system_create_node" }

    it "denies a bare userless call — no user, no internal flag, no instance grant" do
      bare = described_class.new(account: account, user: nil)

      expect(bare.send(:action_permitted?, gated_action)).to be false
      expect(bare.send(:action_permitted?, worker_only_action)).to be false
    end

    it "surfaces the denial as an error_result rather than executing the action" do
      bare = described_class.new(account: account, user: nil)

      expect { @result = bare.execute(params: { action: gated_action, template_id: template.id, name: "bare" }) }
        .not_to change(::System::Node, :count)
      expect(@result[:success]).to be false
      expect(@result[:error]).to include("permission denied")
    end

    it "preserves the documented internal/system bypass when declared explicitly" do
      internal = described_class.new(account: account, user: nil, internal: true)

      expect(internal.send(:action_permitted?, gated_action)).to be true
      expect(internal.send(:action_permitted?, worker_only_action)).to be true
    end

    # Behaviour preservation for the live dev-cell instance principal: the
    # streamable controller grant-gates the specific tool name via
    # Mcp::Principal#may_invoke? BEFORE dispatch, and the registrar marks the
    # call. That marking — not the nil user — is what carries it through here.
    it "still permits a grant-gated MCP instance principal" do
      instance_call = described_class.new(account: account, user: nil)
      instance_call.instance_authorized = true

      expect(instance_call.send(:action_permitted?, gated_action)).to be true
      expect(instance_call.send(:action_permitted?, worker_only_action)).to be true
    end

    it "executes a granted action for a grant-gated instance principal exactly as before" do
      instance_call = described_class.new(account: account, user: nil)
      instance_call.instance_authorized = true

      result = instance_call.execute(params: {
        action: gated_action, template_id: template.id, name: "instance-created"
      })

      expect(result[:success]).to be true
      expect(result.dig(:data, :node, :name)).to eq("instance-created")
    end

    it "keeps enforcing per-action permissions for a user principal" do
      unprivileged = create(:user, account: account, permissions: %w[system.nodes.read])
      user_tool = described_class.new(account: account, user: unprivileged)

      expect(user_tool.send(:action_permitted?, "system_list_nodes")).to be true
      expect(user_tool.send(:action_permitted?, gated_action)).to be false
    end

    # IMP-36a99b8167f7 — WORKER_ONLY_ACTIONS' comment and denial message used
    # to claim, unconditionally, that "agent/operator principals cannot
    # invoke this action." False for a system.admin holder: has_permission?
    # short-circuits on system.admin (app/models/user.rb) and returns true
    # for every permission name before WORKER_ONLY_ACTIONS is ever consulted
    # — action_permitted? doesn't special-case these actions at all, it just
    # calls has_permission? like any other. Pinned here so a "fix" that makes
    # this deny unconditionally (i.e. matches the old, false comment) goes
    # red instead of silently becoming correct-per-the-comment.
    it "still permits a system.admin holder through the worker-only exclusion" do
      super_admin      = create(:user, :super_admin, account: account)
      super_admin_tool = described_class.new(account: account, user: super_admin)

      expect(super_admin_tool.send(:action_permitted?, worker_only_action)).to be true
    end

    # The plain admin/owner account roles are NOT system.admin holders —
    # config/permissions.rb's ROLES hash only puts "system.admin" in
    # super_admin's permissions array, so :admin here holds admin.access
    # (admin-panel access) but not the grant-everything permission. They hit
    # the same denial as any other non-worker caller.
    it "still denies the plain admin account role — it lacks system.admin, not just the explicit grant" do
      admin      = create(:user, :admin, account: account)
      admin_tool = described_class.new(account: account, user: admin)

      expect(admin_tool.send(:action_permitted?, worker_only_action)).to be false
    end
  end

  # IMP-2818: system_refresh_instance_modules built a System::Task with columns
  # that don't exist (node_instance/kind/source/payload), so the resulting
  # ActiveModel::UnknownAttributeError slipped past the RecordInvalid rescue → 500.
  # The action was only ever permission-tested (never executed), which is how it shipped.
  describe "system_refresh_instance_modules (IMP-2818)" do
    let(:node) { create(:system_node, account: account, node_template: template, name: "refresh") }
    let(:instance) { create(:system_node_instance, :running, node: node) }

    it "queues a sync_modules task against the instance instead of raising" do
      result = nil
      expect { result = call("system_refresh_instance_modules", instance_id: instance.id) }
        .to change(::System::Task, :count).by(1)

      expect(result[:success]).to be true
      expect(result[:data][:refreshed]).to be true
      expect(result[:data][:task_id]).to be_present

      task = ::System::Task.order(:created_at).last
      expect(task).to have_attributes(
        command: "sync_modules", status: "pending", operable: instance, account: account
      )
    end
  end

  # F4-05: without operation_id passthrough, ProvisioningService's retry-
  # idempotency guard is unreachable from the agent surface — a retried MCP
  # call provisions a duplicate billable VM.
  describe "system_provision_instance idempotency passthrough" do
    let(:node) { create(:system_node, account: account, node_template: template, name: "prov") }

    it "declares operation_id in the action schema" do
      params = described_class.action_definitions["system_provision_instance"][:parameters]
      expect(params).to have_key(:operation_id)
    end

    it "forwards operation_id to ProvisioningService" do
      instance = create(:system_node_instance, node: node)
      expect(::System::ProvisioningService).to receive(:provision_instance)
        .with(hash_including(operation_id: "op-agent-1"))
        .and_return(::System::Runtime::Result.ok(data: { instance: instance, cloud_instance_id: "i-1" }))

      r = call("system_provision_instance", node_id: node.id,
               provider_region_id: SecureRandom.uuid,
               provider_instance_type_id: SecureRandom.uuid,
               operation_id: "op-agent-1")

      expect(r[:success]).to be true
    end
  end

  describe "Drift report" do
    let(:node) { create(:system_node, account: account, node_template: template, name: "drft") }
    let(:instance) { create(:system_node_instance, :running, node: node) }
    let(:mod) do
      create(:system_node_module, account: account, node_platform: platform_record,
             category: category, variety: "subscription", name: "drift-mod")
    end
    let!(:version) do
      v = System::NodeModuleVersion.create!(
        node_module: mod, version_number: 1, mask: [], file_spec: [], package_spec: [], config: {},
        oci_digest: "sha256:#{'a' * 64}"
      )
      mod.update!(current_version_id: v.id)
      v
    end
    let!(:assignment) do
      System::NodeModuleAssignment.create!(node: node, node_module: mod, enabled: true, priority: 0)
    end

    it "reports no drift when running matches assigned" do
      instance.update!(running_module_digests: { mod.id => "sha256:#{'a' * 64}" })
      r = call("system_drift_report", instance_id: instance.id)
      expect(r[:success]).to be true
      expect(r[:data][:drift]).to be false
    end

    it "reports missing modules" do
      instance.update!(running_module_digests: {})
      r = call("system_drift_report", instance_id: instance.id)
      expect(r[:data][:drift]).to be true
      expect(r[:data][:missing_count]).to eq(1)
    end

    it "reports mismatched digests" do
      instance.update!(running_module_digests: { mod.id => "sha256:#{'b' * 64}" })
      r = call("system_drift_report", instance_id: instance.id)
      expect(r[:data][:drift]).to be true
      expect(r[:data][:mismatched_count]).to eq(1)
    end
  end

  describe "boot image drift (campaign 019f505f)" do
    let(:node) { create(:system_node, account: account, node_template: template) }
    let(:instance) { create(:system_node_instance, :running, node: node) }

    it "reports boot_image_drift when booted and promoted shas differ" do
      booted_sha = "booted-abc123"
      promoted_sha = "promoted-xyz789"
      instance.update!(booted_image_git_sha: booted_sha)
      platform_record.update!(disk_image_git_sha: promoted_sha)

      r = call("system_drift_report", instance_id: instance.id)

      expect(r[:success]).to be true
      expect(r[:data][:boot_image_drift]).to be true
      expect(r[:data][:booted_image_git_sha]).to eq(booted_sha)
      expect(r[:data][:promoted_image_git_sha]).to eq(promoted_sha)
    end

    it "reports boot_image_drift false when booted and promoted shas match" do
      same_sha = "matching-sha"
      instance.update!(booted_image_git_sha: same_sha)
      platform_record.update!(disk_image_git_sha: same_sha)

      r = call("system_drift_report", instance_id: instance.id)

      expect(r[:success]).to be true
      expect(r[:data][:boot_image_drift]).to be false
      expect(r[:data][:booted_image_git_sha]).to eq(same_sha)
      expect(r[:data][:promoted_image_git_sha]).to eq(same_sha)
    end

    it "reports boot_image_drift false when booted_image_git_sha is nil" do
      instance.update!(booted_image_git_sha: nil)
      platform_record.update!(disk_image_git_sha: "promoted-sha")

      r = call("system_drift_report", instance_id: instance.id)

      expect(r[:success]).to be true
      expect(r[:data][:boot_image_drift]).to be false
      expect(r[:data][:booted_image_git_sha]).to be_nil
      expect(r[:data][:promoted_image_git_sha]).to eq("promoted-sha")
    end

    it "reports boot_image_drift false when promoted_image_git_sha is nil" do
      instance.update!(booted_image_git_sha: "booted-sha")
      platform_record.update!(disk_image_git_sha: nil)

      r = call("system_drift_report", instance_id: instance.id)

      expect(r[:success]).to be true
      expect(r[:data][:boot_image_drift]).to be false
      expect(r[:data][:booted_image_git_sha]).to eq("booted-sha")
      expect(r[:data][:promoted_image_git_sha]).to be_nil
    end

    it "includes boot image fields alongside module drift fields" do
      booted_sha = "boot-sha"
      promoted_sha = "promoted-sha"
      instance.update!(booted_image_git_sha: booted_sha, running_module_digests: {})
      platform_record.update!(disk_image_git_sha: promoted_sha)

      r = call("system_drift_report", instance_id: instance.id)

      data = r[:data]
      # Boot image drift fields are always present
      expect(data[:boot_image_drift]).to be true
      expect(data[:booted_image_git_sha]).to eq(booted_sha)
      expect(data[:promoted_image_git_sha]).to eq(promoted_sha)
      # Module drift fields should also be present even when no drift
      expect(data[:missing_count]).to eq(0)
      expect(data[:extra_count]).to eq(0)
      expect(data[:mismatched_count]).to eq(0)
    end
  end

  # Every publication fixture below carries status/published_at because each one
  # stands for the platform's PROMOTED row, and UpgradeDispatcher.preflight
  # refuses a pointer aimed at a row that never reached :published
  # (IMP-80bd70c04afe). That is not an extra precondition invented by the guard:
  # all three writers of NodePlatform#disk_image_git_sha stamp published_at in
  # the same transaction as the pointer flip, so a promoted row without it is a
  # state production cannot reach.
  describe "system_upgrade_boot_image (campaign 019f505f inc 2)" do
    let(:node) { create(:system_node, account: account, node_template: template) }
    let(:instance) { create(:system_node_instance, :running, node: node) }
    let(:user) { create(:user, account: account, permissions: %w[system.node_instances.manage]) }
    let(:user_tool) { described_class.new(account: account, user: user) }
    let(:cosign_public_key_pem) do
      "-----BEGIN PUBLIC KEY-----\n" \
      "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEzKyqKWW5nHvyLMYqwP5xPeOXDw" \
      "tz+sKlxGqKcvK9I5CDLQQRi8S6X8L6kqJMPj7pZ9nFNqnCwHGh/JFVRqZDjA==\n" \
      "-----END PUBLIC KEY-----"
    end

    def call_with_user(action, **rest)
      user_tool.execute(params: { action: action }.merge(rest))
end

    it "rejects upgrades for instances from other accounts (access control)" do
      other_account = create(:account)
      other_node = create(:system_node, account: other_account)
      other_instance = create(:system_node_instance, :running, node: other_node)

      r = call_with_user("system_upgrade_boot_image", instance_id: other_instance.id)

      # Should fail because instance is not in the current account
      expect(r[:success]).to be false
    end

    it "errors when the platform has no promoted disk_image_git_sha" do
      platform_record.update!(disk_image_git_sha: nil, disk_image_oci_ref: "ref")

      r = call_with_user("system_upgrade_boot_image", instance_id: instance.id)

      expect(r[:success]).to be false
      expect(r[:error]).to include("no promoted disk image")
    end

    it "errors when the platform has no promoted disk_image_oci_ref" do
      platform_record.update!(disk_image_git_sha: "sha-abc", disk_image_oci_ref: nil)

      r = call_with_user("system_upgrade_boot_image", instance_id: instance.id)

      expect(r[:success]).to be false
      expect(r[:error]).to include("no promoted disk image")
    end

    it "errors when the promoted publication has no standalone UKI artifact" do
      # Blank on the publication — the only place the UKI pins live — so the
      # dispatcher's UKI guard must fire (df4a2000).
      platform_record.update!(
        disk_image_git_sha: "sha-abc",
        disk_image_oci_ref: "ref-xyz"
      )
      System::DiskImagePublication.create!(
        account: account,
        node_platform: platform_record,
        git_sha: "sha-abc",
        arch: "amd64",
        oci_ref: "ref-xyz",
        sha256: "#{'a' * 64}",
        size_bytes: 1024,
        uki_oci_ref: nil,
        uki_sha256: nil,
        uki_cosign_bundle: "base64_bundle_data",
        status: "published",
        published_at: Time.current
      )

      r = call_with_user("system_upgrade_boot_image", instance_id: instance.id)

      expect(r[:success]).to be false
      expect(r[:error]).to include("UKI artifact")
      expect(r[:error]).to include("republish")
    end

    it "errors when the platform pointer names a git_sha with no published record" do
      # Pointer-consistency guard: the promoted sha resolves to no publication,
      # so the (uki, bundle) pair cannot be sourced self-consistently.
      platform_record.update!(
        disk_image_git_sha: "promoted-but-unpublished",
        disk_image_oci_ref: "ref-xyz"
      )

      r = call_with_user("system_upgrade_boot_image", instance_id: instance.id)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/pointer inconsistent/i)
      expect(r[:error]).to include("promoted-but-unpublished")
      expect(::System::Task.where(operable: instance, command: "upgrade_boot_image").count).to eq(0)
    end

    it "fails closed with security error when cosign public key is not configured (ENV unset)" do
      platform_record.update!(
        disk_image_git_sha: "sha-abc",
        disk_image_oci_ref: "ref-xyz"
      )
      # UKI pins live on the publication row — present here so the chain reaches
      # the cosign-key guard, which is the point of this example.
      System::DiskImagePublication.create!(
        account: account,
        node_platform: platform_record,
        git_sha: "sha-abc",
        arch: "amd64",
        oci_ref: "ref-xyz",
        sha256: "#{'a' * 64}",
        size_bytes: 1024,
        uki_oci_ref: "uki-ref",
        uki_sha256: "#{'b' * 64}",
        uki_cosign_bundle: "base64_bundle_data",
        status: "published",
        published_at: Time.current
      )
      # Ensure ENV is NOT set and no file path exists
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(nil)
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

      r = call_with_user("system_upgrade_boot_image", instance_id: instance.id)

      expect(r[:success]).to be false
      expect(r[:error]).to include("cosign public key")
      expect(r[:error]).to include("not configured")
      expect(::System::Task.where(operable: instance, command: "upgrade_boot_image").count).to eq(0)
    end

    it "errors when platform has no promoted UKI cosign signature bundle" do
      target_sha = "target-no-bundle"
      platform_record.update!(
        disk_image_git_sha: target_sha,
        disk_image_oci_ref: "ref-xyz"
      )
      # Create a publication but without uki_cosign_bundle (nil). UKI pins are
      # present so the artifact guard passes and we reach the bundle guard.
      System::DiskImagePublication.create!(
        account: account,
        node_platform: platform_record,
        git_sha: target_sha,
        arch: "amd64",
        oci_ref: "test-oci-ref",
        sha256: "#{'b' * 64}",
        size_bytes: 1024,
        uki_oci_ref: "uki-ref",
        uki_sha256: "#{'c' * 64}",
        uki_cosign_bundle: nil,
        status: "published",
        published_at: Time.current
      )

      # Bundle guard runs AFTER cosign pubkey guard, so ENV must be set
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

      r = call_with_user("system_upgrade_boot_image", instance_id: instance.id)

      expect(r[:success]).to be false
      expect(r[:error]).to include("no UKI cosign signature bundle")
      expect(System::Task.where(operable: instance, command: "upgrade_boot_image").count).to eq(0)
    end

    it "creates a pending upgrade_boot_image task when all preconditions are met (happy path)" do
      target_sha = "target-sha-xyz"
      oci_ref = "ghcr.io/nodealchemy/system/boot-uki:0.1.0"
      uki_ref = "ghcr.io/nodealchemy/system/boot-uki-standalone:0.1.0"
      uki_sha256 = "e" * 64
      cosign_bundle_b64 = "LS0tLS1CRUdJTiBQR1AgU0lHTkVEIE1FU1NBR0UtLS0tLQo="  # base64 encoded

      # The task must be pinned from the publication row. uki_ref/uki_sha256 are
      # distinct from every other value in play, so a regression that sourced the
      # pins from anywhere else fails these assertions loudly instead of passing
      # on values that happen to agree (df4a2000).
      platform_record.update!(
        disk_image_git_sha: target_sha,
        disk_image_oci_ref: oci_ref
      )

      # Create the promoted publication with the UKI pins + cosign bundle
      pub = System::DiskImagePublication.create!(
        account: account,
        node_platform: platform_record,
        git_sha: target_sha,
        arch: "amd64",
        oci_ref: oci_ref,
        sha256: "#{'a' * 64}",
        size_bytes: 1024,
        uki_oci_ref: uki_ref,
        uki_sha256: uki_sha256,
        uki_cosign_bundle: cosign_bundle_b64,
        status: "published",
        published_at: Time.current
      )

      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

      r = call_with_user("system_upgrade_boot_image", instance_id: instance.id)

      expect(r[:success]).to be true
      expect(r[:data][:upgraded]).to be true
      expect(r[:data][:task_id]).to be_present

      task = System::Task.find(r[:data][:task_id])
      expect(task).to have_attributes(
        command: "upgrade_boot_image",
        status: "pending",
        operable_type: "System::NodeInstance",
        operable_id: instance.id,
        account_id: account.id,
        initiated_by_id: user.id
      )
      expect(task.options["target_git_sha"]).to eq(target_sha)
      expect(task.options["uki_oci_ref"]).to eq(uki_ref)
      expect(task.options["uki_sha256"]).to eq(uki_sha256)
      expect(task.options["cosign_public_key"]).to eq(cosign_public_key_pem)
      expect(task.options["cosign_bundle_b64"]).to eq(cosign_bundle_b64)
      # Digest-pinned so the download endpoint serves the artifact THIS task was
      # pinned to even if a promote lands mid-flight (IMP-b55869029a57).
      expect(task.options["download_path"])
        .to eq("/api/v1/system/node_api/boot_image/download?digest=#{uki_sha256}")
      # Old identity/issuer regexp fields should NOT be present
      expect(task.options).not_to include("cosign_identity_regexp", "cosign_issuer_regexp")
    end

    it "returns NO-OP (already_current:true) when booted sha equals target sha and force not set" do
      matching_sha = "shared-sha-abc123"
      platform_record.update!(
        disk_image_git_sha: matching_sha,
        disk_image_oci_ref: "ref"
      )
      # Create the published artifact with bundle (needed to pass all guards)
      System::DiskImagePublication.create!(
        account: account,
        node_platform: platform_record,
        git_sha: matching_sha,
        arch: "amd64",
        oci_ref: "test-oci-ref",
        sha256: "#{'c' * 64}",
        size_bytes: 1024,
        uki_oci_ref: "uki-ref",
        uki_sha256: "#{'a' * 64}",
        uki_cosign_bundle: "base64_bundle_data",
        status: "published",
        published_at: Time.current
      )
      instance.update!(booted_image_git_sha: matching_sha)

      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

      r = call_with_user("system_upgrade_boot_image", instance_id: instance.id)

      expect(r[:success]).to be true
      expect(r[:data][:upgraded]).to be false
      expect(r[:data][:already_current]).to be true
      expect(System::Task.where(operable: instance, command: "upgrade_boot_image").count).to eq(0)
    end

    it "creates a task when booted sha equals target but force:true" do
      matching_sha = "shared-sha-abc123"
      platform_record.update!(
        disk_image_git_sha: matching_sha,
        disk_image_oci_ref: "ref"
      )
      # Create the published artifact with bundle
      System::DiskImagePublication.create!(
        node_platform: platform_record,
        git_sha: matching_sha,
        account: account,
        arch: "amd64",
        oci_ref: "test-oci-ref",
        sha256: "#{'d' * 64}",
        size_bytes: 1024,
        uki_oci_ref: "uki-ref",
        uki_sha256: "#{'a' * 64}",
        uki_cosign_bundle: "base64_bundle_data",
        status: "published",
        published_at: Time.current
      )
      instance.update!(booted_image_git_sha: matching_sha)

      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

      r = call_with_user("system_upgrade_boot_image", instance_id: instance.id, force: true)

      expect(r[:success]).to be true
      expect(r[:data][:upgraded]).to be true
      expect(r[:data][:task_id]).to be_present
      expect(System::Task.where(operable: instance, command: "upgrade_boot_image", status: "pending").count).to eq(1)
    end

    it "force:true bypasses in-flight dedup — creates a NEW task even if pending/running exists" do
      target_sha = "target-sha"
      platform_record.update!(
        disk_image_git_sha: target_sha,
        disk_image_oci_ref: "ref"
      )
      # Create the published artifact with bundle
      System::DiskImagePublication.create!(
        node_platform: platform_record,
        git_sha: target_sha,
        account: account,
        arch: "amd64",
        oci_ref: "test-oci-ref",
        sha256: "#{'e' * 64}",
        size_bytes: 1024,
        uki_oci_ref: "uki-ref",
        uki_sha256: "#{'a' * 64}",
        uki_cosign_bundle: "base64_bundle_data",
        status: "published",
        published_at: Time.current
      )
      # Create an existing in-flight pending task
      existing_task = System::Task.create!(
        account: account,
        operable: instance,
        command: "upgrade_boot_image",
        status: "pending",
        initiated_by: user
      )

      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

      r = call_with_user("system_upgrade_boot_image", instance_id: instance.id, force: true)

      expect(r[:success]).to be true
      expect(r[:data][:upgraded]).to be true
      expect(r[:data][:task_id]).not_to eq(existing_task.id)
      expect(System::Task.where(operable: instance, command: "upgrade_boot_image").count).to eq(2)
    end

    it "returns DEDUP when an in-flight pending task already exists" do
      target_sha = "target-sha"
      platform_record.update!(
        disk_image_git_sha: target_sha,
        disk_image_oci_ref: "ref"
      )
      # Create the published artifact with bundle
      System::DiskImagePublication.create!(
        node_platform: platform_record,
        git_sha: target_sha,
        account: account,
        arch: "amd64",
        oci_ref: "test-oci-ref",
        sha256: "#{'e' * 64}",
        size_bytes: 1024,
        uki_oci_ref: "uki-ref",
        uki_sha256: "#{'a' * 64}",
        uki_cosign_bundle: "base64_bundle_data",
        status: "published",
        published_at: Time.current
      )
      existing_task = System::Task.create!(
        account: account,
        operable: instance,
        command: "upgrade_boot_image",
        status: "pending",
        initiated_by: user
      )

      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

      r = call_with_user("system_upgrade_boot_image", instance_id: instance.id)

      expect(r[:success]).to be true
      expect(r[:data][:upgraded]).to be false
      expect(r[:data][:deduplicated]).to be true
      expect(r[:data][:task_id]).to eq(existing_task.id)
      expect(System::Task.where(operable: instance, command: "upgrade_boot_image").count).to eq(1)
    end

    it "returns DEDUP when an in-flight scheduled task already exists" do
      target_sha = "target-sha"
      platform_record.update!(
        disk_image_git_sha: target_sha,
        disk_image_oci_ref: "ref"
      )
      # Create the published artifact with bundle
      System::DiskImagePublication.create!(
        node_platform: platform_record,
        git_sha: target_sha,
        account: account,
        arch: "amd64",
        oci_ref: "test-oci-ref",
        sha256: "#{'f' * 64}",
        size_bytes: 1024,
        uki_oci_ref: "uki-ref",
        uki_sha256: "#{'a' * 64}",
        uki_cosign_bundle: "base64_bundle_data",
        status: "published",
        published_at: Time.current
      )
      existing_task = System::Task.create!(
        account: account,
        operable: instance,
        command: "upgrade_boot_image",
        status: "scheduled",
        initiated_by: user
      )

      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

      r = call_with_user("system_upgrade_boot_image", instance_id: instance.id)

      expect(r[:success]).to be true
      expect(r[:data][:deduplicated]).to be true
      expect(r[:data][:task_id]).to eq(existing_task.id)
    end

    it "returns DEDUP when an in-flight running task already exists" do
      target_sha = "target-sha"
      platform_record.update!(
        disk_image_git_sha: target_sha,
        disk_image_oci_ref: "ref"
      )
      # Create the published artifact with bundle
      System::DiskImagePublication.create!(
        node_platform: platform_record,
        git_sha: target_sha,
        account: account,
        arch: "amd64",
        oci_ref: "test-oci-ref",
        sha256: "#{'0' * 64}",
        size_bytes: 1024,
        uki_oci_ref: "uki-ref",
        uki_sha256: "#{'a' * 64}",
        uki_cosign_bundle: "base64_bundle_data",
        status: "published",
        published_at: Time.current
      )
      existing_task = System::Task.create!(
        account: account,
        operable: instance,
        command: "upgrade_boot_image",
        status: "running",
        initiated_by: user
      )

      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

      r = call_with_user("system_upgrade_boot_image", instance_id: instance.id)

      expect(r[:success]).to be true
      expect(r[:data][:deduplicated]).to be true
      expect(r[:data][:task_id]).to eq(existing_task.id)
    end

    it "creates a new task when a completed upgrade_boot_image task exists (dedup only in-flight)" do
      target_sha = "target-sha"
      platform_record.update!(
        disk_image_git_sha: target_sha,
        disk_image_oci_ref: "ref"
      )
      # Create the published artifact with bundle
      System::DiskImagePublication.create!(
        account: account,
        node_platform: platform_record,
        git_sha: target_sha,
        arch: "amd64",
        oci_ref: "test-oci-ref",
        sha256: "#{'1' * 64}",
        size_bytes: 1024,
        uki_oci_ref: "uki-ref",
        uki_sha256: "#{'a' * 64}",
        uki_cosign_bundle: "base64_bundle_data",
        status: "published",
        published_at: Time.current
      )
      existing_task = System::Task.create!(
        account: account,
        operable: instance,
        command: "upgrade_boot_image",
        status: "complete",
        initiated_by: user
      )

      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

      r = call_with_user("system_upgrade_boot_image", instance_id: instance.id)

      expect(r[:success]).to be true
      expect(r[:data][:upgraded]).to be true
      expect(r[:data][:task_id]).not_to eq(existing_task.id)
      expect(System::Task.where(operable: instance, command: "upgrade_boot_image", status: "pending").count).to eq(1)
    end

    it "requires system.node_instances.manage permission" do
      platform_record.update!(
        disk_image_git_sha: "target-sha",
        disk_image_oci_ref: "ref",
        disk_image_sha256: "sha256:aaaa",
        cosign_identity_regexp: "identity",
        cosign_issuer_regexp: "issuer"
      )
      unpermissioned_user = create(:user, account: account, permissions: %w[system.nodes.read])
      unpermissioned_tool = described_class.new(account: account, user: unpermissioned_user)

      r = unpermissioned_tool.execute(params: { action: "system_upgrade_boot_image", instance_id: instance.id })

      expect(r[:success]).to be false
      expect(r[:error]).to include("permission denied")
    end
  end

  describe "Tasks" do
    let(:node) { create(:system_node, account: account, node_template: template, name: "tsk") }

    it "system_list_tasks scopes to account" do
      task = System::Task.create!(
        account: account, command: "test_cmd", status: "pending",
        operable_type: "System::Node", operable_id: node.id
      )
      r = call("system_list_tasks", node_id: node.id)
      ids = r[:data][:tasks].map { |t| t[:id] }
      expect(ids).to include(task.id)
    end
  end

  # IMP-8153d1952ff8 — the AASM abort event (legal from :running) existed but
  # was unexposed on both the operator REST API and this MCP surface, leaving
  # a wedged provision/build/ssh task with no recourse short of the hourly
  # reaper's 60-min STUCK_RUNNING threshold.
  describe "system_abort_task" do
    let(:node) { create(:system_node, account: account, node_template: template, name: "aborttsk") }
    let!(:running_task) do
      System::Task.create!(
        account: account, command: "ssh_command", status: "running", started_at: Time.current,
        operable_type: "System::Node", operable_id: node.id
      )
    end

    it "aborts a running task" do
      r = call("system_abort_task", id: running_task.id, reason: "operator abort")
      expect(r[:success]).to be true
      expect(r[:data][:aborted]).to be true
      expect(r[:data][:task][:status]).to eq("aborted")
      expect(running_task.reload.error_message).to eq("operator abort")
    end

    it "errors when the task is not abortable (state-machine guard)" do
      pending_task = System::Task.create!(
        account: account, command: "sync", status: "pending",
        operable_type: "System::Node", operable_id: node.id
      )
      r = call("system_abort_task", id: pending_task.id)
      expect(r[:success]).to be false
      expect(pending_task.reload.status).to eq("pending")
    end

    it "denies callers without system.infra_tasks.control" do
      denied = described_class.new(
        account: account,
        user: create(:user, account: account, permissions: %w[system.infra_tasks.read])
      )
      r = denied.execute(params: { action: "system_abort_task", id: running_task.id })
      expect(r[:success]).to be false
      expect(r[:error]).to include("permission denied")
    end
  end

  describe "system_get_task" do
    let(:node) { create(:system_node, account: account, node_template: template, name: "gettask") }
    let!(:task) do
      System::Task.create!(
        account: account, command: "provision_node", status: "running", progress: 42,
        operable_type: "System::Node", operable_id: node.id
      )
    end

    it "fetches a single task scoped to the account" do
      r = call("system_get_task", id: task.id)
      expect(r[:success]).to be true
      expect(r[:data][:task][:id]).to eq(task.id)
      expect(r[:data][:task][:command]).to eq("provision_node")
      expect(r[:data][:task][:status]).to eq("running")
      expect(r[:data][:task][:progress]).to eq(42)
    end

    it "returns not-found error for an unknown id" do
      r = call("system_get_task", id: SecureRandom.uuid)
      expect(r[:success]).to be false
    end

    it "does not leak tasks from another account" do
      other_task = System::Task.create!(
        account: create(:account), command: "other_cmd", status: "pending",
        operable_type: "System::Node", operable_id: node.id
      )
      r = call("system_get_task", id: other_task.id)
      expect(r[:success]).to be false
    end

    it "denies callers without system.infra_tasks.read" do
      denied = described_class.new(
        account: account,
        user: create(:user, account: account, permissions: %w[system.nodes.read])
      )
      r = denied.execute(params: { action: "system_get_task", id: task.id })
      expect(r[:success]).to be false
      expect(r[:error]).to include("permission denied")
    end
  end

  describe "Gap remediation slice 1 — system_drain_instance" do
    let(:node)     { create(:system_node, account: account, node_template: template, name: "drain") }
    let(:instance) { create(:system_node_instance, :running, node: node) }

    it "records drain intent on config + emits FleetEvent" do
      r = call("system_drain_instance", instance_id: instance.id, timeout_seconds: 300)
      expect(r[:success]).to be true
      expect(r[:data][:drained]).to be true
      expect(r[:data][:drain_initiated_at]).to be_present
      expect(r[:data][:drain_timeout_seconds]).to eq(300)

      instance.reload
      expect(instance.config["drain_initiated_at"]).to be_present
      expect(instance.config["drain_timeout_seconds"]).to eq(300)
    end

    it "defaults timeout_seconds to 600 when omitted" do
      r = call("system_drain_instance", instance_id: instance.id)
      expect(r[:data][:drain_timeout_seconds]).to eq(600)
    end

    it "emits a system.instance.drain_initiated FleetEvent if model present" do
      skip "FleetEvent model not loaded" unless defined?(::System::FleetEvent)

      expect {
        call("system_drain_instance", instance_id: instance.id)
      }.to change { ::System::FleetEvent.where(kind: "system.instance.drain_initiated", node_instance_id: instance.id).count }.by(1)
    end

    it "is idempotent — calling twice updates drain_initiated_at" do
      call("system_drain_instance", instance_id: instance.id)
      first_at = instance.reload.config["drain_initiated_at"]
      sleep 1
      call("system_drain_instance", instance_id: instance.id)
      second_at = instance.reload.config["drain_initiated_at"]
      expect(second_at).not_to eq(first_at)
    end

    it "scopes to current account — refuses to drain other-account instances" do
      other_node = create(:system_node, account: create(:account), node_template: template, name: "other")
      other = create(:system_node_instance, :running, node: other_node)
      r = call("system_drain_instance", instance_id: other.id)
      expect(r[:success]).to be false
    end
  end

  describe "Gap remediation slice 1 — system_get_silent_instances" do
    let(:node) { create(:system_node, account: account, node_template: template, name: "silent") }
    let!(:silent_instance)  { create(:system_node_instance, :running, node: node, last_heartbeat_at: 10.minutes.ago) }
    let!(:fresh_instance)   { create(:system_node_instance, :running, node: node, last_heartbeat_at: 30.seconds.ago) }
    let!(:never_seen)       { create(:system_node_instance, :running, node: node, last_heartbeat_at: nil) }

    it "returns instances with last_heartbeat_at older than threshold or null" do
      r = call("system_get_silent_instances")
      expect(r[:success]).to be true
      ids = r[:data][:instances].map { |i| i[:id] }
      expect(ids).to include(silent_instance.id, never_seen.id)
      expect(ids).not_to include(fresh_instance.id)
    end

    it "honors custom threshold_seconds" do
      r = call("system_get_silent_instances", threshold_seconds: 10) # 10 seconds
      ids = r[:data][:instances].map { |i| i[:id] }
      expect(ids).to include(silent_instance.id, fresh_instance.id, never_seen.id) # all are older than 10s
    end

    it "reports the cutoff timestamp + threshold" do
      r = call("system_get_silent_instances", threshold_seconds: 60)
      expect(r[:data][:threshold_seconds]).to eq(60)
      expect(r[:data][:cutoff]).to be_present
    end

    it "scopes to current account" do
      other_node = create(:system_node, account: create(:account), node_template: template, name: "other-silent")
      other_silent = create(:system_node_instance, :running, node: other_node, last_heartbeat_at: 10.minutes.ago)
      r = call("system_get_silent_instances")
      ids = r[:data][:instances].map { |i| i[:id] }
      expect(ids).not_to include(other_silent.id)
      expect(ids).to include(silent_instance.id)
    end
  end

  describe "Gap remediation slice 1 — system_validate_module_manifest" do
    let!(:mod) do
      create(:system_node_module,
             account: account, category: category,
             name: "redis", variety: "subscription")
    end

    it "returns valid: true for a well-formed manifest matching the module" do
      yaml = <<~YML
        schema_version: 1
        name: redis
        description: Redis 7.4
        package_spec:
          - redis-server
        file_spec:
          - "/etc/redis/**"
      YML

      r = call("system_validate_module_manifest", module_id: mod.id, manifest_yaml: yaml)
      expect(r[:success]).to be true
      expect(r[:data][:valid]).to be true
      expect(r[:data][:validation_errors]).to be_empty
    end

    it "returns valid: false + errors when manifest.name does not match module" do
      yaml = "schema_version: 1\nname: nginx\n"

      r = call("system_validate_module_manifest", module_id: mod.id, manifest_yaml: yaml)
      expect(r[:success]).to be true # tool returns success even when manifest is invalid (the result captures errors)
      expect(r[:data][:valid]).to be false
      expect(r[:data][:validation_errors].join(" ")).to include("does not match")
    end

    it "returns valid: false for malformed YAML" do
      r = call("system_validate_module_manifest", module_id: mod.id, manifest_yaml: ":\n  - invalid\n  unbalanced")
      expect(r[:data][:valid]).to be false
    end

    it "scopes to current account modules" do
      other_mod = create(:system_node_module,
                         account: create(:account), category: category,
                         name: "other-redis")
      r = call("system_validate_module_manifest", module_id: other_mod.id, manifest_yaml: "schema_version: 1\nname: other-redis\n")
      expect(r[:success]).to be false
    end
  end

  describe "Gap remediation slice 2 — CVE catalog actions" do
    let(:cve_id) { "CVE-2026-99100" }

    let!(:cve) do
      ::System::Cve.create!(
        cve_id: cve_id,
        severity: "critical",
        summary: "Test CVE",
        affected_packages: [ { "name" => "openssl", "version" => "<3.1.4" } ],
        feed_source: "manual",
        published_at: 1.day.ago
      )
    end

    describe "system_get_cve" do
      it "returns the CVE by canonical id" do
        r = call("system_get_cve", cve_id: cve_id)
        expect(r[:success]).to be true
        expect(r[:data][:cve][:cve_id]).to eq(cve_id)
        expect(r[:data][:cve][:severity]).to eq("critical")
        expect(r[:data][:cve][:severity_weight]).to eq(100)
      end

      it "returns an error when CVE doesn't exist" do
        r = call("system_get_cve", cve_id: "CVE-2026-99999")
        expect(r[:success]).to be false
        expect(r[:error]).to include("not found")
      end
    end

    describe "system_get_cve_exposure" do
      let!(:mod) do
        create(:system_node_module,
               account: account, category: category,
               name: "openssl-base", variety: "subscription")
      end
      let!(:version) { create(:system_node_module_version, node_module: mod) }
      let!(:exposure) do
        ::System::CveExposure.create!(
          cve: cve, node_module_version: version,
          package_name: "openssl", state: "open"
        )
      end

      it "returns account-scoped exposure breakdown" do
        r = call("system_get_cve_exposure", cve_id: cve_id)
        expect(r[:success]).to be true
        expect(r[:data][:cve_id]).to eq(cve_id)
        expect(r[:data][:exposed_module_count]).to eq(1)
        expect(r[:data][:exposed_modules].first[:name]).to eq("openssl-base")
      end

      it "scopes exposure to current account — excludes other accounts' exposures" do
        other_account = create(:account)
        other_mod = create(:system_node_module, account: other_account,
                          category: create(:system_node_module_category, account: other_account),
                          name: "openssl-other")
        other_version = create(:system_node_module_version, node_module: other_mod)
        ::System::CveExposure.create!(cve: cve, node_module_version: other_version,
                                      package_name: "openssl", state: "open")

        r = call("system_get_cve_exposure", cve_id: cve_id)
        names = r[:data][:exposed_modules].map { |m| m[:name] }
        expect(names).to include("openssl-base")
        expect(names).not_to include("openssl-other")
      end

      it "returns zero exposures when CVE matches no account modules" do
        ::System::CveExposure.where(cve_id: cve.id).destroy_all
        r = call("system_get_cve_exposure", cve_id: cve_id)
        expect(r[:data][:exposed_module_count]).to eq(0)
      end
    end

    describe "system_create_cve" do
      it "creates a new Cve with the given attributes" do
        r = call("system_create_cve",
                 cve_id: "CVE-2026-99200",
                 severity: "high",
                 summary: "Synthetic high-severity",
                 affected_packages: [ { "name" => "redis" } ])
        expect(r[:success]).to be true
        expect(r[:data][:created]).to be true
        expect(r[:data][:cve][:cve_id]).to eq("CVE-2026-99200")
        expect(::System::Cve.find_by(cve_id: "CVE-2026-99200")).to be_present
      end

      it "is idempotent — re-running updates fields without duplicate-key error" do
        # First create
        call("system_create_cve",
             cve_id: "CVE-2026-99201", severity: "high", summary: "v1")
        # Second call — same ID, different summary
        r = call("system_create_cve",
                 cve_id: "CVE-2026-99201", severity: "critical", summary: "v2")
        expect(r[:success]).to be true
        expect(r[:data][:updated]).to be true
        expect(::System::Cve.find_by(cve_id: "CVE-2026-99201").summary).to eq("v2")
      end

      it "rejects malformed CVE ids" do
        r = call("system_create_cve",
                 cve_id: "CVE-DRILL-001", severity: "critical")
        expect(r[:success]).to be false
        expect(r[:error]).to include("CVE-YYYY-NNNN")
      end
    end

    describe "system_delete_cve" do
      it "destroys the CVE and cascades to exposures" do
        r = call("system_delete_cve", cve_id: cve_id)
        expect(r[:success]).to be true
        expect(r[:data][:deleted]).to be true
        expect(::System::Cve.find_by(cve_id: cve_id)).to be_nil
      end

      it "returns error when CVE doesn't exist" do
        r = call("system_delete_cve", cve_id: "CVE-2026-99999")
        expect(r[:success]).to be false
      end
    end
  end

  describe "Gap remediation slice 2 — system_unassign_module_from_template" do
    let!(:mod) do
      create(:system_node_module,
             account: account, category: category,
             name: "remove-me", variety: "subscription")
    end
    let!(:join) do
      ::System::TemplateModule.create!(node_template: template, node_module: mod)
    end

    it "destroys the TemplateModule join" do
      r = call("system_unassign_module_from_template",
               template_id: template.id, module_id: mod.id)
      expect(r[:success]).to be true
      expect(r[:data][:unassigned]).to be true
      expect(::System::TemplateModule.where(id: join.id)).to be_empty
    end

    it "is idempotent when join already absent" do
      join.destroy!
      r = call("system_unassign_module_from_template",
               template_id: template.id, module_id: mod.id)
      expect(r[:success]).to be true
      expect(r[:data][:unassigned]).to be false
      expect(r[:data][:already_absent]).to be true
    end

    it "scopes templates + modules to current account" do
      other_account = create(:account)
      other_template = create(:system_node_template, account: other_account)
      r = call("system_unassign_module_from_template",
               template_id: other_template.id, module_id: mod.id)
      expect(r[:success]).to be false
    end
  end

  describe "system_update_module_assignment" do
    let(:node) { create(:system_node, account: account, node_template: template, name: "asn") }
    let(:mod)  { create(:system_node_module, account: account, category: category, name: "togglable", variety: "subscription") }
    let!(:assignment) do
      create(:system_node_module_assignment, node: node, node_module: mod, enabled: true)
    end

    it "disables an enabled assignment when enabled=false" do
      r = call("system_update_module_assignment", assignment_id: assignment.id, enabled: false)
      expect(r[:success]).to be true
      expect(r[:data][:updated]).to be true
      expect(r[:data][:assignment][:enabled]).to be false
      expect(assignment.reload.enabled).to be false
    end

    it "enables a disabled assignment when enabled=true" do
      assignment.update!(enabled: false)
      r = call("system_update_module_assignment", assignment_id: assignment.id, enabled: true)
      expect(r[:success]).to be true
      expect(r[:data][:assignment][:enabled]).to be true
      expect(assignment.reload.enabled).to be true
    end

    it "returns not-found error for an unknown assignment id" do
      r = call("system_update_module_assignment", assignment_id: SecureRandom.uuid, enabled: true)
      expect(r[:success]).to be false
    end

    it "does not touch assignments whose node belongs to another account" do
      other_node = create(:system_node, account: create(:account))
      other_assignment = create(:system_node_module_assignment, node: other_node, enabled: true)
      r = call("system_update_module_assignment", assignment_id: other_assignment.id, enabled: false)
      expect(r[:success]).to be false
      expect(other_assignment.reload.enabled).to be true
    end

    it "denies callers without system.modules.update" do
      denied = described_class.new(
        account: account,
        user: create(:user, account: account, permissions: %w[system.modules.read])
      )
      r = denied.execute(params: { action: "system_update_module_assignment", assignment_id: assignment.id, enabled: false })
      expect(r[:success]).to be false
      expect(r[:error]).to include("permission denied")
    end
  end

  describe "Gap remediation slice 3 — pool ops + canary marking" do
    let(:provider_region) { create(:system_provider_region) }
    let(:provider_instance_type) { create(:system_provider_instance_type) }
    let(:pool) do
      ::System::InstancePool.create!(
        account: account, node_template: template,
        name: "slice3-pool", target_size: 2, min_size: 0, max_size: 5,
        lifecycle_class: "ephemeral", status: "active",
        provider_region: provider_region,
        provider_instance_type: provider_instance_type
      )
    end

    let(:pool_node) do
      create(:system_node, account: account, node_template: template,
                            lifecycle_class: "ephemeral", name: "pool-mem")
    end

    describe "system_return_pooled_instance" do
      let(:claimed_instance) do
        create(:system_node_instance, :running, node: pool_node,
               instance_pool_id: pool.id,
               pool_state: "claimed",
               pool_acquired_at: 2.minutes.ago,
               provider_region: provider_region,
               provider_instance_type: provider_instance_type)
      end

      # Audit F2-03 — return flipped claimed→ready with no reset, re-serving
      # an instance that still carried the prior mission's on-disk state,
      # credentials, and agent memory to the NEXT mission. The default now
      # recycles (draining + terminate → replenish provisions a fresh member);
      # reuse-without-reset is per-pool opt-in for same-trust-domain workloads.
      it "recycles a returned member by default — no cross-mission reuse without opt-in" do
        allow(::System::ProvisioningService).to receive(:terminate_instance)
          .and_return(double(success?: true, error: nil))

        r = call("system_return_pooled_instance", instance_id: claimed_instance.id)
        expect(r[:success]).to be true
        expect(r[:data][:returned]).to be true
        expect(r[:data][:disposition]).to eq("recycled")

        claimed_instance.reload
        expect(claimed_instance.pool_state).to eq("draining")
        expect(claimed_instance.pool_acquired_at).to be_nil
        expect(::System::ProvisioningService).to have_received(:terminate_instance)
          .with(instance: claimed_instance)
      end

      context "with a reuse_without_reset opt-in pool (same trust domain)" do
        let(:pool) do
          ::System::InstancePool.create!(
            account: account, node_template: template,
            name: "slice3-reuse-pool", target_size: 2, min_size: 0, max_size: 5,
            lifecycle_class: "ephemeral", status: "active",
            metadata: { "reuse_without_reset" => true },
            provider_region: provider_region,
            provider_instance_type: provider_instance_type
          )
        end

        it "transitions claimed → ready and clears pool_acquired_at" do
          r = call("system_return_pooled_instance", instance_id: claimed_instance.id)
          expect(r[:success]).to be true
          expect(r[:data][:returned]).to be true
          expect(r[:data][:disposition]).to eq("reused")

          claimed_instance.reload
          expect(claimed_instance.pool_state).to eq("ready")
          expect(claimed_instance.pool_acquired_at).to be_nil
        end

        # Audit F2-05 — return left pool_warming_started_at at the original
        # provision timestamp; recycle_stale_members! anchors stale_ready on
        # that column, so a returned member older than ready_ttl was terminated
        # on the next 60s reaper tick instead of being reused.
        it "resets the ready-TTL anchor so a returned member is not immediately stale-recycled" do
          old_member = create(:system_node_instance, :running, node: pool_node,
                              instance_pool_id: pool.id,
                              pool_state: "claimed",
                              pool_acquired_at: 2.minutes.ago,
                              pool_warming_started_at: 5.hours.ago,
                              provider_region: provider_region,
                              provider_instance_type: provider_instance_type)
          allow(::System::ProvisioningService).to receive(:terminate_instance)

          r = call("system_return_pooled_instance", instance_id: old_member.id)
          expect(r[:success]).to be true
          expect(old_member.reload.pool_warming_started_at).to be > 1.minute.ago

          ::System::InstancePoolService.recycle_stale_members!(pool: pool)
          expect(old_member.reload.pool_state).to eq("ready")
          expect(::System::ProvisioningService).not_to have_received(:terminate_instance)
        end
      end

      it "errors when instance was never in a pool" do
        unrelated_node = create(:system_node, account: account, node_template: template, name: "unrelated")
        free_instance = create(:system_node_instance, :running, node: unrelated_node)
        r = call("system_return_pooled_instance", instance_id: free_instance.id)
        expect(r[:success]).to be false
        expect(r[:error]).to include("never a pool member")
      end

      it "errors when instance is not in 'claimed' state" do
        ready_instance = create(:system_node_instance, :running, node: pool_node,
                                instance_pool_id: pool.id, pool_state: "ready",
                                provider_region: provider_region,
                                provider_instance_type: provider_instance_type)
        r = call("system_return_pooled_instance", instance_id: ready_instance.id)
        expect(r[:success]).to be false
        expect(r[:error]).to include("can only return 'claimed'")
      end
    end

    describe "system_delete_instance_pool" do
      it "destroys an empty pool" do
        empty_pool = ::System::InstancePool.create!(
          account: account, node_template: template,
          name: "empty-pool", target_size: 0, min_size: 0, max_size: 5,
          lifecycle_class: "ephemeral", status: "archived",
          provider_region: provider_region,
          provider_instance_type: provider_instance_type
        )
        r = call("system_delete_instance_pool", id: empty_pool.id)
        expect(r[:success]).to be true
        expect(r[:data][:deleted]).to be true
        expect(::System::InstancePool.where(id: empty_pool.id)).to be_empty
      end

      it "errors when pool still has members" do
        # Touch pool to ensure it's saved before adding members
        create(:system_node_instance, :running, node: pool_node,
               instance_pool_id: pool.id, pool_state: "ready",
               provider_region: provider_region,
               provider_instance_type: provider_instance_type)
        r = call("system_delete_instance_pool", id: pool.id)
        expect(r[:success]).to be false
        expect(r[:error]).to include("drain first")
      end

      it "scopes to current account" do
        other_account = create(:account)
        other_pool = ::System::InstancePool.create!(
          account: other_account, node_template: create(:system_node_template, account: other_account),
          name: "other-pool", target_size: 0, min_size: 0, max_size: 5,
          lifecycle_class: "ephemeral", status: "archived",
          provider_region: provider_region,
          provider_instance_type: provider_instance_type
        )
        r = call("system_delete_instance_pool", id: other_pool.id)
        expect(r[:success]).to be false
      end
    end

    describe "system_module_mark_canary" do
      let!(:mod) do
        create(:system_node_module, account: account, category: category,
               name: "decoy-secrets-store", variety: "subscription")
      end

      it "marks the module as a canary via CanaryModuleService" do
        r = call("system_module_mark_canary", module_id: mod.id)
        expect(r[:success]).to be true
        expect(r[:data][:marked]).to be true
        expect(r[:data][:canary]).to be true
        expect(::System::Honeypot::CanaryModuleService.canary?(node_module: mod.reload)).to be true
      end

      it "is idempotent — re-marking returns success without error" do
        2.times { call("system_module_mark_canary", module_id: mod.id) }
        r = call("system_module_mark_canary", module_id: mod.id)
        expect(r[:success]).to be true
      end

      it "honors lure_kind parameter" do
        r = call("system_module_mark_canary", module_id: mod.id, lure_kind: "ssh_keys")
        expect(r[:data][:lure_kind]).to eq("ssh_keys")
        expect(mod.reload.config["honeypot"]["lure_kind"]).to eq("ssh_keys")
      end

      it "scopes to current account" do
        other_mod = create(:system_node_module, account: create(:account),
                           category: category, name: "other-decoy")
        r = call("system_module_mark_canary", module_id: other_mod.id)
        expect(r[:success]).to be false
      end
    end
  end

  describe "Gap remediation slice 5 — disk image CI" do
    let!(:platform_record_for_pubs) { platform_record }

    describe "system_list_disk_image_publications" do
      let!(:pub_a) { create(:system_disk_image_publication, account: account, node_platform: platform_record_for_pubs, status: "queued") }
      let!(:pub_b) { create(:system_disk_image_publication, account: account, node_platform: platform_record_for_pubs, status: "published") }

      it "lists publications for the account" do
        r = call("system_list_disk_image_publications")
        expect(r[:success]).to be true
        ids = r[:data][:publications].map { |p| p[:id] }
        expect(ids).to include(pub_a.id, pub_b.id)
      end

      it "filters by status when provided" do
        r = call("system_list_disk_image_publications", status: "published")
        ids = r[:data][:publications].map { |p| p[:id] }
        expect(ids).to include(pub_b.id)
        expect(ids).not_to include(pub_a.id)
      end
    end

    describe "system_set_default_disk_image_publication" do
      # NOTE: uses the :published TRAIT (not a bare status: "published"
      # override) so this row carries a real file_object — a "published"
      # row can never legitimately exist without one (mark_published /
      # reactivate both guard on file_object_id.present?). A bare status
      # override without a file_object is exactly the impossible state
      # IMP-70f3109e693a's promotable? guard now (correctly) refuses to
      # promote — that guard tripped here before this fixture was fixed.
      let!(:published) do
        create(:system_disk_image_publication, :published, account: account, node_platform: platform_record_for_pubs,
                                                             oci_ref: "registry.example.com/test:abc", git_sha: "test-sha-promoted")
      end

      it "copies oci_ref + git_sha onto the parent NodePlatform" do
        r = call("system_set_default_disk_image_publication", publication_id: published.id)
        expect(r[:success]).to be true
        expect(r[:data][:set_default]).to be true

        platform_record_for_pubs.reload
        expect(platform_record_for_pubs.disk_image_oci_ref).to eq("registry.example.com/test:abc")
        expect(platform_record_for_pubs.disk_image_git_sha).to eq("test-sha-promoted")
        expect(platform_record_for_pubs.disk_image_publication_status).to eq("published")
      end

      it "errors when publication is not in 'published' state" do
        queued = create(:system_disk_image_publication, account: account, node_platform: platform_record_for_pubs, status: "queued")
        r = call("system_set_default_disk_image_publication", publication_id: queued.id)
        expect(r[:success]).to be false
        expect(r[:error]).to include("only 'published'")
      end

      it "scopes to current account" do
        other_account = create(:account)
        other_pub = create(:system_disk_image_publication, account: other_account, node_platform: create(:system_node_platform, account: other_account), status: "published")
        r = call("system_set_default_disk_image_publication", publication_id: other_pub.id)
        expect(r[:success]).to be false
      end

      it "copies disk_image_file_object_id/sha256/size_bytes so provisioning actually boots the new image, not just display metadata" do
        promoted = create(:system_disk_image_publication, :published,
                           account: account, node_platform: platform_record_for_pubs,
                           oci_ref: "registry.example.com/test:promoted", git_sha: "promoted-sha")

        r = call("system_set_default_disk_image_publication", publication_id: promoted.id)
        expect(r[:success]).to be true

        platform_record_for_pubs.reload
        expect(platform_record_for_pubs.disk_image_file_object_id).to eq(promoted.file_object_id)
        expect(platform_record_for_pubs.disk_image_sha256).to eq(promoted.sha256)
        expect(platform_record_for_pubs.disk_image_size_bytes).to eq(promoted.size_bytes)
      end
    end

    describe "system_set_disk_image_retention" do
      it "updates the retention count" do
        r = call("system_set_disk_image_retention", node_platform_id: platform_record_for_pubs.id, retention_count: 10)
        expect(r[:success]).to be true
        expect(platform_record_for_pubs.reload.disk_image_retention_count).to eq(10)
      end

      it "rejects retention_count < 1" do
        r = call("system_set_disk_image_retention", node_platform_id: platform_record_for_pubs.id, retention_count: 0)
        expect(r[:success]).to be false
        expect(r[:error]).to include("must be ≥1")
      end

      it "scopes to current account" do
        other_platform = create(:system_node_platform, account: create(:account))
        r = call("system_set_disk_image_retention", node_platform_id: other_platform.id, retention_count: 5)
        expect(r[:success]).to be false
      end
    end

    describe "system_revert_disk_image" do
      # A target publication to roll back TO (published → has a file_object
      # via the :published trait).
      let!(:target) do
        create(:system_disk_image_publication, :published,
               account: account, node_platform: platform_record_for_pubs,
               oci_ref: "registry.example.com/test:target", git_sha: "target-sha")
      end

      it "rolls back to an explicit publication_id" do
        r = call("system_revert_disk_image",
                 platform_id: platform_record_for_pubs.id, publication_id: target.id)
        expect(r[:success]).to be true
        expect(r[:data][:reverted]).to be true
        expect(r[:data][:activated_publication_id]).to eq(target.id)

        platform_record_for_pubs.reload
        expect(platform_record_for_pubs.disk_image_file_object_id).to eq(target.file_object_id)
        expect(platform_record_for_pubs.disk_image_oci_ref).to eq("registry.example.com/test:target")
        expect(platform_record_for_pubs.disk_image_git_sha).to eq("target-sha")
        expect(platform_record_for_pubs.disk_image_publication_status).to eq("published")
      end

      it "auto-selects the most recent retired publication when no publication_id is given" do
        retired = create(:system_disk_image_publication, :retired,
                         account: account, node_platform: platform_record_for_pubs,
                         oci_ref: "registry.example.com/test:retired", git_sha: "retired-sha")
        # retired trait does not build a file_object — give it one so the
        # revert (which requires file_object_id) can proceed.
        fo = create(:file_object, account: account, filename: "retired.img",
                                  file_size: retired.size_bytes, content_type: "application/octet-stream",
                                  checksum_sha256: retired.sha256)
        retired.update!(file_object: fo)

        r = call("system_revert_disk_image", platform_id: platform_record_for_pubs.id)
        expect(r[:success]).to be true
        expect(r[:data][:activated_publication_id]).to eq(retired.id)
        expect(platform_record_for_pubs.reload.disk_image_git_sha).to eq("retired-sha")
      end

      it "errors when no prior publication is available to auto-revert to" do
        empty_platform = create(:system_node_platform, account: account)
        r = call("system_revert_disk_image", platform_id: empty_platform.id)
        expect(r[:success]).to be false
        expect(r[:error]).to include("No prior publication")
      end

      it "refuses to revert to a purged publication" do
        target.update_columns(status: "purged", file_object_id: nil)
        r = call("system_revert_disk_image",
                 platform_id: platform_record_for_pubs.id, publication_id: target.id)
        expect(r[:success]).to be false
        expect(r[:error]).to include("purged")
      end

      it "errors when target publication has no file_object" do
        target.update_columns(file_object_id: nil)
        r = call("system_revert_disk_image",
                 platform_id: platform_record_for_pubs.id, publication_id: target.id)
        expect(r[:success]).to be false
        expect(r[:error]).to include("no file_object")
      end

      it "returns not-found for an unknown platform" do
        r = call("system_revert_disk_image", platform_id: SecureRandom.uuid)
        expect(r[:success]).to be false
      end

      it "does not revert a publication on a platform from another account" do
        other_account = create(:account)
        other_platform = create(:system_node_platform, account: other_account)
        r = call("system_revert_disk_image",
                 platform_id: other_platform.id, publication_id: target.id)
        expect(r[:success]).to be false
      end

      it "denies callers without system.platforms.rollback_disk_image" do
        denied = described_class.new(
          account: account,
          user: create(:user, account: account, permissions: %w[system.modules.update])
        )
        r = denied.execute(params: {
          action: "system_revert_disk_image",
          platform_id: platform_record_for_pubs.id, publication_id: target.id
        })
        expect(r[:success]).to be false
        expect(r[:error]).to include("permission denied")
      end
    end

    describe "system_provision_ci_worker / list / terminate" do
      it "creates a ci_worker Worker + returns one-time token" do
        r = call("system_provision_ci_worker", name: "build-runner-1")
        expect(r[:success]).to be true
        expect(r[:data][:ci_worker]).to be_present
        expect(r[:data][:token_plaintext]).to be_present
        expect(r[:data][:note]).to include("Not recoverable")
        worker = ::Worker.find_by(name: "build-runner-1")
        expect(worker.has_role?("ci_worker")).to be true
      end

      it "system_list_ci_workers returns only ci_worker-role Workers for the account" do
        call("system_provision_ci_worker", name: "list-test-1")
        # Create a non-ci worker in the same account using a valid account-worker role
        ::Worker.create_worker!(name: "member-worker", account: account, roles: [ "member" ])
        r = call("system_list_ci_workers")
        expect(r[:success]).to be true
        names = r[:data][:ci_workers].map { |w| w[:name] }
        expect(names).to include("list-test-1")
        expect(names).not_to include("member-worker")
      end

      it "system_terminate_ci_worker revokes the worker" do
        provision_r = call("system_provision_ci_worker", name: "terminate-test-1")
        worker_id = provision_r[:data][:ci_worker][:id]
        r = call("system_terminate_ci_worker", worker_id: worker_id)
        expect(r[:success]).to be true
        expect(r[:data][:revoked]).to be true
        expect(::Worker.find(worker_id).status).to eq("revoked")
      end

      it "system_terminate_ci_worker refuses to revoke non-ci workers" do
        member_worker = ::Worker.create_worker!(name: "member-worker-2", account: account, roles: [ "member" ])
        r = call("system_terminate_ci_worker", worker_id: member_worker.id)
        expect(r[:success]).to be false
        expect(r[:error]).to include("not a ci_worker")
      end
    end

    # Campaign 019f5885 inc3 — CI runner lease MCP surface. lease!/release!
    # are already thoroughly covered at the service layer
    # (ci_runner_lease_service_spec.rb); these examples lock in the MCP
    # param-marshaling + response shape + error passthrough.
    describe "system_lease_ci_runner / system_release_ci_runner / system_list_ci_runner_leases" do
      let(:provider_region)  { create(:system_provider_region) }
      let(:instance_type)    { create(:system_provider_instance_type) }
      let(:builder_pool) do
        System::InstancePool.create!(
          account: account, node_template: template, name: "ci-builders-mcp",
          target_size: 2, min_size: 1, max_size: 3, lifecycle_class: "ephemeral", status: "active",
          provider_region: provider_region, provider_instance_type: instance_type
        )
      end

      def seed_ready_member(pool)
        node = create(:system_node, account: account, node_template: template, lifecycle_class: "ephemeral")
        create(:system_node_instance, node: node, name: "mcp-member-#{SecureRandom.hex(3)}", variety: "cloud",
                                       status: "running", provider_region: provider_region,
                                       provider_instance_type: instance_type,
                                       instance_pool_id: pool.id, pool_state: "ready",
                                       pool_warming_started_at: 1.minute.ago)
      end

      it "system_lease_ci_runner acquires a warm builder and correlates it to its self-registered runner" do
        member = seed_ready_member(builder_pool)
        create(:git_runner, account: account, name: ::System::CiRunnerRegistrationResolver.runner_name(member))

        r = call("system_lease_ci_runner", pool_name: builder_pool.name, correlate_timeout: 0)

        expect(r[:success]).to be true
        expect(r[:data][:ci_runner_lease][:status]).to eq("registered")
        expect(r[:data][:ci_runner_lease][:node_instance_id]).to eq(member.id)
      end

      it "system_lease_ci_runner returns an error result when the pool has no ready members" do
        r = call("system_lease_ci_runner", pool_name: builder_pool.name, correlate_timeout: 0)

        expect(r[:success]).to be false
        expect(r[:error]).to be_present
      end

      it "system_release_ci_runner deregisters the runner and releases the lease" do
        member = seed_ready_member(builder_pool)
        runner_name = ::System::CiRunnerRegistrationResolver.runner_name(member)
        create(:git_runner, account: account, name: runner_name)
        lease_r = call("system_lease_ci_runner", pool_name: builder_pool.name, correlate_timeout: 0)
        lease_id = lease_r[:data][:ci_runner_lease][:id]

        fake_gitea_client = instance_double("Devops::Git::GiteaApiClient")
        allow(::Devops::Git::ApiClient).to receive(:for).and_return(fake_gitea_client)
        allow(fake_gitea_client).to receive(:supports_runners?).and_return(true)
        allow(fake_gitea_client).to receive(:delete_runner).and_return(success: true)
        allow(::System::ProvisioningService).to receive(:terminate_instance)

        r = call("system_release_ci_runner", lease_id: lease_id)

        expect(r[:success]).to be true
        expect(r[:data][:ci_runner_lease][:status]).to eq("released")
      end

      it "system_release_ci_runner surfaces RunnerBusyError as an error result (not an exception)" do
        member = seed_ready_member(builder_pool)
        runner_name = ::System::CiRunnerRegistrationResolver.runner_name(member)
        runner = create(:git_runner, account: account, name: runner_name)
        lease_r = call("system_lease_ci_runner", pool_name: builder_pool.name, correlate_timeout: 0)
        lease_id = lease_r[:data][:ci_runner_lease][:id]
        runner.update!(status: "busy", busy: true)

        r = call("system_release_ci_runner", lease_id: lease_id)

        expect(r[:success]).to be false
        expect(r[:error]).to include("busy")
      end

      it "system_list_ci_runner_leases lists + filters leases for the account" do
        member = seed_ready_member(builder_pool)
        registered = ::System::CiRunnerLease.create!(account: account, node_instance: member, status: "registered")
        released = ::System::CiRunnerLease.create!(account: account, node_instance: member, status: "released")

        all_r = call("system_list_ci_runner_leases")
        expect(all_r[:success]).to be true
        expect(all_r[:data][:ci_runner_leases].map { |l| l[:id] }).to contain_exactly(registered.id, released.id)

        active_r = call("system_list_ci_runner_leases", active: true)
        expect(active_r[:data][:ci_runner_leases].map { |l| l[:id] }).to contain_exactly(registered.id)

        status_r = call("system_list_ci_runner_leases", status: "released")
        expect(status_r[:data][:ci_runner_leases].map { |l| l[:id] }).to contain_exactly(released.id)
      end
    end

    describe "system_list_disk_image_webhooks" do
      let!(:webhook) { create(:system_disk_image_webhook, account: account) }

      it "lists webhooks for the account" do
        r = call("system_list_disk_image_webhooks")
        expect(r[:success]).to be true
        ids = r[:data][:webhooks].map { |w| w[:id] }
        expect(ids).to include(webhook.id)
      end

      it "scopes to current account" do
        other_webhook = create(:system_disk_image_webhook, account: create(:account))
        r = call("system_list_disk_image_webhooks")
        ids = r[:data][:webhooks].map { |w| w[:id] }
        expect(ids).not_to include(other_webhook.id)
      end
    end
  end

  describe "Missing-features slice 6a — GitOps reconciler MCP surface" do
    describe "system_gitops_register_repository" do
      it "creates a GitopsRepository for the account" do
        r = call("system_gitops_register_repository",
                 name: "fleet-config",
                 repo_url: "https://example.com/fleet-config.git",
                 branch: "main")
        expect(r[:success]).to be true
        expect(r[:data][:repository][:name]).to eq("fleet-config")
        expect(::System::GitopsRepository.where(account_id: account.id, name: "fleet-config")).to exist
      end

      it "rejects URLs with inline credentials" do
        r = call("system_gitops_register_repository",
                 name: "bad-repo",
                 repo_url: "https://user:pw@example.com/repo.git")
        expect(r[:success]).to be false
        expect(r[:error]).to include("inline credentials")
      end
    end

    describe "system_gitops_sync_repository" do
      let!(:repo) do
        ::System::GitopsRepository.create!(
          account: account, name: "sync-test",
          repo_url: "https://example.com/repo.git", branch: "main"
        )
      end

      it "delegates to Reconciler.reconcile!" do
        result = ::System::Gitops::Reconciler::Result.new(
          ok?: true, diff_count: 0, proposal_ids: [],
          synced_revision: "abc123", diff_summary: { templates: 0 }, error: nil
        )
        expect(::System::Gitops::Reconciler).to receive(:reconcile!)
          .with(repository: instance_of(::System::GitopsRepository))
          .and_return(result)

        r = call("system_gitops_sync_repository", id: repo.id)
        expect(r[:success]).to be true
        expect(r[:data][:diff_count]).to eq(0)
        expect(r[:data][:synced_revision]).to eq("abc123")
      end

      it "scopes to current account" do
        other_repo = ::System::GitopsRepository.create!(
          account: create(:account), name: "other", repo_url: "https://example.com/other.git", branch: "main"
        )
        r = call("system_gitops_sync_repository", id: other_repo.id)
        expect(r[:success]).to be false
      end
    end

    describe "system_gitops_get_sync_run" do
      let!(:repo) do
        ::System::GitopsRepository.create!(
          account: account, name: "get-test",
          repo_url: "https://example.com/repo.git", branch: "main"
        )
      end

      it "returns the sync_run details" do
        proposal_uuids = 3.times.map { SecureRandom.uuid }
        run = ::System::GitopsSyncRun.create!(
          gitops_repository: repo,
          started_at: 5.minutes.ago,
          completed_at: 2.minutes.ago,
          status: "success",
          diff_count: 3,
          proposal_ids: proposal_uuids
        )

        r = call("system_gitops_get_sync_run", sync_run_id: run.id)
        expect(r[:success]).to be true
        expect(r[:data][:sync_run][:status]).to eq("success")
        expect(r[:data][:sync_run][:diff_count]).to eq(3)
        expect(r[:data][:sync_run][:proposal_ids]).to match_array(proposal_uuids)
      end
    end

    describe "system_gitops_get_drift_report" do
      let!(:repo) do
        ::System::GitopsRepository.create!(
          account: account, name: "drift-test",
          repo_url: "https://example.com/repo.git", branch: "main"
        )
      end

      it "runs the diff pipeline without opening proposals" do
        repo_result = double(ok?: true, work_tree_path: "/tmp/repo", commit_sha: "abc123", error: nil)
        parse_result = double(ok?: true, desired_state: double, error: nil)
        diff_result = double(ok?: true, diffs: [], error: nil)

        expect(::System::Gitops::RepoSyncService).to receive(:sync!).and_return(repo_result)
        expect(::System::Gitops::DesiredStateParser).to receive(:parse!).and_return(parse_result)
        expect(::System::Gitops::DiffEngine).to receive(:diff!).and_return(diff_result)
        # Critically — Reconciler should NOT be invoked (no proposals opened)
        expect(::System::Gitops::Reconciler).not_to receive(:reconcile!)

        r = call("system_gitops_get_drift_report", id: repo.id)
        expect(r[:success]).to be true
        expect(r[:data][:drift]).to be false
        expect(r[:data][:synced_revision]).to eq("abc123")
      end
    end
  end

  describe "Missing-features slice Vault DR-3 — pepper rotation" do
    it "delegates to CredentialRestorationService and returns counts" do
      result = ::Security::CredentialRestorationService::Result.new(
        ok?: true, rotated_count: 47, skipped_count: 0,
        failed_count: 0, latest_version: "v3", errors: [], error: nil
      )
      expect(::Security::CredentialRestorationService).to receive(:rotate_transit_pepper!)
        .with(reencrypt_existing: true)
        .and_return(result)

      r = call("system_rotate_vault_transit_pepper")
      expect(r[:success]).to be true
      expect(r[:data][:rotated]).to be true
      expect(r[:data][:rotated_count]).to eq(47)
      expect(r[:data][:latest_version]).to eq("v3")
    end

    it "honors reencrypt_existing: false (key bump only)" do
      result = ::Security::CredentialRestorationService::Result.new(
        ok?: true, rotated_count: 0, skipped_count: 0,
        failed_count: 0, latest_version: "v4", errors: [], error: nil
      )
      expect(::Security::CredentialRestorationService).to receive(:rotate_transit_pepper!)
        .with(reencrypt_existing: false)
        .and_return(result)

      r = call("system_rotate_vault_transit_pepper", reencrypt_existing: false)
      expect(r[:success]).to be true
      expect(r[:data][:rotated_count]).to eq(0)
    end

    it "returns an error when rotation fails" do
      result = ::Security::CredentialRestorationService::Result.new(
        ok?: false, rotated_count: 0, skipped_count: 0,
        failed_count: 0, latest_version: nil, errors: [], error: "vault unreachable"
      )
      expect(::Security::CredentialRestorationService).to receive(:rotate_transit_pepper!).and_return(result)

      r = call("system_rotate_vault_transit_pepper")
      expect(r[:success]).to be false
      expect(r[:error]).to include("vault unreachable")
    end
  end

  describe "Missing-features slice 11a — federation acceptance (via SdwanTool)" do
    # In-process system caller, same as this file's own `tool` let above and
    # sdwan_tool_spec.rb's file-wide `tool` let — see IMP-54bf2643f542's
    # fail-closed ladder (SdwanTool#action_permitted?: internal? then
    # instance_authorized? then @user.nil? => false). A bare userless
    # construction stopped being an implicit bypass; declare it explicitly.
    let(:sdwan_tool) { ::Ai::Tools::SdwanTool.new(account: account, internal: true) }
    let!(:proposed_peer) do
      ::System::FederationPeer.create!(
        account: account, status: "proposed",
        remote_instance_url: "https://other.example.com",
        remote_instance_id: SecureRandom.uuid
      )
    end

    # Acceptance extends trust to a remote instance — the same weight as the
    # revoke this tool exposes — so it goes through Ai::AutonomyGate on the MCP
    # surface exactly as it does on FederationPeersController#update.
    it "defers acceptance through the approval gate rather than mutating inline" do
      r = sdwan_tool.execute(params: {
        action: "system_sdwan_accept_federation_peer",
        federation_peer_id: proposed_peer.id
      })

      expect(r[:success]).to be true
      expect(r[:data][:pending]).to be true
      expect(proposed_peer.reload.status).to eq("proposed"),
                                             "MCP acceptance mutated the peer without an approval gate"

      deferred = Ai::DeferredOperation.order(created_at: :desc).first
      expect(deferred.action_category).to eq("sdwan.federation_peer_accept")
      expect(deferred.executor_class).to eq("Sdwan::Executors::AcceptFederationPeer")
      expect(deferred.params["federation_peer_id"]).to eq(proposed_peer.id)
    end

    # The seeded require_approval row is scoped to the SDWAN Manager agent, and
    # Ai::InterventionPolicy#agent_matches? rejects a scoped row when no agent is
    # passed — so an agent caller that does not forward its agent silently falls
    # through to the account default and its approval routes to "Manual
    # Operations" instead of the agent's own chain, unattributed.
    it "attributes the deferred acceptance to the calling agent" do
      agent = create(:ai_agent, account: account)
      agent_tool = ::Ai::Tools::SdwanTool.new(account: account, agent: agent, internal: true)

      agent_tool.execute(params: {
        action: "system_sdwan_accept_federation_peer",
        federation_peer_id: proposed_peer.id
      })

      expect(Ai::DeferredOperation.order(created_at: :desc).first.ai_agent_id).to eq(agent.id)
    end

    it "transitions proposed → accepted with signed_at populated" do
      auto_approve_policy!

      r = sdwan_tool.execute(params: {
        action: "system_sdwan_accept_federation_peer",
        federation_peer_id: proposed_peer.id
      })
      expect(r[:success]).to be true
      expect(r[:data][:accepted]).to be true

      proposed_peer.reload
      expect(proposed_peer.status).to eq("accepted")
      expect(proposed_peer.signed_at).to be_present
    end

    it "refuses transition for already-accepted peers" do
      proposed_peer.accept!
      r = sdwan_tool.execute(params: {
        action: "system_sdwan_accept_federation_peer",
        federation_peer_id: proposed_peer.id
      })
      expect(r[:success]).to be false
      expect(r[:error]).to include("only 'proposed'")
    end

    it "records acceptance_token usage in metadata when token provided (no digest set, drill mode)" do
      auto_approve_policy!

      sdwan_tool.execute(params: {
        action: "system_sdwan_accept_federation_peer",
        federation_peer_id: proposed_peer.id,
        acceptance_token: "abc123"
      })
      expect(proposed_peer.reload.metadata["acceptance_token_used"]).to be true
    end
  end

  describe "Missing-features slice 11b — token round-trip handshake" do
    # Same in-process-caller declaration as slice 11a above — see that let's
    # comment for the IMP-54bf2643f542 fail-closed ladder this satisfies.
    let(:sdwan_tool) { ::Ai::Tools::SdwanTool.new(account: account, internal: true) }

    # Minting moved off this surface entirely (IMP-3a32dc649043): a tool result
    # is forwarded to the model provider, so the MCP propose action cannot hand
    # back signing material. The round trip itself is unchanged — only where the
    # proposing operator obtains the token.
    describe "propose with generate_token" do
      it "refuses to mint, naming the operator path, and creates no peer" do
        expect {
          @r = sdwan_tool.execute(params: {
            action: "system_sdwan_propose_federation_peer",
            remote_instance_url: "https://b.example.com",
            remote_instance_id: SecureRandom.uuid,
            generate_token: true
          })
        }.not_to change(::System::FederationPeer, :count)

        expect(@r[:success]).to be false
        expect(@r[:error]).to include("/api/v1/system/sdwan/federation_peers")
      end
    end

    describe "accept with token verification" do
      # The token now originates from the operator path
      # (Sdwan::Executors::ProposeFederationPeer), which mints on the model
      # exactly as this does. `let!` keeps the mint eager — the accept surface
      # treats a digest-less peer as requiring no token at all, so a lazy mint
      # would quietly turn "rejects when token missing" into a no-op.
      let(:accept_peer) do
        create(:system_federation_peer, account: account, status: "proposed",
                                        remote_instance_url: "https://b.example.com")
      end
      let(:peer_id) { accept_peer.id }
      let!(:plaintext) { accept_peer.generate_acceptance_token!(ttl_seconds: 600) }

      it "accepts when correct plaintext token provided" do
        auto_approve_policy!

        r = sdwan_tool.execute(params: {
          action: "system_sdwan_accept_federation_peer",
          federation_peer_id: peer_id,
          acceptance_token: plaintext
        })
        expect(r[:success]).to be true
        expect(r[:data][:accepted]).to be true

        peer = ::System::FederationPeer.find(peer_id)
        expect(peer.status).to eq("accepted")
        # Token cleared after single-use
        expect(peer.acceptance_token_digest).to be_nil
      end

      it "rejects when token missing" do
        r = sdwan_tool.execute(params: {
          action: "system_sdwan_accept_federation_peer",
          federation_peer_id: peer_id
        })
        expect(r[:success]).to be false
        expect(r[:error]).to include("required")
      end

      it "rejects when token does not match" do
        r = sdwan_tool.execute(params: {
          action: "system_sdwan_accept_federation_peer",
          federation_peer_id: peer_id,
          acceptance_token: "wrong-token"
        })
        expect(r[:success]).to be false
        expect(r[:error]).to include("does not match")
      end

      it "rejects when token expired" do
        peer = ::System::FederationPeer.find(peer_id)
        peer.update!(acceptance_token_expires_at: 1.minute.ago)
        r = sdwan_tool.execute(params: {
          action: "system_sdwan_accept_federation_peer",
          federation_peer_id: peer_id,
          acceptance_token: plaintext
        })
        expect(r[:success]).to be false
        expect(r[:error]).to include("expired")
      end

      # The token is checked BEFORE the gate so an unacceptable request fails
      # immediately instead of parking an approval request that can only ever
      # fail. Sdwan::Executors::AcceptFederationPeer re-checks it at execution
      # time — that re-check, not this one, is the enforcement.
      it "parks no approval request when the token is wrong" do
        target = peer_id # force the propose round-trip outside the expectation

        expect {
          sdwan_tool.execute(params: {
            action: "system_sdwan_accept_federation_peer",
            federation_peer_id: target,
            acceptance_token: "wrong-token"
          })
        }.not_to change(Ai::DeferredOperation, :count)
      end
    end
  end

  describe "Unknown action" do
    it "returns an error_result" do
      r = call("system_definitely_not_real")
      expect(r[:success]).to be false
      expect(r[:error]).to include("Unknown action")
    end
  end

  describe "Registry wiring" do
    it "is registered in PlatformApiToolRegistry::TOOLS" do
      mapped = Ai::Tools::PlatformApiToolRegistry::TOOLS["system_list_nodes"]
      expect(mapped).to eq("Ai::Tools::SystemFleetTool")
    end

    it "registers gap-remediation slice 1 actions" do
      %w[system_drain_instance system_get_silent_instances system_validate_module_manifest].each do |action|
        expect(Ai::Tools::PlatformApiToolRegistry::TOOLS[action]).to eq("Ai::Tools::SystemFleetTool")
      end
    end

    it "registers gap-remediation slice 2 actions" do
      %w[system_get_cve system_get_cve_exposure system_create_cve system_delete_cve system_unassign_module_from_template].each do |action|
        expect(Ai::Tools::PlatformApiToolRegistry::TOOLS[action]).to eq("Ai::Tools::SystemFleetTool")
      end
    end

    it "registers gap-remediation slice 3 actions" do
      %w[system_return_pooled_instance system_delete_instance_pool system_module_mark_canary].each do |action|
        expect(Ai::Tools::PlatformApiToolRegistry::TOOLS[action]).to eq("Ai::Tools::SystemFleetTool")
      end
    end

    it "registers gap-remediation slice 5 actions" do
      %w[system_list_disk_image_publications system_set_default_disk_image_publication system_set_disk_image_retention system_provision_ci_worker system_terminate_ci_worker system_list_ci_workers system_list_disk_image_webhooks].each do |action|
        expect(Ai::Tools::PlatformApiToolRegistry::TOOLS[action]).to eq("Ai::Tools::SystemFleetTool")
      end
    end

    it "registers campaign 019f5885 inc3 CI runner lease actions" do
      %w[system_lease_ci_runner system_release_ci_runner system_list_ci_runner_leases].each do |action|
        expect(Ai::Tools::PlatformApiToolRegistry::TOOLS[action]).to eq("Ai::Tools::SystemFleetTool")
      end
    end

    it "registers missing-features slice 6a + Vault DR-3 actions" do
      %w[system_gitops_register_repository system_gitops_sync_repository system_gitops_get_sync_run system_gitops_get_drift_report system_rotate_vault_transit_pepper].each do |action|
        expect(Ai::Tools::PlatformApiToolRegistry::TOOLS[action]).to eq("Ai::Tools::SystemFleetTool")
      end
    end

    it "registers missing-features slice 11a action via SdwanTool" do
      expect(Ai::Tools::PlatformApiToolRegistry::TOOLS["system_sdwan_accept_federation_peer"]).to eq("Ai::Tools::SdwanTool")
    end

    it "registers missing-features slice 6b action" do
      expect(Ai::Tools::PlatformApiToolRegistry::TOOLS["system_gitops_apply_proposal"]).to eq("Ai::Tools::SystemFleetTool")
    end

    it "registers the newly-implemented aspirational MCP wrappers" do
      %w[system_get_task system_revert_disk_image system_update_module_assignment].each do |action|
        expect(Ai::Tools::PlatformApiToolRegistry::TOOLS[action]).to eq("Ai::Tools::SystemFleetTool")
      end
    end
  end

  describe "Missing-features slice 6b — GitOps apply path" do
    let!(:gitops_repo) do
      ::System::GitopsRepository.create!(
        account: account, name: "apply-test",
        repo_url: "https://example.com/apply-repo.git", branch: "main"
      )
    end

    let(:agent) { create(:ai_agent, account: account) }

    def make_proposal(diff:, status: "approved")
      ::Ai::AgentProposal.create!(
        account: account,
        ai_agent_id: agent.id,
        title: "GitOps: #{diff[:change]} #{diff[:kind]} #{diff[:name]}",
        description: "Apply test",
        proposal_type: "configuration",
        status: status,
        priority: "medium",
        proposed_changes: {
          diff: diff,
          source: "gitops",
          repository_id: gitops_repo.id,
          commit_sha: "abc123"
        }
      )
    end

    it "applies a template create diff (looks up node_platform by name)" do
      # Platform must exist in the account for the apply to resolve the name
      platform_record # touch to ensure it's created
      proposal = make_proposal(diff: {
        kind: "template", change: "create", name: "edge-cdn-applied",
        resource_id: nil, current: nil,
        desired: { name: "edge-cdn-applied", node_platform: platform_record.name }
      })

      r = call("system_gitops_apply_proposal", proposal_id: proposal.id)
      expect(r[:data][:applied]).to be true
      expect(::System::NodeTemplate.where(account_id: account.id, name: "edge-cdn-applied")).to exist
      expect(proposal.reload.status).to eq("implemented")
    end

    it "errors when template create lacks node_platform reference" do
      proposal = make_proposal(diff: {
        kind: "template", change: "create", name: "no-platform",
        resource_id: nil, current: nil, desired: { name: "no-platform" }
      })
      r = call("system_gitops_apply_proposal", proposal_id: proposal.id)
      expect(r[:data][:applied]).to be false
      expect(r[:data][:error]).to include("node_platform")
    end

    it "applies a module create diff" do
      proposal = make_proposal(diff: {
        kind: "module", change: "create", name: "redis-applied",
        resource_id: nil, current: nil,
        desired: { name: "redis-applied", variety: "subscription" }
      })

      r = call("system_gitops_apply_proposal", proposal_id: proposal.id)
      expect(r[:success]).to be true
      expect(r[:data][:applied]).to be true
      expect(::System::NodeModule.where(account_id: account.id, name: "redis-applied")).to exist
    end

    it "rejects non-approved proposals" do
      proposal = make_proposal(diff: { kind: "template", change: "create", name: "x" }, status: "pending_review")
      r = call("system_gitops_apply_proposal", proposal_id: proposal.id)
      expect(r[:data][:applied]).to be false
      expect(r[:data][:error]).to include("only 'approved'")
    end

    it "rejects proposals with non-gitops source" do
      proposal = ::Ai::AgentProposal.create!(
        account: account, ai_agent_id: agent.id,
        title: "manual proposal", description: "x",
        proposal_type: "configuration", status: "approved", priority: "medium",
        proposed_changes: { diff: {}, source: "manual" }
      )
      r = call("system_gitops_apply_proposal", proposal_id: proposal.id)
      expect(r[:data][:applied]).to be false
      expect(r[:data][:error]).to include("source is not 'gitops'")
    end

    it "informational diffs are no-ops with success status" do
      proposal = make_proposal(diff: {
        kind: "provider_config", change: "informational", name: "managed-via-ui",
        resource_id: nil, current: nil, desired: { note: "managed via UI" }
      })
      r = call("system_gitops_apply_proposal", proposal_id: proposal.id)
      expect(r[:data][:applied]).to be true
      expect(r[:data][:applied_action]).to include("informational")
    end

    it "destroy diff returns unsupported (v1 conservative)" do
      tmpl = create(:system_node_template, account: account)
      proposal = make_proposal(diff: {
        kind: "template", change: "destroy", name: tmpl.name,
        resource_id: tmpl.id, current: { name: tmpl.name }, desired: nil
      })
      r = call("system_gitops_apply_proposal", proposal_id: proposal.id)
      expect(r[:data][:applied]).to be false
      expect(r[:data][:error]).to include("not yet implemented")
    end
  end

  # Audit F8-03 — the provider MCP surface was list/get/update only while
  # REST had full CRUD: an agent on a fleet-expansion mission could not
  # onboard or decommission a substrate provider via MCP.
  describe "provider CRUD (audit F8-03)" do
    it "system_create_provider creates a provider for the account" do
      r = call("system_create_provider", name: "qemu-host-2", provider_type: "local_qemu",
               description: "second libvirt host", config: { "bridge_name" => "br0" })

      expect(r[:success]).to be true
      provider = System::Provider.find(r[:data][:provider][:id])
      expect(provider.account_id).to eq(account.id)
      expect(provider.provider_type).to eq("local_qemu")
      expect(provider.config["bridge_name"]).to eq("br0")
      expect(provider.enabled).to be true
    end

    it "system_create_provider accepts no credential parameters (Vault-backed flow only)" do
      params = described_class.action_definitions.fetch("system_create_provider")[:parameters].keys.map(&:to_s)
      expect(params).not_to include("credentials", "api_key", "secret_key", "api_secret", "token")
    end

    it "system_create_provider surfaces validation errors structurally" do
      r = call("system_create_provider", name: "", provider_type: "local_qemu")
      expect(r[:success]).to be false
      expect(r[:error]).to match(/blank|validation/i)
    end

    it "system_delete_provider deletes the provider" do
      provider = create(:system_provider, account: account)
      r = call("system_delete_provider", id: provider.id)

      expect(r[:success]).to be true
      expect(System::Provider.find_by(id: provider.id)).to be_nil
    end

    it "system_delete_provider scopes to the current account" do
      other = create(:system_provider) # different account
      r = call("system_delete_provider", id: other.id)

      expect(r[:success]).to be false
      expect(System::Provider.find_by(id: other.id)).to be_present
    end
  end

  # Audit F4-07 — F8-03 closed the Provider half, but the provisionable chain
  # needs FOUR records (provider + connected connection + region + instance
  # type) and the other three had no MCP create at all: an agent could not
  # self-serve onboard a substrate end-to-end. Credential safety: the
  # connection action accepts NO key material — the adapter layer resolves
  # credentials from the BYOC System::ProviderCredential store at use time.
  describe "provider chain creates (audit F4-07)" do
    let(:provider) { create(:system_provider, account: account) }

    describe "system_create_provider_connection" do
      it "creates a credential-less connection for the account's provider" do
        r = call("system_create_provider_connection",
                 provider_id: provider.id, name: "main-conn",
                 endpoint_url: "https://api.cloud.example", config: { "zone" => "z1" })

        expect(r[:success]).to be true
        conn = System::ProviderConnection.find(r[:data][:provider_connection][:id])
        expect(conn.account_id).to eq(account.id)
        expect(conn.provider_id).to eq(provider.id)
        expect(conn.status).to eq("pending")
      end

      it "accepts no raw credential parameters (BYOC ProviderCredential flow only)" do
        params = described_class.action_definitions
                                .fetch("system_create_provider_connection")[:parameters].keys.map(&:to_s)
        expect(params).not_to include("access_key", "secret_key", "tenant", "credentials",
                                      "api_key", "api_secret", "token")
      end

      it "optionally runs the live credential test after create" do
        allow_any_instance_of(System::ProviderConnection).to receive(:test_connection!) do |conn|
          conn.mark_connected!("ok")
          { success: true, message: "ok" }
        end

        r = call("system_create_provider_connection",
                 provider_id: provider.id, name: "tested-conn", test_connection: true)

        expect(r[:success]).to be true
        expect(r[:data][:test_result][:success]).to be true
        conn = System::ProviderConnection.find(r[:data][:provider_connection][:id])
        expect(conn.status).to eq("connected")
      end

      it "scopes the provider lookup to the current account" do
        foreign = create(:system_provider) # different account
        r = call("system_create_provider_connection", provider_id: foreign.id, name: "x")
        expect(r[:success]).to be false
      end
    end

    describe "system_create_provider_region" do
      it "creates a region under the provider" do
        r = call("system_create_provider_region",
                 provider_id: provider.id, name: "Lab Rack 1", region_code: "lab-1",
                 capabilities: { "gpu" => true })

        expect(r[:success]).to be true
        region = System::ProviderRegion.find(r[:data][:region][:id])
        expect(region.provider_id).to eq(provider.id)
        expect(region.account_id).to eq(account.id)
        expect(region.region_code).to eq("lab-1")
      end

      it "surfaces validation errors structurally" do
        r = call("system_create_provider_region", provider_id: provider.id, name: "")
        expect(r[:success]).to be false
        expect(r[:error]).to match(/blank|validation/i)
      end
    end

    describe "system_create_provider_instance_type" do
      it "creates an instance type under the provider" do
        r = call("system_create_provider_instance_type",
                 provider_id: provider.id, name: "Small", instance_type_code: "small-1",
                 vcpus: 2, memory_mb: 2048, storage_gb: 20)

        expect(r[:success]).to be true
        itype = System::ProviderInstanceType.find(r[:data][:instance_type][:id])
        expect(itype.provider_id).to eq(provider.id)
        expect(itype.account_id).to eq(account.id)
        expect(itype.vcpus).to eq(2)
      end

      it "mirrors the REST permission gates" do
        expect(described_class::ACTION_PERMISSIONS.fetch("system_create_provider_connection"))
          .to eq("system.connections.create")
        expect(described_class::ACTION_PERMISSIONS.fetch("system_create_provider_region"))
          .to eq("system.regions.create")
        # The instance-types REST controller gates create on system.providers.create.
        expect(described_class::ACTION_PERMISSIONS.fetch("system_create_provider_instance_type"))
          .to eq("system.providers.create")
      end
    end
  end

  # Increment 9 (campaign 019f3458) — revert_binding! (R) / cleanup (C).
  describe "system_revert_storage_migration_binding / system_cleanup_storage_migration" do
    let(:nfs_volume_type) { create(:system_provider_volume_type, account: account, volume_type: "nfs", name: "nfs-pool") }
    let(:source_volume) do
      create(:system_provider_volume, account: account, volume_type: nfs_volume_type, name: "vol-a",
                                       config: { "nfs" => { "server" => "nas1", "export_path" => "/v1/Powernode" } })
    end
    let(:target_volume) do
      create(:system_provider_volume, account: account, volume_type: nfs_volume_type, name: "vol-b",
                                       config: { "nfs" => { "server" => "nas2", "export_path" => "/v2/Powernode" } })
    end
    let(:instance) { create(:system_node_instance, account: account) }
    let(:failed_migration) do
      ::System::StorageMigration.create!(
        account: account, node_instance: instance, source_volume: source_volume, target_volume: target_volume,
        role: "postgres", status: "failed", failed_at: Time.current,
        source_subpath: "deployments/test/postgres", target_subpath: "deployments/test/postgres", plan: {}
      )
    end

    it "requests a revert on a reachable (failed) migration" do
      r = call("system_revert_storage_migration_binding", id: failed_migration.id, reason: "diverged mount")
      expect(r[:success]).to be true
      expect(r[:data][:storage_migration][:metadata]["revert_status"]).to eq("requested")
    end

    it "surfaces the model's reachability error for a non-revertible migration" do
      active = ::System::StorageMigration.create!(
        account: account, node_instance: instance, source_volume: source_volume, target_volume: target_volume,
        role: "postgres", status: "syncing",
        source_subpath: "deployments/test2/postgres", target_subpath: "deployments/test2/postgres", plan: {}
      )
      r = call("system_revert_storage_migration_binding", id: active.id)
      expect(r[:success]).to be false
      expect(r[:error]).to match(/Cannot revert binding/)
    end

    it "requests cleanup immediately, bypassing the grace window" do
      r = call("system_cleanup_storage_migration", id: failed_migration.id, immediate: true)
      expect(r[:success]).to be true
      expect(r[:data][:storage_migration][:metadata]["cleanup_status"]).to eq("requested")
    end

    it "refuses cleanup within the (default 24h) grace window without immediate: true" do
      r = call("system_cleanup_storage_migration", id: failed_migration.id)
      expect(r[:success]).to be false
      expect(r[:error]).to match(/grace window/i)
    end

    it "denies both actions to a caller without system.platform.scale" do
      denied = described_class.new(
        account: account,
        user: create(:user, account: account, permissions: %w[system.platform.read])
      )
      revert_result = denied.execute(params: { action: "system_revert_storage_migration_binding", id: failed_migration.id })
      cleanup_result = denied.execute(params: { action: "system_cleanup_storage_migration", id: failed_migration.id })
      expect(revert_result[:error]).to include("permission denied")
      expect(cleanup_result[:error]).to include("permission denied")
    end

    # Pins CURRENT (gap) behavior, not desired behavior — see improvement
    # 019f34a3 ("requires_approval is unenforced on the MCP tools/call
    # dispatch path"). The action_definitions entry declares
    # requires_approval: true, but calling .execute directly runs the
    # destructive op immediately — there is no approval gate in the
    # dispatch path today. If 019f34a3 is ever closed by wiring an actual
    # gate in here (or in the shared dispatcher), THIS spec should start
    # failing and needs to be updated to assert the gate instead.
    it "documents that requires_approval is declared but NOT enforced by direct .execute (019f34a3)" do
      defn = described_class.action_definitions.fetch("system_cleanup_storage_migration")
      expect(defn[:requires_approval]).to be true

      r = call("system_cleanup_storage_migration", id: failed_migration.id, immediate: true)
      expect(r[:success]).to be true # ran immediately — no approval step intervened
    end
  end

  describe "system_dispatch_module_build_batch (campaign 019f5885 inc9)" do
    def plan_result(entries, excluded: [])
      ::System::ModuleBuildPlannerService::PlanResult.new(entries: entries, excluded: excluded)
    end

    def stub_orchestrator_dispatch(dispatched: 1)
      allow(::System::NativeModuleBuildOrchestrator).to receive(:dispatch!).and_return(
        System::NativeModuleBuildOrchestrator::Result.new(
          ok?: true, dispatched: dispatched, queued: 0, succeeded: 0, retried: 0, failed: 0
        )
      )
    end

    it "plans, creates the ModuleBuildBatch, and dispatches it via the orchestrator" do
      allow(::System::ModuleBuildPlannerService).to receive(:plan_with_diagnostics)
        .with(base_sha: "base0000", head_sha: "headsha1234567", force_all: false, source_repo: nil)
        .and_return(plan_result([ { module: "mod-a", oci_ref: "abc1234" } ]))
      dispatch_result = System::NativeModuleBuildOrchestrator::Result.new(
        ok?: true, dispatched: 1, queued: 0, succeeded: 0, retried: 0, failed: 0
      )
      expect(::System::NativeModuleBuildOrchestrator).to receive(:dispatch!).and_return(dispatch_result)

      result = call("system_dispatch_module_build_batch", base_sha: "base0000", head_sha: "headsha1234567")

      expect(result[:success]).to be true
      batch_payload = result[:data][:module_build_batch]
      expect(batch_payload[:status]).to eq("planning") # the stubbed orchestrator never actually transitioned it
      expect(batch_payload[:base_sha]).to eq("base0000")
      expect(batch_payload[:head_sha]).to eq("headsha1234567")
      expect(batch_payload[:module_slugs]).to eq([ "mod-a" ])
      expect(batch_payload[:planned_count]).to eq(1)
      expect(result[:data][:dispatched]).to eq(1)
      expect(result[:data][:queued]).to eq(0)
      expect(System::ModuleBuildBatch.where(account: account).count).to eq(1)
      expect(System::ModuleBuildBatch.last.trigger).to eq("manual")
    end

    it "passes force_all through to the planner and an explicit trigger through to the batch" do
      allow(::System::ModuleBuildPlannerService).to receive(:plan_with_diagnostics)
        .with(base_sha: "b", head_sha: "h", force_all: true, source_repo: nil).and_return(plan_result([]))
      allow(::System::NativeModuleBuildOrchestrator).to receive(:dispatch!).and_return(
        System::NativeModuleBuildOrchestrator::Result.new(ok?: true, dispatched: 0, queued: 0, succeeded: 0, retried: 0, failed: 0)
      )

      result = call("system_dispatch_module_build_batch", base_sha: "b", head_sha: "h", force_all: true, trigger: "cve")

      expect(result[:success]).to be true
      expect(result[:data][:module_build_batch][:trigger]).to eq("cve")
    end

    it "threads source_repo through to the planner and records it on the batch (imp 019f71e2)" do
      allow(::System::ModuleBuildPlannerService).to receive(:plan_with_diagnostics)
        .with(base_sha: "b", head_sha: "h", force_all: false, source_repo: "powernode/powernode-platform")
        .and_return(plan_result([ { module: "mod-a", oci_ref: "abc1234" } ]))
      allow(::System::NativeModuleBuildOrchestrator).to receive(:dispatch!).and_return(
        System::NativeModuleBuildOrchestrator::Result.new(ok?: true, dispatched: 1, queued: 0, succeeded: 0, retried: 0, failed: 0)
      )

      result = call("system_dispatch_module_build_batch", base_sha: "b", head_sha: "h", source_repo: "powernode/powernode-platform")

      expect(result[:success]).to be true
      expect(System::ModuleBuildBatch.last.metadata["source_repo"]).to eq("powernode/powernode-platform")
    end

    it "requires base_sha and head_sha" do
      result = call("system_dispatch_module_build_batch", base_sha: "", head_sha: "h")

      expect(result[:success]).to be false
      expect(result[:error]).to include("base_sha and head_sha are required")
    end

    it "surfaces a planner PlanningError as an error_result rather than raising" do
      allow(::System::ModuleBuildPlannerService).to receive(:plan_with_diagnostics)
        .and_raise(::System::ModuleBuildPlannerService::PlanningError, "no active Gitea credential resolvable")

      result = call("system_dispatch_module_build_batch", base_sha: "b", head_sha: "h")

      expect(result[:success]).to be false
      expect(result[:error]).to include("no active Gitea credential resolvable")
      expect(System::ModuleBuildBatch.where(account: account).count).to eq(0)
    end

    it "is gated by system.module_builds.dispatch" do
      expect(described_class::ACTION_PERMISSIONS.fetch("system_dispatch_module_build_batch"))
        .to eq("system.module_builds.dispatch")

      user = create(:user, account: account, permissions: [])
      gated_tool = described_class.new(account: account, user: user)

      result = gated_tool.execute(params: { action: "system_dispatch_module_build_batch", base_sha: "b", head_sha: "h" })

      expect(result[:success]).to be false
      expect(result[:error]).to include("permission denied")
    end

    # IMP-9e01d1b48f7a — this permission is deliberately excluded from every
    # human-assignable role (admin/manager), so a denial here reads as a bug
    # to an agent/operator unless the error says so. Assert the message is
    # self-diagnosing: names the required permission AND states the
    # worker-only restriction, not just a generic "permission denied".
    it "explains the worker-only restriction in the permission-denied message" do
      user = create(:user, account: account, permissions: [])
      gated_tool = described_class.new(account: account, user: user)

      result = gated_tool.execute(params: { action: "system_dispatch_module_build_batch", base_sha: "b", head_sha: "h" })

      expect(result[:success]).to be false
      expect(result[:error]).to include("system.module_builds.dispatch")
      expect(result[:error]).to include("system_worker")
    end

    it "documents the action's parameter contract" do
      defn = described_class.action_definitions.fetch("system_dispatch_module_build_batch")

      expect(defn[:parameters][:base_sha][:required]).to be true
      expect(defn[:parameters][:head_sha][:required]).to be true
      expect(defn[:parameters].keys).to include(:force_all, :trigger, :source_repo)
    end

    it "documents the worker-only permission requirement in the action description" do
      defn = described_class.action_definitions.fetch("system_dispatch_module_build_batch")

      expect(defn[:description]).to include("system.module_builds.dispatch")
      expect(defn[:description]).to include("system_worker")
    end

    # imp b9e3e05a5119 — a module the planner dropped must reach the caller.
    it "surfaces the planner's exclusions in the dispatch result" do
      excluded = [ {
        module: "python3",
        reason: "package_origin",
        detail: "package-origin module — rebuild it with system_refresh_package_module"
      } ]
      allow(::System::ModuleBuildPlannerService).to receive(:plan_with_diagnostics)
        .and_return(plan_result([ { module: "mod-a", oci_ref: "abc1234" } ], excluded: excluded))
      stub_orchestrator_dispatch

      result = call("system_dispatch_module_build_batch", base_sha: "b", head_sha: "h", force_all: true)

      expect(result[:success]).to be true
      expect(result[:data][:excluded_modules]).to eq(excluded)
      expect(result[:data][:excluded_count]).to eq(1)
    end

    # imp b9e3e05a5119 follow-up (Fable review) — surfacing exclusions in the
    # synchronous dispatch response is not the same as persisting them: an
    # operator inspecting the batch later (not the dispatch call's own
    # response) must still be able to see what the plan dropped.
    it "persists the planner's exclusions onto the created batch's metadata, not just the response payload" do
      excluded = [ {
        module: "python3",
        reason: "package_origin",
        detail: "package-origin module — rebuild it with system_refresh_package_module",
        package_module_link_id: "link-1"
      } ]
      allow(::System::ModuleBuildPlannerService).to receive(:plan_with_diagnostics)
        .and_return(plan_result([ { module: "mod-a", oci_ref: "abc1234" } ], excluded: excluded))
      stub_orchestrator_dispatch

      call("system_dispatch_module_build_batch", base_sha: "b", head_sha: "h", force_all: true)

      batch = System::ModuleBuildBatch.last
      expect(batch.metadata["excluded"]).to contain_exactly(
        { "module" => "python3", "reason" => "package_origin",
          "detail" => "package-origin module — rebuild it with system_refresh_package_module",
          "package_module_link_id" => "link-1" }
      )
      expect(batch.metadata["excluded_count"]).to eq(1)
    end

    # Pins the sample cap itself: without this, deleting the cap (or changing
    # .first(LIMIT) to .first) passes the whole suite while a force_all sweep
    # on a package-heavy fleet dumps hundreds of entries into the response.
    it "samples excluded_modules at the cap while excluded_count keeps the true total" do
      excluded = (1..26).map { |i| { module: "pkg-#{i}", reason: "package_origin", detail: "…" } }
      allow(::System::ModuleBuildPlannerService).to receive(:plan_with_diagnostics)
        .and_return(plan_result([ { module: "mod-a", oci_ref: "abc1234" } ], excluded: excluded))
      stub_orchestrator_dispatch

      result = call("system_dispatch_module_build_batch", base_sha: "b", head_sha: "h", force_all: true)

      expect(result[:data][:excluded_modules].size).to eq(25)
      expect(result[:data][:excluded_modules].size).to eq(described_class::EXCLUDED_MODULE_SAMPLE_LIMIT)
      expect(result[:data][:excluded_count]).to eq(26)
    end

    it "omits the exclusion keys entirely when the planner dropped nothing" do
      allow(::System::ModuleBuildPlannerService).to receive(:plan_with_diagnostics)
        .and_return(plan_result([ { module: "mod-a", oci_ref: "abc1234" } ]))
      stub_orchestrator_dispatch

      result = call("system_dispatch_module_build_batch", base_sha: "b", head_sha: "h")

      expect(result[:data]).not_to have_key(:excluded_modules)
      expect(result[:data]).not_to have_key(:excluded_count)
    end

    it "documents the package-origin dual build path in the action description" do
      defn = described_class.action_definitions.fetch("system_dispatch_module_build_batch")

      expect(defn[:description]).to include("system_refresh_package_module")
    end
  end

  # 2026-08-07: runtime-go v2 and gitleaks v4 auto-promoted EMPTY artifacts and
  # nodes whiteout-deleted the corresponding files off a live root. Publishing
  # auto-promotes, so a bad build reaches the fleet with no gate — and there was
  # no supported way to repoint either module back to its last good version.
  #
  # The sharp part is target selection: both modules' immediately-previous
  # version rows carry oci_digest: null, so a naive "promote the previous row"
  # would have pointed the fleet at nothing. The action must walk back to the
  # most recent version that actually has a usable artifact.
  # A plain reconcile applies DRIFT. It cannot repair a root whose files were
  # deleted underneath an unchanged module version (2026-08-07: an empty
  # artifact's hot-prune whiteout-deleted /usr/local/go and
  # /usr/local/bin/gitleaks), because in that state nothing has drifted and the
  # reconcile correctly does nothing. Recovery was a hand bind-mount over a root
  # shell. force_resync carries the instruction that makes it a platform action.
  describe "system_refresh_instance_modules force_resync" do
    let(:node) { create(:system_node, account: account, node_template: template) }
    let(:instance) { create(:system_node_instance, node: node, name: "n1") }

    def queued_task
      ::System::Task.where(account: account, command: "sync_modules").order(:created_at).last
    end

    it "queues an ordinary reconcile with no resync instruction by default" do
      result = call("system_refresh_instance_modules", instance_id: instance.id)

      expect(result[:success]).to be(true)
      expect(queued_task.options).not_to have_key("force_resync")
    end

    it "carries force_resync and the module scope when asked" do
      result = call("system_refresh_instance_modules", instance_id: instance.id,
                                                        force_resync: true, module_id: "runtime-go")

      expect(result[:success]).to be(true)
      expect(queued_task.options["force_resync"]).to be(true)
      expect(queued_task.options["module_id"]).to eq("runtime-go")
    end

    it "omits module_id for a whole-node resync so every module is re-materialized" do
      call("system_refresh_instance_modules", instance_id: instance.id, force_resync: true)

      expect(queued_task.options["force_resync"]).to be(true)
      expect(queued_task.options).not_to have_key("module_id")
    end
  end

  describe "system_rollback_module_version" do
    let!(:mod) { create(:system_node_module, account: account, name: "runtime-go") }

    def version_with_digest(number, digest: "sha256:#{'a' * 64}", size: 12_345_000)
      create(:system_node_module_version, node_module: mod, version_number: number,
             artifacts: { "erofs" => { "oci_digest" => digest, "size" => size, "oci_ref" => "ref#{number}" } })
    end

    def version_without_digest(number)
      create(:system_node_module_version, node_module: mod, version_number: number, artifacts: {})
    end

    it "rolls back to the most recent version WITH a usable artifact, skipping digestless rows" do
      good = version_with_digest(1)
      version_without_digest(2)          # the naive "previous row" — points at nothing
      bad  = version_with_digest(3, size: 1_024) # the empty artifact that got promoted
      mod.promote_to_version!(bad)

      result = call("system_rollback_module_version", module_id: mod.id)

      expect(result[:success]).to be(true)
      expect(mod.reload.current_version_id).to eq(good.id)
      expect(mod.current_version_number).to eq(good.version_number)
    end

    it "refuses when no prior version has a usable artifact" do
      version_without_digest(1)
      current = version_with_digest(2)
      mod.promote_to_version!(current)

      result = call("system_rollback_module_version", module_id: mod.id)

      expect(result[:success]).to be(false)
      expect(mod.reload.current_version_id).to eq(current.id)
    end

    it "rolls back to an explicitly named version" do
      v1 = version_with_digest(1)
      version_with_digest(2)
      v3 = version_with_digest(3)
      mod.promote_to_version!(v3)

      result = call("system_rollback_module_version", module_id: mod.id, version_id: v1.id)

      expect(result[:success]).to be(true)
      expect(mod.reload.current_version_id).to eq(v1.id)
    end

    it "refuses an explicit target that has no usable artifact" do
      dud = version_without_digest(1)
      current = version_with_digest(2)
      mod.promote_to_version!(current)

      result = call("system_rollback_module_version", module_id: mod.id, version_id: dud.id)

      expect(result[:success]).to be(false)
      expect(mod.reload.current_version_id).to eq(current.id)
    end

    it "refuses a version belonging to a different module" do
      other = create(:system_node_module, account: account, name: "gitleaks")
      foreign = create(:system_node_module_version, node_module: other, version_number: 1,
                       artifacts: { "erofs" => { "oci_digest" => "sha256:#{'b' * 64}", "size" => 9_000_000 } })
      current = version_with_digest(2)
      mod.promote_to_version!(current)

      result = call("system_rollback_module_version", module_id: mod.id, version_id: foreign.id)

      expect(result[:success]).to be(false)
      expect(mod.reload.current_version_id).to eq(current.id)
    end
  end

  # Closes the "author a module over MCP" gap: create/update now route a raw
  # manifest.yaml through ManifestImportService so the module carries the
  # authoritative manifest_yaml (+ derived specs) and is therefore buildable.
  describe "MCP module authoring via manifest_yaml" do
    let(:manifest) do
      <<~YAML
        schema_version: 1
        name: ghtest
        file_spec:
          - "/usr/local/bin/ghtest"
        package_spec: []
        reboot_required: false
      YAML
    end

    it "declares manifest_yaml on both create and update" do
      defs = described_class.action_definitions
      expect(defs.fetch("system_create_module")[:parameters]).to include(:manifest_yaml, :create_version)
      expect(defs.fetch("system_update_module")[:parameters]).to include(:manifest_yaml)
    end

    it "creates a module carrying the imported manifest_yaml + derived specs (so it is buildable)" do
      # reuse_check is now mandatory on an authoring create (IMP-a67be4fe9041).
      # This account has no buildable modules yet, so `considered` may be empty
      # — but the R1/R2/R3 justification is required regardless.
      r = call("system_create_module", name: "ghtest", node_platform_id: platform_record.id,
                                        category_id: category.id, manifest_yaml: manifest,
                                        reuse_check: { justification: "R2", considered: [],
                                                       justification_detail: "vendored upstream with its own CVE cadence" })
      expect(r[:success]).to be(true)

      mod = ::System::NodeModule.find(r[:data][:node_module][:id])
      expect(mod.manifest_yaml).to be_present
      expect(mod.manifest_yaml).to include("ghtest")
      # a non-blank manifest_yaml is exactly what ModuleBuildPlannerService#known_module_names
      # requires to plan a build — the piece that was missing over MCP.
      expect(mod.file_spec).to be_present
      expect(r[:data][:node_module_version_id]).to be_present
    end

    it "rejects an invalid manifest and leaves no half-authored row behind" do
      before = ::System::NodeModule.where(account: account).count
      r = call("system_create_module", name: "badmod", node_platform_id: platform_record.id,
                                        category_id: category.id,
                                        reuse_check: { justification: "R3", considered: [],
                                                       justification_detail: "opt-in payload a node type must exclude" },
                                        manifest_yaml: "schema_version: 1\nname: badmod\nfile_spec:\n  - \"/home/evil\"\n")
      expect(r[:success]).to be(false)
      expect(r[:error]).to match(/manifest import failed/)
      expect(::System::NodeModule.where(account: account).count).to eq(before)
    end

    it "re-imports a manifest onto an existing module via update" do
      # The fixture now starts WITH a manifest, because that is what this
      # example is about — a re-import (the CVE version bump the tool
      # description names) onto a module the build planner already builds.
      # It previously started bare, which conflated the re-import with the
      # bare-create-then-update AUTHORING path; that path is gated by
      # IMP-a67be4fe9041 and has its own example in the reuse-gate block.
      mod = create(:system_node_module, account: account, node_platform: platform_record, name: "upmod",
                                        manifest_yaml: "schema_version: 1\nname: upmod\n")
      r = call("system_update_module", module_id: mod.id,
                                       manifest_yaml: "schema_version: 1\nname: upmod\nfile_spec:\n  - \"/usr/local/bin/upmod\"\nreboot_required: false\n")
      expect(r[:success]).to be(true)
      expect(mod.reload.manifest_yaml).to include("upmod")
    end
  end

  # IMP-a67be4fe9041 — the R1/R2/R3 reuse gate.
  #
  # Manifest authoring over MCP landed 2026-08-06 (f65e72c7): system_create_module
  # routes manifest_yaml through System::ManifestImportService, which is exactly
  # what puts the name into ModuleBuildPlannerService's buildable set. The reuse
  # gate did NOT land with it — it stayed advisory prose in the tool description
  # ("run system_discover_modules before authoring") and human-only prose in
  # docs/runbooks/module-authoring.md Phase 0. An agent could therefore mint a
  # duplicate module with no reuse check at all.
  #
  # Novelty is defined by ONE seam, not a second spelling: a call is authoring a
  # NEW module iff it would add a name to
  # System::ModuleBuildPlannerService.buildable_module_names — the same set the
  # planner builds from.
  describe "the R1/R2/R3 reuse gate on module authoring (IMP-a67be4fe9041)" do
    let(:manifest) do
      <<~YAML
        schema_version: 1
        name: newmod
        file_spec:
          - "/usr/local/bin/newmod"
        package_spec: []
        reboot_required: false
      YAML
    end

    # A module already in the buildable set, so `considered:` has something real
    # to name and the "you considered nothing" prong has something to fire on.
    let!(:incumbent) do
      create(:system_node_module, account: account, node_platform: platform_record,
                                  name: "traefik", manifest_yaml: "schema_version: 1\nname: traefik\n")
    end

    # Calls execute directly rather than through `call` so a string-keyed
    # override (the shape MCP JSON actually arrives in) survives the merge.
    def authored(over = {})
      tool.execute(params: { action: "system_create_module", name: "newmod",
                             node_platform_id: platform_record.id, category_id: category.id,
                             manifest_yaml: manifest }.merge(over))
    end

    it "refuses a novel manifest-bearing create that declares no reuse check" do
      before = ::System::NodeModule.where(account: account).count
      r = authored
      expect(r[:success]).to be(false)
      expect(r[:error]).to match(/reuse_check/)
      expect(r[:error]).to match(/R1|R2|R3/)
      # and it refuses BEFORE the row exists — no half-authored module.
      expect(::System::NodeModule.where(account: account).count).to eq(before)
    end

    it "refuses a justification outside R1/R2/R3" do
      r = authored(reuse_check: { justification: "R4", justification_detail: "it completes a family",
                                  considered: [ { module: "traefik", rejected_because: "no TLS" } ] })
      expect(r[:success]).to be(false)
      expect(r[:error]).to match(/R1, R2, R3/)
    end

    it "refuses a considered module that does not exist — the declaration is falsifiable" do
      r = authored(reuse_check: { justification: "R2", justification_detail: "own CVE cadence",
                                  considered: [ { module: "traefik", rejected_because: "no TLS" },
                                                { module: "no-such-module", rejected_because: "made up" } ] })
      expect(r[:success]).to be(false)
      expect(r[:error]).to match(/no-such-module/)
      expect(r[:error]).not_to match(/traefik/)
    end

    it "refuses a considered entry with no rejection rationale" do
      r = authored(reuse_check: { justification: "R2", justification_detail: "own CVE cadence",
                                  considered: [ { module: "traefik", rejected_because: "  " } ] })
      expect(r[:success]).to be(false)
      expect(r[:error]).to match(/rejected_because/)
    end

    it "refuses an empty considered list while the catalog has buildable modules" do
      r = authored(reuse_check: { justification: "R2", justification_detail: "own CVE cadence",
                                  considered: [] })
      expect(r[:success]).to be(false)
      expect(r[:error]).to match(/considered/)
    end

    it "refuses a blank justification_detail" do
      r = authored(reuse_check: { justification: "R2", justification_detail: "",
                                  considered: [ { module: "traefik", rejected_because: "no TLS" } ] })
      expect(r[:success]).to be(false)
      expect(r[:error]).to match(/justification_detail/)
    end

    it "accepts a declaration naming modules that exist, and persists the outcome" do
      r = authored(reuse_check: { justification: "R2", justification_detail: "vendored upstream, own CVE cadence",
                                  considered: [ { module: "traefik", rejected_because: "terminates TLS, does not scrape" } ] })
      expect(r[:success]).to be(true)

      mod = ::System::NodeModule.find(r[:data][:node_module][:id])
      expect(mod.manifest_yaml).to be_present
      recorded = mod.config["reuse_check"]
      expect(recorded["justification"]).to eq("R2")
      expect(recorded["considered"].map { |c| c["module"] }).to eq([ "traefik" ])
      expect(recorded["checked_at"]).to be_present
    end

    # MCP delivers with_indifferent_access, so symbol access already works over
    # the wire; this pins the string-keyed fallback for any other in-process
    # caller and keeps normalize_hash honest.
    it "accepts string-keyed params" do
      r = authored("reuse_check" => { "justification" => "R3", "justification_detail" => "opt-in heavy payload",
                                      "considered" => [ { "module" => "traefik", "rejected_because" => "different purpose" } ] })
      expect(r[:success]).to be(true)
    end

    it "does not gate a bare-field create — no manifest, so the planner cannot build it" do
      r = call("system_create_module", name: "barefields", node_platform_id: platform_record.id,
                                       category_id: category.id)
      expect(r[:success]).to be(true)
    end

    it "does not gate a re-import onto a name already in the buildable set" do
      r = call("system_update_module", module_id: incumbent.id,
                                       manifest_yaml: "schema_version: 1\nname: traefik\nfile_spec:\n  - \"/usr/local/bin/traefik\"\nreboot_required: false\n")
      expect(r[:success]).to be(true)
    end

    it "gates the create-bare-then-update bypass: the update that FIRST makes a row buildable" do
      bare = create(:system_node_module, account: account, node_platform: platform_record, name: "sneaky")
      expect(bare.manifest_yaml).to be_blank

      r = call("system_update_module", module_id: bare.id,
                                       manifest_yaml: "schema_version: 1\nname: sneaky\nfile_spec:\n  - \"/usr/local/bin/sneaky\"\nreboot_required: false\n")
      expect(r[:success]).to be(false)
      expect(r[:error]).to match(/reuse_check/)
      expect(bare.reload.manifest_yaml).to be_blank
    end

    it "accepts an authoring UPDATE that declares its reuse check, and persists it" do
      bare = create(:system_node_module, account: account, node_platform: platform_record, name: "declared")
      r = call("system_update_module", module_id: bare.id,
                                       reuse_check: { justification: "R1",
                                                      justification_detail: "two node types consume it today",
                                                      considered: [ { module: "traefik", rejected_because: "proxy, not a scraper" } ] },
                                       manifest_yaml: "schema_version: 1\nname: declared\nfile_spec:\n  - \"/usr/local/bin/declared\"\nreboot_required: false\n")
      expect(r[:success]).to be(true)
      expect(bare.reload.manifest_yaml).to be_present
      expect(bare.config["reuse_check"]["justification"]).to eq("R1")
    end

    it "ignores a reuse_check on an UNGATED re-import rather than recording it as verified" do
      # The gate early-returns for a name already in the buildable set, so this
      # declaration was never checked — recording it would stamp unverified junk
      # with a checked_at that reads as proof.
      r = call("system_update_module", module_id: incumbent.id,
                                       reuse_check: { justification: "R9",
                                                      considered: [ { module: "invented-module" } ] },
                                       manifest_yaml: "schema_version: 1\nname: traefik\nfile_spec:\n  - \"/usr/local/bin/traefik\"\nreboot_required: false\n")
      expect(r[:success]).to be(true)
      expect(incumbent.reload.config.to_h["reuse_check"]).to be_nil
    end

    it "does not mint an extra version when it stamps the declaration" do
      # config is in NodeModule::VERSIONED_ATTRIBUTES, so a plain update! here
      # would fire after_update :auto_create_version and re-point current_version
      # at a second, artifact-less version — right after the manifest import
      # suppressed that same callback to snapshot exactly one.
      r = authored(reuse_check: { justification: "R2", justification_detail: "own CVE cadence",
                                  considered: [ { module: "traefik", rejected_because: "different purpose" } ] })
      expect(r[:success]).to be(true)

      mod = ::System::NodeModule.find(r[:data][:node_module][:id])
      expect(mod.versions.count).to eq(1)
      expect(mod.current_version_id).to eq(r[:data][:node_module_version_id])
    end

    it "asks the novelty question through the planner's own seam" do
      expect(::System::ModuleBuildPlannerService.buildable_module_names(account)).to include("traefik")
      expect(::System::ModuleBuildPlannerService.buildable_module_names(account)).not_to include("newmod")
    end
  end

  # IMP-c0687cfb3a05. A federated deploy always mints a single-use federation
  # acceptance token (System::SpawnPlatformService#spawn! — unconditional, not a
  # flag) and the plaintext came back in the tool result TWICE: once as
  # `acceptance_token` and again inside `spawn_payload`.
  #
  # A tool return does not stop at its caller. Ai::AgentToolBridgeService appends
  # the full result JSON as a `role: "tool"` message and sends it to the model
  # provider on the next loop iteration. This action is additionally in that
  # service's CARD_TOOLS map, so the full UNTRUNCATED data payload is copied
  # into a chat card that ConciergeService writes to
  # ai_messages.content_metadata — measured on HEAD: both copies persisted to
  # the column. (The 200-char tool_calls_log preview did NOT reach it: plaintext
  # sat at offsets 245 and 370 of a 1146-char result, behind three UUIDs.)
  # Ai::SensitiveParams cannot intervene on either — #filter returns non-Hash
  # input unchanged, and the card payload never passes through it.
  #
  # The refusal is up front rather than a silent omission: minting a token no
  # caller can read would strand a FederationPeer whose digest is the only thing
  # that can accept it, with a child VM already provisioned against it.
  describe "system_deploy_platform federated token minting (IMP-c0687cfb3a05)" do
    let(:deploy_user)     { create(:user, account: account) }
    let(:deploy_template) { create(:system_node_template, account: account, name: "powernode-hub-spec") }
    # Shadows the outer tool so the deploy carries an initiating user, as the
    # concierge path does.
    let(:tool) { described_class.new(account: account, user: deploy_user, internal: true) }

    # Never a real mint. The surface must refuse before reaching the model, so
    # this marker doubles as the tripwire: if it appears anywhere in the result,
    # a plaintext token reached the MCP surface.
    let(:synthetic_token) { "SYNTHETIC-NOT-A-REAL-TOKEN-0000000000000000" }
    # Counts mints without asserting on a real one. allow_any_instance_of has no
    # spy form, so the block records the call itself.
    let(:mint_calls) { [] }

    before do
      recorder = mint_calls
      token = synthetic_token
      allow_any_instance_of(::System::FederationPeer)
        .to receive(:generate_acceptance_token!) do |_peer, **_kwargs|
          recorder << true
          token
        end
      # Keep the spawn off the provider layer; the leak is in what comes back,
      # not in what gets built.
      allow_any_instance_of(::Federation::SpawnProvisioner)
        .to receive(:provision!)
        .and_return({ ok?: true, node_id: nil, node_instance_id: nil,
                      provider_type: "proxmox", cloud_id: "vm-9001", error: nil })
    end

    def deploy(**rest)
      call("system_deploy_platform", name: "child-platform",
                                     template_slug: deploy_template.name, **rest)
    end

    def federated_deploy(**rest)
      deploy(mode: "federated", parent_url: "https://parent.example.test",
             spawn_mode: "managed_child", **rest)
    end

    context "with mode: federated" do
      # The wording assertion is load-bearing, not decoration. Without it this
      # example passes for the WRONG reason when both refusals are removed: the
      # tool also stopped forwarding spawn_mode, so the orchestrator raises
      # "Invalid spawn_mode" before SpawnPlatformService ever mints. Absence of
      # plaintext would then be evidence of param starvation, not of a refusal —
      # and would silently stop being evidence the day someone restores
      # forwarding (the orchestrator still declares the param).
      it "refuses instead of returning the plaintext under any key" do
        r = federated_deploy

        expect(r.to_json).not_to include(synthetic_token),
                                 "a plaintext acceptance token reached the MCP tool result"
        expect(r[:success]).to be false
        expect(r[:error]).to include("MCP tool surface"),
                            "no plaintext appeared, but a refusal is not what prevented it"
      end

      # The two refusals (tool + executor) are worded differently on purpose:
      # asserting the MCP-surface wording is what makes this arm independently
      # killable. A shared oracle would have been satisfied by whichever arm
      # answered, pinning neither.
      it "names the operator path that can deliver the token" do
        r = federated_deploy

        expect(r[:error]).to include("MCP tool surface"),
                             "the tool did not refuse — something downstream answered instead"
        expect(r[:error]).to include("/api/v1/system/platform/deployments"),
                             "the refusal does not tell the caller where the token CAN be obtained"
      end

      # Fail loud, not silently strand: a peer minted with a token nobody can
      # read is worse than no peer, because the digest is the only thing that
      # can accept it — and the child is provisioned against it.
      it "mints nothing, creates no peer, and provisions no child" do
        expect { @r = federated_deploy }.not_to change(::System::FederationPeer, :count)

        expect(mint_calls).to be_empty, "a token was minted and then withheld, stranding the peer"
        expect(::System::PlatformDeployment.count).to eq(0)
        # Same trap as above: with the refusals gone, the orchestrator's own
        # spawn_mode validation also creates no peer. Pin that the refusal is
        # what stopped it.
        expect(@r[:error]).to include("MCP tool surface"),
                              "nothing was created, but a refusal is not what prevented it"
      end

      # CONTROL, not evidence: PlatformDeployExecutor matches on `mode.to_s`, so
      # " Federated " never reached the mint on HEAD either — it fell through to
      # "Unknown mode". What this pins is that the refusal is BROADER than the
      # mint's acceptance, so tightening it to a literal comparison (the shape
      # that let a string "true" walk past the sibling's refusal) is caught.
      #
      # The oracle has to name the MCP-surface wording, not just the operator
      # path: a literal-comparison mutant on the tool still yields success:false
      # AND the operator path, because the executor's own refusal catches the
      # spelling one layer down. That mutant survived the looser oracle.
      it "refuses the spellings a JSON boundary produces, not just the exact literal" do
        r = federated_deploy(mode: " Federated ")

        expect(r[:success]).to be false
        expect(r[:error]).to include("MCP tool surface"),
                             "a mode spelling walked past the tool's refusal and was answered downstream"
        expect(r[:error]).to include("/api/v1/system/platform/deployments")
        expect(mint_calls).to be_empty
      end
    end

    # Guard: the refusal is scoped to the federated path, not to the action.
    # This is what keeps the fix from reading as a removal of the capability.
    context "the paths that stay open" do
      it "still deploys standalone" do
        provisioned = instance_double("ProvisionResult", success?: true, data: { instance: nil })
        allow(::System::ProvisioningService).to receive(:provision_instance).and_return(provisioned)

        r = deploy(mode: "standalone")

        expect(r[:success]).to be(true), "standalone deployment was refused too: #{r[:error]}"
        expect(r[:data][:mode]).to eq("standalone")
        expect(::System::ProvisioningService).to have_received(:provision_instance)
      end

      it "still returns the wizard payload, still offering federated to the OPERATOR form" do
        r = deploy

        expect(r[:success]).to be true
        modes = r[:data][:card][:modes].map { |m| m[:value] }
        # The wizard feeds PlatformDeploymentWizardCard, which submits to
        # POST /system/platform/deployments — the REST path, which is unaffected.
        # Dropping federated here would break the operator's only safe route.
        expect(modes).to include("federated")
      end
    end

    # Guard: the operator path still delivers. DeploymentsController#create calls
    # this orchestrator directly and renders result.acceptance_token into its
    # HTTP response, which is where PlatformDeploymentWizardCard's copy button
    # reads it from.
    #
    # Mints for REAL (overriding the outer stub) so this cannot degrade into
    # "the orchestrator returns whatever the stub was handed": the delivered
    # plaintext has to verify against the digest the peer actually stored. The
    # value is never printed.
    it "leaves the operator orchestrator path delivering a token that verifies" do
      allow_any_instance_of(::System::FederationPeer)
        .to receive(:generate_acceptance_token!).and_call_original

      result = ::System::PlatformDeploymentOrchestrator.deploy!(
        account: account,
        mode: "federated",
        params: { name: "operator-child", template_slug: deploy_template.name,
                  parent_url: "https://parent.example.test", spawn_mode: "managed_child" },
        initiated_by_user: deploy_user
      )

      expect(result.ok?).to be(true), "the operator deploy path broke: #{result.error}"
      expect(result.acceptance_token).to be_present,
                                         "the operator delivery path stopped returning the token"

      peer = ::System::FederationPeer.find(result.federation_peer_id)
      expect(peer.acceptance_token_error(result.acceptance_token)).to be_nil,
             "the delivered plaintext does not verify against the digest the peer stored"
    end

    # The skill executor is the same agent-facing surface (it is bound to System
    # Concierge and discoverable via get_skill_context), and it is what the tool
    # delegates to. Pinned separately so the two refusals are independently
    # killable: removing either one reds only its own examples.
    it "refuses at the skill executor too, naming the same operator path" do
      executor = ::System::Ai::Skills::PlatformDeployExecutor.new(
        account: account, agent: nil, user: deploy_user
      )

      expect {
        @r = executor.execute(mode: "federated", name: "child-platform",
                              template_slug: deploy_template.name,
                              parent_url: "https://parent.example.test",
                              spawn_mode: "managed_child")
      }.not_to change(::System::FederationPeer, :count)

      expect(@r[:success]).to be false
      expect(@r.to_json).not_to include(synthetic_token)
      expect(@r[:error]).to include("platform_deploy skill"),
                          "the skill layer did not refuse on its own"
      expect(@r[:error]).to include("/api/v1/system/platform/deployments")
      expect(mint_calls).to be_empty
    end

    # The plan-time surfaces must not advertise a path that now refuses —
    # otherwise a model reads "returns acceptance_token" and calls it.
    it "no longer advertises token minting on either plan-time schema" do
      tool_schema = described_class.action_definitions.fetch("system_deploy_platform")
      expect(tool_schema[:parameters]).not_to have_key(:token_ttl_seconds)
      expect(tool_schema[:description]).to include("/api/v1/system/platform/deployments")

      outputs = ::System::Ai::Skills::PlatformDeployExecutor.descriptor[:outputs]
      expect(outputs).not_to have_key(:acceptance_token)
      expect(outputs).not_to have_key(:spawn_payload)
    end
  end
end
