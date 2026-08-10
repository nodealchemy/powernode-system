# frozen_string_literal: true

require "rails_helper"

# Shared best-effort dev-cell deploy-key revocation (IMP-73eab188c4bd) —
# previously duplicated byte-for-byte in InstancePoolService (reuse-release
# path) and ProvisioningService (termination path). Vault-backed key cleanup:
# one revoke contract, one place to change it.
RSpec.describe System::DevCellDeployKeyRevocation do
  let(:host_class) do
    Class.new do
      include System::DevCellDeployKeyRevocation

      def self.name = "System::FakeLifecycleService"

      def call(instance)
        revoke_dev_cell_deploy_key!(instance)
      end
    end
  end
  let(:instance) { instance_double(System::NodeInstance, id: "ni-123") }

  it "revokes through the DevCellDeployKey model" do
    allow(System::DevCellDeployKey).to receive(:revoke_for!)

    host_class.new.call(instance)

    expect(System::DevCellDeployKey).to have_received(:revoke_for!).with(instance)
  end

  it "swallows a revoke failure and warns with the host's own log tag (never blocks the lifecycle step)" do
    allow(System::DevCellDeployKey).to receive(:revoke_for!).and_raise(StandardError, "vault sealed")
    expect(Rails.logger).to receive(:warn)
      .with(/\[FakeLifecycleService\] dev-cell deploy-key revoke failed \(instance=ni-123\).*vault sealed/)
      .at_least(:once)

    expect { host_class.new.call(instance) }.not_to raise_error
  end

  it "keeps the helper private on the host" do
    expect(host_class.new.respond_to?(:revoke_dev_cell_deploy_key!)).to be(false)
    expect(host_class.private_method_defined?(:revoke_dev_cell_deploy_key!)).to be(true)
  end
end
