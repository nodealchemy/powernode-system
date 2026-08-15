# frozen_string_literal: true

require "rails_helper"

# IMP-3a563becb7d7 — #summarize is the approval/notification body
# (Ai::DeferredOperationApprovalContent.title and .message both render
# preview[:summary]). It read "Delete route policy <uuid>" — a bare UUID.
# Sdwan::RoutePolicy validates a name, so the row an operator is asked to
# destroy can always be named while it still exists; the bare id is only the
# floor for a row that is already gone.
#
# IMP-4a5094b22df0 threads the operation through `preview`, and the label is
# resolved through it — so these previews now pass one. Without it there is no
# account to anchor on and the card correctly declines to name the row at all
# (asserted separately, in preview_account_anchor_spec.rb).
RSpec.describe Sdwan::Executors::DeleteRoutePolicy do
  let(:account) { create(:account) }

  def operation_for(params)
    ::Ai::DeferredOperation.create!(
      account: account,
      action_category: "sdwan.route_policy_delete",
      executor_class: described_class.name,
      params: params
    )
  end

  describe ".preview" do
    it "names the policy an operator recognises, not a bare UUID" do
      policy = create(:sdwan_route_policy, account: account, name: "block-transit")
      params = { policy_id: policy.id }

      preview = described_class.preview(params, deferred_operation: operation_for(params))

      expect(preview[:summary]).to eq("Delete route policy 'block-transit'")
      expect(preview[:impact]).to include("BGP route filtering")
    end

    it "falls back to the bare id when the policy is gone" do
      params = { policy_id: "gone" }

      preview = described_class.preview(params, deferred_operation: operation_for(params))

      expect(preview[:summary]).to eq("Delete route policy gone")
    end
  end
end
