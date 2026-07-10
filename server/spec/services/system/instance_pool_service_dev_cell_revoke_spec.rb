# frozen_string_literal: true

require "rails_helper"

# A1' security (F5): the reuse-without-reset release path must revoke the prior
# consumer's dev-cell deploy key + Vault secret so a read-write repo key can't
# survive into the next acquirer (the default recycle path already revokes via
# ProvisioningService#finalize_termination!). Isolated from the main pool spec
# so it doesn't touch the heartbeat/recycle logic under concurrent edit.
RSpec.describe System::InstancePoolService, "reuse-without-reset dev-cell revoke", type: :service do
  let(:account) { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }
  let(:provider_region) { create(:system_provider_region) }
  let(:provider_instance_type) { create(:system_provider_instance_type) }
  let(:node) { create(:system_node, account: account, node_template: node_template, lifecycle_class: "ephemeral") }

  let(:pool) do
    System::InstancePool.create!(
      account: account, node_template: node_template, name: "warm-devcell-pool",
      target_size: 1, min_size: 1, max_size: 3, lifecycle_class: "ephemeral",
      status: "active", provider_region: provider_region,
      provider_instance_type: provider_instance_type,
      metadata: { "reuse_without_reset" => true }
    )
  end

  let(:instance) do
    create(:system_node_instance, node: node, name: "member-#{SecureRandom.hex(3)}",
           variety: "cloud", status: "running", provider_region: provider_region,
           provider_instance_type: provider_instance_type, instance_pool_id: pool.id,
           pool_state: "claimed", pool_acquired_at: 1.minute.ago)
  end

  let(:gitea_provider) { create(:git_provider, :gitea, account: account) }
  let!(:gitea_credential) { create(:git_provider_credential, account: account, provider: gitea_provider) }
  let!(:deploy_key) do
    System::DevCellDeployKey.create!(
      node_instance: instance, source_repo: "powernode/powernode-platform",
      deploy_key_id: 7, title: "dev-cell-#{instance.id}"
    )
  end

  let(:fake_client) { instance_double("Devops::Git::GiteaApiClient") }
  before { allow(::Devops::Git::ApiClient).to receive(:for).and_return(fake_client) }

  it "revokes the deploy key and returns the member to ready (reused)" do
    expect(fake_client).to receive(:delete_deploy_key)
      .with("powernode", "powernode-platform", 7).and_return({ success: true })

    result = described_class.release!(instance: instance, pool: pool)

    expect(result).to eq("reused")
    expect(instance.reload.pool_state).to eq("ready")
    expect(System::DevCellDeployKey.exists?(deploy_key.id)).to be(false)
  end

  it "still reuses the member when the revoke raises (best-effort, non-blocking)" do
    allow(System::DevCellDeployKey).to receive(:revoke_for!).and_raise(StandardError, "boom")

    result = described_class.release!(instance: instance, pool: pool)

    expect(result).to eq("reused")
    expect(instance.reload.pool_state).to eq("ready")
  end
end
