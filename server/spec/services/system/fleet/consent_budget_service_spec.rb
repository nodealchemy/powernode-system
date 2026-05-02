# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse Block R — ConsentBudgetService.
RSpec.describe System::Fleet::ConsentBudgetService do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:mod) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "budget-mod")
  end

  describe ".check_and_consume!" do
    context "when module has no budget set" do
      it "always allows" do
        result = described_class.check_and_consume!(module_id: mod.id)
        expect(result.allowed).to be true
        expect(result.reason).to eq("no_budget_set")
      end
    end

    context "when module has budget=3" do
      before do
        mod.update!(consent_budget_per_day: 3,
                    consent_budget_used_count: 0,
                    consent_budget_window_start_at: Time.current)
      end

      it "allows + decrements on each call until exhausted" do
        r1 = described_class.check_and_consume!(module_id: mod.id)
        expect(r1.allowed).to be true
        expect(r1.remaining).to eq(2)

        r2 = described_class.check_and_consume!(module_id: mod.id)
        expect(r2.allowed).to be true
        expect(r2.remaining).to eq(1)

        r3 = described_class.check_and_consume!(module_id: mod.id)
        expect(r3.allowed).to be true
        expect(r3.remaining).to eq(0)

        r4 = described_class.check_and_consume!(module_id: mod.id)
        expect(r4.allowed).to be false
        expect(r4.reason).to match(/budget_exhausted/)
      end

      it "resets the window when older than 24 hours" do
        mod.update_columns(
          consent_budget_used_count: 3,
          consent_budget_window_start_at: 25.hours.ago
        )
        result = described_class.check_and_consume!(module_id: mod.id)
        expect(result.allowed).to be true
        expect(result.remaining).to eq(2)
        expect(mod.reload.consent_budget_used_count).to eq(1)
      end
    end

    context "when module_id is missing" do
      it "fails open with no_module_id reason" do
        result = described_class.check_and_consume!(module_id: nil)
        expect(result.allowed).to be true
        expect(result.reason).to eq("no_module_id")
      end
    end

    context "when module is not found" do
      it "fails open with module_not_found reason" do
        result = described_class.check_and_consume!(module_id: SecureRandom.uuid)
        expect(result.allowed).to be true
        expect(result.reason).to eq("module_not_found")
      end
    end
  end
end
