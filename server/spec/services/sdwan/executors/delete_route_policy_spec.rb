# frozen_string_literal: true

require "rails_helper"

# IMP-3a563becb7d7 — #summarize is the approval/notification body
# (Ai::DeferredOperationApprovalContent.title and .message both render
# preview[:summary]). It read "Delete route policy <uuid>" — a bare UUID.
# Sdwan::RoutePolicy validates a name, so the row an operator is asked to
# destroy can always be named while it still exists; the bare id is only the
# floor for a row that is already gone.
RSpec.describe Sdwan::Executors::DeleteRoutePolicy do
  describe ".preview" do
    it "names the policy an operator recognises, not a bare UUID" do
      policy = create(:sdwan_route_policy, name: "block-transit")

      preview = described_class.preview({ policy_id: policy.id })

      expect(preview[:summary]).to eq("Delete route policy 'block-transit'")
      expect(preview[:impact]).to include("BGP route filtering")
    end

    it "falls back to the bare id when the policy is gone" do
      preview = described_class.preview({ policy_id: "gone" })

      expect(preview[:summary]).to eq("Delete route policy gone")
    end
  end
end
