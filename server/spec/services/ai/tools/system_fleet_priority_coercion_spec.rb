# frozen_string_literal: true

require "rails_helper"

# `priority` on the TemplateModule write actions used to be read as
# `params[:priority].to_i`, which fails two ways:
#
#   NON-SCALAR — a Hash or Array has no #to_i, so it raised NoMethodError. From
#     an MCP tool a raised exception surfaces as a raw protocol error rather
#     than a refusal the caller can read.
#   BAD STRING — "abc".to_i is 0, SILENTLY. priority orders modules within a
#     composition and 0 is the lowest, so a typo did not fail; it quietly
#     changed which module wins a conflict. This is the worse half: a raised
#     error is loud and gets fixed, a wrong answer is not.
#
# The REST twin of these assertions lives in
# spec/requests/api/v1/system/node_templates_modules_spec.rb — the two surfaces
# render refusals differently (422 vs error_result), so neither spec is
# evidence for the other.
RSpec.describe Ai::Tools::SystemFleetTool, "priority coercion" do
  let(:account)  { create(:account) }
  let(:user)     { create(:user, account: account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account, variety: "subscription") }

  subject(:tool) { described_class.new(account: account, agent: nil, user: user) }

  let(:template) do
    create(:system_node_template, account: account, node_platform: platform, name: "prio-tmpl")
  end

  let(:node_module) do
    create(:system_node_module, account: account, node_platform: platform, category: category,
           variety: "subscription", name: "prio-mod-#{SecureRandom.hex(3)}")
  end

  let!(:join) do
    ::System::TemplateModule.create!(node_template: template, node_module: node_module, priority: 42)
  end

  def update(priority)
    tool.send(:update_template_module,
              { template_id: template.id, module_id: node_module.id, priority: priority })
  end

  describe "refuses input it cannot read as an integer" do
    it "returns an error_result rather than raising on a non-scalar priority" do
      result = nil
      expect { result = update({ "n" => 1 }) }.not_to raise_error

      expect(result[:success]).to be(false)
      expect(result[:error]).to include("priority must be an integer")
      expect(join.reload.priority).to eq(42)
    end

    it "returns an error_result rather than silently writing 0 for a bad string" do
      result = update("abc")

      expect(result[:success]).to be(false)
      expect(result[:error]).to include("priority must be an integer")
      # The whole point: 0 is the LOWEST priority, so the silent version of
      # this bug reorders the composition instead of refusing.
      expect(join.reload.priority).to eq(42)
    end

    it "refuses a float rather than truncating it" do
      result = update(2.7)

      expect(result[:success]).to be(false)
      expect(join.reload.priority).to eq(42)
    end

    it "refuses an array" do
      expect { expect(update([ 1 ])[:success]).to be(false) }.not_to raise_error
      expect(join.reload.priority).to eq(42)
    end
  end

  describe "accepts what a caller legitimately sends" do
    it "takes an integer" do
      expect(update(9)[:success]).to be(true)
      expect(join.reload.priority).to eq(9)
    end

    # HTTP and JSON clients legitimately send "7"; refusing that would break
    # callers to fix a typo.
    it "takes an integer-looking string" do
      expect(update("7")[:success]).to be(true)
      expect(join.reload.priority).to eq(7)
    end

    # nil means "the caller did not name this field", NOT priority 0 — the
    # column default applies at INSERT only, so coercing nil would demote an
    # existing join on an unrelated edit.
    it "leaves priority untouched when it is not named at all" do
      result = tool.send(:update_template_module,
                         { template_id: template.id, module_id: node_module.id, enabled: false })

      expect(result[:success]).to be(true)
      expect(join.reload.priority).to eq(42)
    end
  end

  # The assign action shares template_module_attrs, so it shares the defect.
  describe "the assign action refuses the same input" do
    let(:other_module) do
      create(:system_node_module, account: account, node_platform: platform, category: category,
             variety: "subscription", name: "prio-mod2-#{SecureRandom.hex(3)}")
    end

    it "returns an error_result rather than raising on a non-scalar priority" do
      result = nil
      expect do
        result = tool.send(:assign_module_to_template,
                           { template_id: template.id, module_id: other_module.id,
                             priority: { "n" => 1 } })
      end.not_to raise_error

      expect(result[:success]).to be(false)
      expect(::System::TemplateModule.find_by(node_template: template, node_module: other_module)).to be_nil
    end
  end
end
