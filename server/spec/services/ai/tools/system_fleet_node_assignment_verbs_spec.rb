# frozen_string_literal: true

require "rails_helper"

# The node-level half of module assignment over MCP. Before these two verbs a
# node's assignments could only be READ by querying the database directly
# (system_get_node carries module_count alone) and a node-level assignment
# could only be CREATED by a hand-written row — the only way a node whose
# template carries no modules (a self-hosted control-plane node is one) can
# gain a module at all.
RSpec.describe Ai::Tools::SystemFleetTool, "node module assignment verbs" do
  let(:account)         { create(:account) }
  let(:platform_record) { create(:system_node_platform, account: account) }
  let(:cat_a) { create(:system_node_module_category, account: account, name: "cat-a-#{SecureRandom.hex(3)}") }
  let(:cat_b) { create(:system_node_module_category, account: account, name: "cat-b-#{SecureRandom.hex(3)}") }
  let(:template) { create(:system_node_template, account: account, node_platform: platform_record) }
  let(:node)     { create(:system_node, account: account, node_template: template, name: "asn-#{SecureRandom.hex(3)}") }
  let(:tool)     { described_class.new(account: account, internal: true) }

  def call(action, **rest)
    tool.execute(params: { action: action }.merge(rest))
  end

  # Names that won't collide with the account bootstrap's default catalog.
  def composition_module(name, category: cat_a, variety: "subscription")
    create(:system_node_module, account: account, node_platform: platform_record,
           category: category, variety: variety, name: "#{name}-#{SecureRandom.hex(3)}")
  end

  describe "system_list_node_module_assignments" do
    let(:template_join) { create(:system_template_module, node_template: template, node_module: composition_module("from-tpl")) }
    let!(:derived) do
      create(:system_node_module_assignment, node: node, node_module: template_join.node_module,
             enabled: true, source_template_module: template_join)
    end
    let!(:manual) do
      create(:system_node_module_assignment, node: node, node_module: composition_module("by-hand", category: cat_b),
             enabled: false)
    end

    it "lists every assignment on the node with its module, enabled flag and template provenance" do
      result = call("system_list_node_module_assignments", node_id: node.id)

      expect(result[:success]).to be true
      rows = result[:data][:assignments].index_by { |r| r[:id] }
      expect(rows.keys).to match_array([ derived.id, manual.id ])
      expect(result[:data][:count]).to eq(2)

      expect(rows[derived.id]).to include(
        node_id: node.id, node_module_id: derived.node_module_id, module_name: derived.node_module.name,
        enabled: true, source_template_module_id: template_join.id
      )
      expect(rows[manual.id]).to include(enabled: false, source_template_module_id: nil,
                                         module_name: manual.node_module.name)
      expect(rows[manual.id][:created_at]).to be_present
      expect(rows[manual.id][:updated_at]).to be_present
    end

    it "paginates like the sibling list verbs" do
      first = call("system_list_node_module_assignments", node_id: node.id, limit: 1)

      expect(first[:data][:assignments].size).to eq(1)
      expect(first[:data][:has_more]).to be true
      second = call("system_list_node_module_assignments", node_id: node.id, limit: 1,
                                                          cursor: first[:data][:next_cursor])
      expect(second[:data][:assignments].size).to eq(1)
      expect(second[:data][:has_more]).to be false
      expect((first[:data][:assignments] + second[:data][:assignments]).map { |r| r[:id] })
        .to match_array([ derived.id, manual.id ])
    end

    it "does not list another account's node" do
      other_node = create(:system_node, account: create(:account))
      create(:system_node_module_assignment, node: other_node)

      result = call("system_list_node_module_assignments", node_id: other_node.id)

      expect(result[:success]).to be false
      expect(result[:data]).to be_nil
    end

    it "is a read verb gated on system.modules.read" do
      expect(described_class::ACTION_PERMISSIONS.fetch("system_list_node_module_assignments")).to eq("system.modules.read")
      expect(described_class.declared_action("system_list_node_module_assignments")&.fetch(:mutating)).to be false

      holder = create(:user, account: account, permissions: %w[system.nodes.read system.modules.read])
      expect(described_class.new(account: account, user: holder)
               .execute(params: { action: "system_list_node_module_assignments", node_id: node.id })[:success]).to be true

      denied = create(:user, account: account, permissions: %w[system.nodes.read])
      result = described_class.new(account: account, user: denied)
                              .execute(params: { action: "system_list_node_module_assignments", node_id: node.id })
      expect(result[:success]).to be false
      expect(result[:error]).to include("permission denied")
    end
  end

  describe "system_assign_module_to_node" do
    let(:mod) { composition_module("assignable") }

    it "creates an enabled, hand-authored assignment by default" do
      result = nil
      expect { result = call("system_assign_module_to_node", node_id: node.id, module_id: mod.id) }
        .to change { System::NodeModuleAssignment.where(node: node).count }.by(1)

      expect(result[:success]).to be true
      row = System::NodeModuleAssignment.find_by!(node: node, node_module: mod)
      expect(row.enabled).to be true
      expect(row.source_template_module_id).to be_nil
      expect(row.auto_resolved).to be false
      expect(result[:data][:assigned]).to be true
      expect(result[:data][:assignment]).to include(id: row.id, node_module_id: mod.id, enabled: true)
    end

    it "honours enabled=false" do
      result = call("system_assign_module_to_node", node_id: node.id, module_id: mod.id, enabled: false)

      expect(result[:success]).to be true
      expect(System::NodeModuleAssignment.find_by!(node: node, node_module: mod).enabled).to be false
    end

    it "runs the model's create callbacks (module skill registration)" do
      expect(::System::ModuleSkillRegistrar).to receive(:register_for_module!).with(node_module: mod)

      expect(call("system_assign_module_to_node", node_id: node.id, module_id: mod.id)[:success]).to be true
    end

    [ true, false ].each do |existing_enabled|
      it "refuses a module already assigned to the node (existing enabled=#{existing_enabled}) and points at the update verb" do
        existing = create(:system_node_module_assignment, node: node, node_module: mod, enabled: existing_enabled)

        result = nil
        expect { result = call("system_assign_module_to_node", node_id: node.id, module_id: mod.id, enabled: true) }
          .not_to change { System::NodeModuleAssignment.where(node: node).count }

        expect(result[:success]).to be false
        expect(result[:error]).to include("already assigned").and include("system_update_module_assignment")
        expect(result[:error]).to include(existing.id)
        expect(existing.reload.enabled).to be existing_enabled
      end
    end

    it "refuses an instance-variety collision with a module already on the node and names both" do
      installed = composition_module("inst-installed", variety: "instance")
      incoming  = composition_module("inst-incoming", variety: "instance")
      create(:system_node_module_assignment, node: node, node_module: installed, enabled: true)

      result = nil
      expect { result = call("system_assign_module_to_node", node_id: node.id, module_id: incoming.id) }
        .not_to change { System::NodeModuleAssignment.where(node: node).count }

      expect(result[:success]).to be false
      expect(result[:error]).to include(installed.name).and include(incoming.name)
    end

    it "refuses a declared Conflicts: relation even when the new assignment is created disabled" do
      # A disabled row can be enabled later by system_update_module_assignment,
      # which runs no composition check — so the create is the only place the
      # conflict can be stopped.
      installed = composition_module("conf-installed")
      incoming  = composition_module("conf-incoming", category: cat_b)
      create(:system_module_dependency, node_module: incoming, dependency: installed,
             dependency_type: "conflicts", required: false)
      create(:system_node_module_assignment, node: node, node_module: installed, enabled: true)

      result = nil
      expect { result = call("system_assign_module_to_node", node_id: node.id, module_id: incoming.id, enabled: false) }
        .not_to change { System::NodeModuleAssignment.where(node: node).count }

      expect(result[:success]).to be false
      expect(result[:error]).to include(installed.name).and include(incoming.name)
    end

    it "ignores a DISABLED existing assignment as a conflict baseline" do
      installed = composition_module("inst-disabled", variety: "instance")
      incoming  = composition_module("inst-live", variety: "instance")
      create(:system_node_module_assignment, node: node, node_module: installed, enabled: false)

      expect(call("system_assign_module_to_node", node_id: node.id, module_id: incoming.id)[:success]).to be true
    end

    it "returns protected_spec warnings alongside a successful assignment" do
      claimer = composition_module("warn-claimer")
      claimer.update!(protected_spec: "/etc/shadow")
      broad = composition_module("warn-broad", category: cat_b)
      broad.update!(file_spec: "/etc/**")
      create(:system_node_module_assignment, node: node, node_module: claimer, enabled: true)

      result = call("system_assign_module_to_node", node_id: node.id, module_id: broad.id)

      expect(result[:success]).to be true
      warning = Array(result.dig(:data, :warnings)).first
      expect(warning[:kind]).to eq("protected_spec_overlap")
      expect(warning[:severity]).to eq("warning")
    end

    it "refuses a module that is disabled in the catalog, creating nothing" do
      mod.update!(enabled: false)

      result = nil
      expect { result = call("system_assign_module_to_node", node_id: node.id, module_id: mod.id) }
        .not_to change(System::NodeModuleAssignment, :count)

      expect(result[:success]).to be false
      expect(result[:error]).to include(mod.name).and include("disabled")
    end

    it "answers a lost create race with the same readable refusal, never the raw DB error" do
      allow_any_instance_of(System::NodeModuleAssignment)
        .to receive(:save!).and_raise(ActiveRecord::RecordNotUnique, "PG::UniqueViolation SENTINEL-idx-leak")

      result = call("system_assign_module_to_node", node_id: node.id, module_id: mod.id)

      expect(result[:success]).to be false
      expect(result[:error]).to include("already assigned").and include("system_update_module_assignment")
      expect(result.to_json).not_to include("SENTINEL-idx-leak")
    end

    # TemplateApplyService expands a module's closure into assignments; a
    # single node-level row does not, and node_api/modules adds nothing missing,
    # so a module whose hard dependency is absent would ship without it.
    describe "hard dependencies" do
      let(:needed)   { composition_module("dep-needed", category: cat_b) }
      let(:consumer) { composition_module("dep-consumer") }

      before do
        create(:system_module_dependency, node_module: consumer, dependency: needed,
               dependency_type: "requires", required: true)
      end

      it "refuses when a required dependency is neither assigned-and-enabled nor supplied by the template, naming it" do
        result = nil
        expect { result = call("system_assign_module_to_node", node_id: node.id, module_id: consumer.id) }
          .not_to change(System::NodeModuleAssignment, :count)

        expect(result[:success]).to be false
        expect(result[:error]).to include(needed.name).and include("system_assign_module_to_node")
      end

      it "refuses when the dependency is assigned to the node but disabled" do
        create(:system_node_module_assignment, node: node, node_module: needed, enabled: false)

        result = call("system_assign_module_to_node", node_id: node.id, module_id: consumer.id)

        expect(result[:success]).to be false
        expect(result[:error]).to include(needed.name)
      end

      it "refuses when the dependency is disabled in the catalog" do
        needed.update!(enabled: false)
        create(:system_node_module_assignment, node: node, node_module: needed, enabled: true)

        result = call("system_assign_module_to_node", node_id: node.id, module_id: consumer.id)

        expect(result[:success]).to be false
        expect(result[:error]).to include(needed.name)
      end

      it "assigns when the dependency is already assigned and enabled on the node" do
        create(:system_node_module_assignment, node: node, node_module: needed, enabled: true)

        expect(call("system_assign_module_to_node", node_id: node.id, module_id: consumer.id)[:success]).to be true
      end

      it "assigns when the node's template supplies the dependency" do
        create(:system_template_module, node_template: template, node_module: needed, enabled: true)

        expect(call("system_assign_module_to_node", node_id: node.id, module_id: consumer.id)[:success]).to be true
      end

      it "does not treat a recommends edge as a hard dependency" do
        optional = composition_module("dep-optional", category: cat_b)
        create(:system_module_dependency, node_module: mod, dependency: optional,
               dependency_type: "recommends", required: false)

        expect(call("system_assign_module_to_node", node_id: node.id, module_id: mod.id)[:success]).to be true
      end
    end

    it "refuses another account's node" do
      other_node = create(:system_node, account: create(:account))

      result = nil
      expect { result = call("system_assign_module_to_node", node_id: other_node.id, module_id: mod.id) }
        .not_to change(System::NodeModuleAssignment, :count)
      expect(result[:success]).to be false
    end

    it "refuses another account's module" do
      foreign = create(:system_node_module, account: create(:account))

      result = nil
      expect { result = call("system_assign_module_to_node", node_id: node.id, module_id: foreign.id) }
        .not_to change(System::NodeModuleAssignment, :count)
      expect(result[:success]).to be false
    end

    it "is a mutating verb gated on system.modules.update, like system_update_module_assignment" do
      expect(described_class::ACTION_PERMISSIONS.fetch("system_assign_module_to_node"))
        .to eq(described_class::ACTION_PERMISSIONS.fetch("system_update_module_assignment"))
      expect(described_class.declared_action("system_assign_module_to_node")&.fetch(:mutating)).to be true

      denied = create(:user, account: account, permissions: %w[system.nodes.read system.modules.read])
      result = nil
      expect do
        result = described_class.new(account: account, user: denied)
                                .execute(params: { action: "system_assign_module_to_node", node_id: node.id, module_id: mod.id })
      end.not_to change(System::NodeModuleAssignment, :count)
      expect(result[:error]).to include("permission denied")

      holder = create(:user, account: account, permissions: %w[system.nodes.read system.modules.update])
      expect(described_class.new(account: account, user: holder)
               .execute(params: { action: "system_assign_module_to_node", node_id: node.id, module_id: mod.id })[:success]).to be true
    end
  end

  it "registers both verbs against SystemFleetTool" do
    %w[system_list_node_module_assignments system_assign_module_to_node].each do |action|
      expect(Ai::Tools::PlatformApiToolRegistry::TOOLS[action]).to eq("Ai::Tools::SystemFleetTool")
    end
  end
end
