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
  let(:tool)     { described_class.new(account: account) }

  def call(action, **rest)
    tool.execute(params: { action: action }.merge(rest))
  end

  describe ".action_definitions" do
    it "registers all 17 system_* actions" do
      keys = described_class.action_definitions.keys
      expect(keys.size).to be >= 17
      expect(keys).to all(start_with("system_"))
    end
  end

  describe "Nodes — create / list / get" do
    it "system_create_node creates a node bound to the template" do
      r = call("system_create_node", name: "fleet-node-1", template_id: template.id)
      expect(r[:success]).to be true
      expect(r.dig(:data, :node, :name)).to eq("fleet-node-1")
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
        affected_packages: [{ "name" => "openssl", "version" => "<3.1.4" }],
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
                 affected_packages: [{ "name" => "redis" }])
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

      it "transitions claimed → ready and clears pool_acquired_at" do
        r = call("system_return_pooled_instance", instance_id: claimed_instance.id)
        expect(r[:success]).to be true
        expect(r[:data][:returned]).to be true

        claimed_instance.reload
        expect(claimed_instance.pool_state).to eq("ready")
        expect(claimed_instance.pool_acquired_at).to be_nil
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
      let!(:published) { create(:system_disk_image_publication, account: account, node_platform: platform_record_for_pubs, status: "published", oci_ref: "git.ipnode.org/test:abc", git_sha: "test-sha-promoted") }

      it "copies oci_ref + git_sha onto the parent NodePlatform" do
        r = call("system_set_default_disk_image_publication", publication_id: published.id)
        expect(r[:success]).to be true
        expect(r[:data][:set_default]).to be true

        platform_record_for_pubs.reload
        expect(platform_record_for_pubs.disk_image_oci_ref).to eq("git.ipnode.org/test:abc")
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
        ::Worker.create_worker!(name: "member-worker", account: account, roles: ["member"])
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
        member_worker = ::Worker.create_worker!(name: "member-worker-2", account: account, roles: ["member"])
        r = call("system_terminate_ci_worker", worker_id: member_worker.id)
        expect(r[:success]).to be false
        expect(r[:error]).to include("not a ci_worker")
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
    let(:sdwan_tool) { ::Ai::Tools::SdwanTool.new(account: account) }
    let!(:proposed_peer) do
      ::Sdwan::FederationPeer.create!(
        account: account, status: "proposed",
        remote_instance_url: "https://other.example.com",
        remote_instance_id: SecureRandom.uuid
      )
    end

    it "transitions proposed → accepted with signed_at populated" do
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

    it "records acceptance_token usage in metadata when token provided" do
      sdwan_tool.execute(params: {
        action: "system_sdwan_accept_federation_peer",
        federation_peer_id: proposed_peer.id,
        acceptance_token: "abc123"
      })
      expect(proposed_peer.reload.metadata["acceptance_token_used"]).to be true
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
end
