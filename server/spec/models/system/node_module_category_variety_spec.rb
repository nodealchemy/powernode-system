# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse polish — NodeModuleCategory variety + sibling resolution.
RSpec.describe System::NodeModuleCategory, "variety + siblings", type: :model do
  let(:account) { create(:account) }

  describe "VARIETIES + variety predicates" do
    it "validates variety inclusion" do
      cat = build(:system_node_module_category, account: account, variety: "garbage")
      expect(cat).not_to be_valid
      expect(cat.errors[:variety]).to be_present
    end

    it "exposes <variety>_variety? predicates" do
      sub = create(:system_node_module_category, account: account, name: "S", variety: "subscription")
      cfg = create(:system_node_module_category, account: account, name: "C", variety: "config")
      ins = create(:system_node_module_category, account: account, name: "I", variety: "instance")
      expect(sub).to be_subscription_variety
      expect(cfg).to be_config_variety
      expect(ins).to be_instance_variety
      expect(cfg).not_to be_subscription_variety
    end
  end

  describe ".create_triplet!" do
    it "creates 3 wired-up categories with ascending positions" do
      sub = described_class.create_triplet!(account: account, base_name: "Web", base_position: 100)

      expect(sub.variety).to eq("subscription")
      expect(sub.position).to eq(100)
      expect(sub.config_category).to be_present
      expect(sub.instance_category).to be_present

      expect(sub.config_category.variety).to eq("config")
      expect(sub.config_category.position).to eq(101)

      expect(sub.instance_category.variety).to eq("instance")
      expect(sub.instance_category.position).to eq(102)
    end

    it "is rolled back atomically if any inner create fails" do
      stub_const("System::NodeModuleCategory::DEFAULT_POSITION_OFFSETS",
                 { "subscription" => 0, "config" => 0, "instance" => 0 })
      # Same position triplet still works (no uniqueness on position),
      # but force a name collision to trigger rollback.
      create(:system_node_module_category, account: account, name: "Dup (config)")

      expect {
        described_class.create_triplet!(account: account, base_name: "Dup")
      }.to raise_error(ActiveRecord::RecordInvalid)
      expect(described_class.where(account: account, name: "Dup")).to be_empty
      expect(described_class.where(account: account, name: "Dup (instance)")).to be_empty
    end
  end

  describe "#category_for_variety" do
    let!(:sub) { described_class.create_triplet!(account: account, base_name: "Tier", base_position: 50) }

    it "returns config sibling for 'config'" do
      expect(sub.category_for_variety("config")).to eq(sub.config_category)
    end

    it "returns instance sibling for 'instance'" do
      expect(sub.category_for_variety("instance")).to eq(sub.instance_category)
    end

    it "returns self for unknown variety" do
      expect(sub.category_for_variety("garbage")).to eq(sub)
    end

    it "falls back to self when sibling is missing" do
      lonely = create(:system_node_module_category, account: account, name: "Lonely", variety: "subscription")
      expect(lonely.config_category).to be_nil
      expect(lonely.category_for_variety("config")).to eq(lonely)
    end
  end
end

RSpec.describe System::NodeModuleAssignment, "create_dependant! with category siblings", type: :model do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category_triplet) do
    System::NodeModuleCategory.create_triplet!(account: account, base_name: "Tier", base_position: 50)
  end
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }
  let(:base_module) do
    create(:system_node_module,
           account: account, node_platform: platform, category: category_triplet,
           variety: "subscription", name: "tier-mod", priority: 7)
  end
  let(:assignment) do
    System::NodeModuleAssignment.create!(node: node, node_module: base_module, enabled: true, priority: 0)
  end

  it "places config children under the sibling config_category" do
    child = assignment.create_dependant!
    expect(child.category).to eq(category_triplet.config_category)
    expect(child.variety).to eq("config")
  end

  it "places instance children under the sibling instance_category" do
    child = assignment.create_dependant!(node_instance: instance)
    expect(child.category).to eq(category_triplet.instance_category)
    expect(child.variety).to eq("instance")
  end

  it "child effective_priority is strictly greater than parent's via category multiplier" do
    child = assignment.create_dependant!
    expect(child.effective_priority).to be > base_module.effective_priority
    # Same parent.priority preserved; the category multiplier does the work
    expect(child.priority).to eq(base_module.priority)
  end

  it "instance child outranks config child outranks subscription parent" do
    config_child   = assignment.create_dependant!
    instance_child = assignment.create_dependant!(node_instance: instance)

    expect(instance_child.effective_priority).to be > config_child.effective_priority
    expect(config_child.effective_priority).to be > base_module.effective_priority
  end

  it "fallback path (no sibling categories): bumps priority + 1 like before" do
    plain_cat = create(:system_node_module_category, account: account, name: "Plain", variety: "subscription")
    plain_mod = create(:system_node_module, account: account, node_platform: platform,
                       category: plain_cat, variety: "subscription", name: "plain-mod", priority: 3)
    plain_assign = System::NodeModuleAssignment.create!(
      node: node, node_module: plain_mod, enabled: true, priority: 0
    )
    child = plain_assign.create_dependant!
    expect(child.priority).to eq(4) # parent.priority + 1
    expect(child.category).to eq(plain_cat) # fallback to parent's category
  end
end
