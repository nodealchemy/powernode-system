# frozen_string_literal: true

require "rails_helper"

# Environment campaign, increment 1 — every fleet row knows its plane.
#
# The template is the anchor: it always has an environment (the account
# default when its creator says nothing), a node inherits the template's, an
# instance the node's, a pool the template's. The refusals are for the ways a
# value can be WRONG: cleared after creation, or borrowed from another account.
RSpec.describe "fleet rows carry an environment" do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }

  def env(slug) = account.environments.find_by!(slug: slug)

  describe System::NodeTemplate do
    it "lands in the account default environment when its creator says nothing" do
      template = create(:system_node_template, account: account, node_platform: platform)
      expect(template.environment).to eq(env("dev"))
    end

    it "keeps an explicit environment" do
      template = create(:system_node_template, account: account, node_platform: platform, environment: env("prod"))
      expect(template.reload.environment.slug).to eq("prod")
      expect(described_class.in_environment(env("prod"))).to include(template)
    end

    it "refuses to be cleared after creation" do
      template = create(:system_node_template, account: account, node_platform: platform)
      template.environment = nil
      expect(template).not_to be_valid
      expect(template.errors[:environment]).to be_present
    end

    it "refuses another account's environment" do
      foreign = create(:account).environments.find_by!(slug: "dev")
      template = build(:system_node_template, account: account, node_platform: platform, environment: foreign)
      expect(template).not_to be_valid
      expect(template.errors[:environment]).to include("must belong to the template's account")
    end
  end

  describe "inheritance down the fleet" do
    let(:template) { create(:system_node_template, account: account, node_platform: platform, environment: env("ops")) }

    it "node <- template, instance <- node, pool <- template" do
      node = create(:system_node, account: account, node_template: template)
      expect(node.environment).to eq(env("ops"))

      instance = create(:system_node_instance, node: node)
      expect(instance.environment).to eq(env("ops"))
      expect(System::NodeInstance.in_environment(env("ops"))).to include(instance)

      pool = System::InstancePool.create!(account: account, node_template: template, name: "ops-pool",
                                          lifecycle_class: "ephemeral", status: "active",
                                          target_size: 0, min_size: 0, max_size: 1)
      expect(pool.environment).to eq(env("ops"))
    end

    it "refuses a node on another account's template, naming the template as the cause" do
      foreign_template = create(:system_node_template, account: create(:account))
      bad = build(:system_node, account: account, node_template: foreign_template)

      expect(bad).not_to be_valid
      expect(bad.errors[:node_template]).to include("must belong to the node's account")
      expect(bad.errors[:environment]).to be_empty
    end

    it "a node may override its template's environment but not borrow another account's" do
      node = create(:system_node, account: account, node_template: template, environment: env("staging"))
      expect(node.reload.environment.slug).to eq("staging")

      foreign = create(:account).environments.find_by!(slug: "dev")
      bad = build(:system_node, account: account, node_template: template, environment: foreign)
      expect(bad).not_to be_valid
    end
  end

  describe "serializers" do
    it "expose environment_id and environment_slug on template, node and instance rows" do
      template = create(:system_node_template, account: account, node_platform: platform, environment: env("ci"))
      node = create(:system_node, account: account, node_template: template)
      instance = create(:system_node_instance, node: node)

      expect(System::NodeTemplateSerializer.new(template).as_json).to include(environment_slug: "ci", environment_id: env("ci").id)
      expect(System::NodeSerializer.new(node).as_json).to include(environment_slug: "ci")
      expect(System::NodeInstanceSerializer.new(instance).as_json).to include(environment_slug: "ci")
    end
  end

  describe "operator placement through the fleet tool" do
    let(:tool) { Ai::Tools::SystemFleetTool.new(account: account, internal: true) }
    let(:template) { create(:system_node_template, account: account, node_platform: platform) }

    def call(action, **rest) = tool.execute(params: { action: action }.merge(rest))

    it "system_update_template moves a template by slug and new nodes inherit it" do
      r = call("system_update_template", template_id: template.id, environment: "ops")
      expect(r[:success]).to be true
      expect(template.reload.environment.slug).to eq("ops")

      node = create(:system_node, account: account, node_template: template)
      expect(node.environment.slug).to eq("ops")
    end

    it "system_update_node overrides one node without touching its template" do
      node = create(:system_node, account: account, node_template: template)
      r = call("system_update_node", node_id: node.id, environment: env("prod").id)
      expect(r[:success]).to be true
      expect(node.reload.environment.slug).to eq("prod")
      expect(template.reload.environment.slug).to eq("dev")
    end

    it "refuses an unknown environment instead of silently ignoring it" do
      r = call("system_update_template", template_id: template.id, environment: "moon")
      expect(r[:success]).to be false
      expect(r[:error]).to include("moon")
      expect(template.reload.environment.slug).to eq("dev")
    end

    it "lists rows with their environment slug" do
      template.update!(environment: env("ci"))
      r = call("system_list_templates")
      row = r.dig(:data, :templates).find { |t| t[:id] == template.id }
      expect(row).to include(environment_slug: "ci", environment_id: env("ci").id)
    end
  end

  describe "deletion" do
    it "refuses to destroy an environment that still holds fleet rows, and the account teardown stays a clean refusal" do
      template = create(:system_node_template, account: account, node_platform: platform, environment: env("staging"))

      staging = env("staging")
      expect(staging.destroy).to be false
      expect(staging.errors[:base].join).to include("templates")

      expect { expect(account.destroy).to be false }.not_to raise_error
      expect(System::NodeTemplate.exists?(template.id)).to be true
    end
  end
end
