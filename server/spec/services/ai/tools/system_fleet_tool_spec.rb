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
  end
end
