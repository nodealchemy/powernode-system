# frozen_string_literal: true

require "rails_helper"

# IMP-967901b9d2e1 — RotateDockerTls called ::DockerHost.find (NameError —
# the model is Devops::DockerHost) and guarded the rotation with
# `host.respond_to?(:rotate_tls!)`, which was always false since
# Devops::DockerHost has no such method. Both bugs combined to silently
# report `rotated: true` without ever touching TLS material. There is no
# real rotate backend yet (db/seeds/system_runtime_manager_agent.rb
# documents the alternate path), so the executor now raises instead of
# faking success.
RSpec.describe System::Executors::Runtime::RotateDockerTls do
  let(:account) { create(:account) }
  let(:deferred_operation) { double("Ai::DeferredOperation", account: account) }
  let!(:host) { create(:devops_docker_host, account: account) }

  describe ".execute" do
    it "resolves the host without NameError and raises NotYetImplementedError instead of faking success" do
      expect {
        described_class.execute({ host_id: host.id }, deferred_operation: deferred_operation)
      }.to raise_error(described_class::NotYetImplementedError, /not implemented for host #{host.id}/)
    end
  end
end
