# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M0.J — dependant module restoration.
# Reference: ~/Drive/Projects/powernode-server/app/models/node_module.rb (parent_module
# pattern, lines 11-14, 154-162) and node_module_subscription.rb:11-17 (create_dependant_module!).
RSpec.describe System::NodeModule, "dependant modules", type: :model do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account, name: "Base") }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }

  let(:base_module) do
    create(
      :system_node_module,
      account: account, node_platform: platform, category: category,
      variety: "subscription", name: "nginx-mod", priority: 5
    )
  end
  let(:assignment) do
    System::NodeModuleAssignment.create!(node: node, node_module: base_module, enabled: true, priority: 0)
  end

  describe "#dependant? / scopes" do
    it "is false for base modules and true for children" do
      expect(base_module).not_to be_dependant
      child = assignment.create_dependant!
      expect(child).to be_dependant
    end

    it "exposes :dependants and :base_modules scopes" do
      child = assignment.create_dependant!
      expect(System::NodeModule.dependants).to include(child)
      expect(System::NodeModule.dependants).not_to include(base_module)
      expect(System::NodeModule.base_modules).to include(base_module)
      expect(System::NodeModule.base_modules).not_to include(child)
    end
  end

  describe "NodeModuleAssignment#create_dependant! (config variety)" do
    it "creates a config-variety child bound to the node" do
      child = assignment.create_dependant!

      expect(child).to be_persisted
      expect(child.parent_module).to eq(base_module)
      expect(child.node).to eq(node)
      expect(child.node_instance).to be_nil
      expect(child.variety).to eq("config")
    end

    it "inherits node_platform + category + account from the parent" do
      child = assignment.create_dependant!
      expect(child.node_platform).to eq(platform)
      expect(child.category).to eq(category)
      expect(child.account).to eq(account)
    end

    it "is idempotent — returns existing child instead of creating duplicates" do
      child1 = assignment.create_dependant!
      child2 = assignment.create_dependant!
      expect(child1).to eq(child2)
      expect(System::NodeModule.where(parent_module: base_module, node: node).count).to eq(1)
    end

    it "sets child priority to parent.priority + 1" do
      child = assignment.create_dependant!
      expect(child.priority).to eq(base_module.priority + 1)
    end
  end

  describe "NodeModuleAssignment#create_dependant! (instance variety)" do
    it "creates an instance-variety child bound to (node, instance)" do
      child = assignment.create_dependant!(node_instance: instance)

      expect(child.parent_module).to eq(base_module)
      expect(child.node).to eq(node)
      expect(child.node_instance).to eq(instance)
      expect(child.variety).to eq("instance")
    end

    it "is idempotent at the (parent, node, instance) tuple" do
      a = assignment.create_dependant!(node_instance: instance)
      b = assignment.create_dependant!(node_instance: instance)
      expect(a).to eq(b)
    end

    it "creates separate children for config and instance varieties" do
      config_child = assignment.create_dependant!
      instance_child = assignment.create_dependant!(node_instance: instance)
      expect(config_child).not_to eq(instance_child)
      expect(config_child.variety).to eq("config")
      expect(instance_child.variety).to eq("instance")
    end
  end

  describe "#display_name (parent-aware rendering)" do
    it "returns the bare name for a base module" do
      expect(base_module.display_name).to eq("nginx-mod")
    end

    it "renders 'parent for node-name' for config-variety children" do
      child = assignment.create_dependant!
      expect(child.display_name).to eq("nginx-mod for #{node.name}")
    end

    it "renders 'parent for instance-name' for instance-variety children" do
      child = assignment.create_dependant!(node_instance: instance)
      expect(child.display_name).to eq("nginx-mod for #{instance.name}")
    end
  end

  describe "create_dependant! safety" do
    it "refuses to create a dependant of an already-dependant module" do
      child = assignment.create_dependant!
      child_assignment = System::NodeModuleAssignment.create!(
        node: node, node_module: child, enabled: true, priority: 0
      )
      expect { child_assignment.create_dependant! }.to raise_error(ArgumentError, /already-dependant/)
    end
  end

  # `dependency_spec` semantics: the file-spec a dependant child inherits
  # from its parent. Reading `file_spec` on a dependant transparently
  # resolves to `parent.dependency_spec` rather than the child's own
  # column. See node_module.rb#file_spec — mirrors legacy line 124.
  describe "#file_spec inheritance from parent.dependency_spec" do
    it "returns the parent's dependency_spec for dependant children" do
      base_module.update!(dependency_spec: "/etc/nginx/sites-enabled/**\n/var/www/inherited/**")
      child = assignment.create_dependant!

      decoded = base_module.send(:decode_spec, child.file_spec).sort
      expect(decoded).to include("/etc/nginx/sites-enabled/**", "/var/www/inherited/**")
    end

    it "tracks live changes to the parent's dependency_spec" do
      child = assignment.create_dependant!
      base_module.update!(dependency_spec: "/etc/v1/**")
      decoded_v1 = base_module.send(:decode_spec, child.file_spec).sort
      expect(decoded_v1).to eq([ "/etc/v1/**" ])

      base_module.update!(dependency_spec: "/etc/v2/**\n/etc/v2-extra/**")
      decoded_v2 = base_module.send(:decode_spec, child.reload.file_spec).sort
      expect(decoded_v2).to eq([ "/etc/v2-extra/**", "/etc/v2/**" ])
    end

    it "ignores the dependant child's own file_spec column when parent is set" do
      base_module.update!(dependency_spec: "/from/parent/**")
      child = assignment.create_dependant!
      # Direct column write on the child — silently shadowed for dependants.
      child.update!(file_spec: "/this/should/be/ignored/**")

      decoded = base_module.send(:decode_spec, child.file_spec).sort
      expect(decoded).to eq([ "/from/parent/**" ])
    end

    it "returns its own column for non-dependant (base) modules" do
      base_module.update!(file_spec: "/etc/own/**", dependency_spec: "/inherited/**")
      decoded = base_module.send(:decode_spec, base_module.file_spec).sort
      expect(decoded).to eq([ "/etc/own/**" ])
    end

    it "file_spec_text on a dependant reflects parent's dependency_spec" do
      base_module.update!(dependency_spec: "/inherited/path")
      child = assignment.create_dependant!
      expect(child.file_spec_text).to include("/inherited/path")
    end

    it "rsync_spec on a dependant emits parent's dependency_spec as include rules" do
      base_module.update!(dependency_spec: "/etc/inherited/**")
      child = assignment.create_dependant!
      expect(child.rsync_spec).to include("+ /etc/inherited/**\n")
    end
  end
end
