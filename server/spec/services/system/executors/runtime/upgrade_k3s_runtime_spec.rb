# frozen_string_literal: true

require "rails_helper"

# IMP-967901b9d2e1 — UpgradeK3sRuntime read `cluster.try(:version)`, but
# Devops::KubernetesCluster has no `version` column (the persisted field is
# `k8s_version`), so current_version always read nil. It also never
# triggered any upgrade at all — a bare version-echo stub reported success
# with no orchestration behind it. Full rolling-upgrade orchestration
# doesn't exist yet, so the executor now raises instead of faking success.
RSpec.describe System::Executors::Runtime::UpgradeK3sRuntime do
  let(:account) { create(:account) }
  let(:deferred_operation) { double("Ai::DeferredOperation", account: account) }
  let!(:cluster) { create(:devops_kubernetes_cluster, :active, account: account, k8s_version: "v1.30.4+k3s1") }

  describe ".execute" do
    it "reads the real k8s_version column and raises NotYetImplementedError instead of faking an upgrade" do
      expect {
        described_class.execute(
          { cluster_id: cluster.id, target_version: "v1.31.0+k3s1" },
          deferred_operation: deferred_operation
        )
      }.to raise_error(
        described_class::NotYetImplementedError,
        /cluster #{cluster.id} \(current "v1\.30\.4\+k3s1" -> target "v1\.31\.0\+k3s1"\)/
      )
    end
  end
end
