# frozen_string_literal: true

require "rails_helper"

# IMP-967901b9d2e1 — DrainK3sNode unconditionally returned
# `drain_scheduled: true` with no backing implementation at all. Any caller
# relying on drain-before-upgrade sequencing saw a false success. No
# kubectl-driver integration exists yet, so the executor now raises instead
# of faking success.
RSpec.describe System::Executors::Runtime::DrainK3sNode do
  let(:account) { create(:account) }
  let(:deferred_operation) { double("Ai::DeferredOperation", account: account) }
  let(:cluster) { create(:devops_kubernetes_cluster, :active, account: account) }
  let(:node_instance) { create(:system_node_instance, account: account) }
  let!(:node) { create(:devops_kubernetes_node, :agent, :active, kubernetes_cluster: cluster, node_instance: node_instance) }

  describe ".execute" do
    it "resolves the node and raises NotYetImplementedError instead of faking a scheduled drain" do
      expect {
        described_class.execute({ node_id: node.id }, deferred_operation: deferred_operation)
      }.to raise_error(described_class::NotYetImplementedError, /not implemented for node #{node.id}/)
    end
  end
end
