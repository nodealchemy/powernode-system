# frozen_string_literal: true

require "rails_helper"

# Campaign 019f5885 inc3 — CiRunnerLeaseService.lease!/release!/ensure_standing_capacity!.
# Mirrors instance_pool_service_spec.rb's seed_pool_member pattern (InstancePool
# has no factory in this suite) and config_ci_runner_registration_spec.rb's
# Devops::Git::ApiClient stubbing pattern.
RSpec.describe System::CiRunnerLeaseService do
  let(:account)         { create(:account) }
  let(:node_template)   { create(:system_node_template, account: account) }
  let(:provider_region) { create(:system_provider_region) }
  let(:instance_type)   { create(:system_provider_instance_type) }

  let(:pool) do
    System::InstancePool.create!(
      account: account,
      node_template: node_template,
      name: "ci-builders-amd64",
      target_size: 3,
      min_size: 1,
      max_size: 5,
      lifecycle_class: "ephemeral",
      status: "active",
      provider_region: provider_region,
      provider_instance_type: instance_type
    )
  end

  # Seed a fully-warm pool member, bypassing the standard provisioning flow.
  def seed_pool_member(state: "ready")
    node = create(:system_node, account: account, node_template: node_template)
    create(:system_node_instance,
           node: node,
           name: "member-#{SecureRandom.hex(3)}",
           variety: "cloud",
           status: state == "ready" ? "running" : "pending",
           provider_region: provider_region,
           provider_instance_type: instance_type,
           instance_pool_id: pool.id,
           pool_state: state,
           pool_warming_started_at: 1.minute.ago)
  end

  describe "#lease!" do
    context "when the runner has already self-registered (correlate finds it immediately)" do
      let!(:member) { seed_pool_member }

      it "acquires the pool member, creates the lease, and correlates it to registered" do
        expected_name = ::System::CiRunnerRegistrationResolver.runner_name(member)
        runner = create(:git_runner, account: account, name: expected_name, external_id: "ext-1")

        lease = described_class.lease!(account: account, pool_name: pool.name, correlate_timeout: 0)

        expect(lease).to be_persisted
        expect(lease).to be_registered
        expect(lease.node_instance_id).to eq(member.id)
        expect(lease.instance_pool_id).to eq(pool.id)
        expect(lease.runner_name).to eq(expected_name)
        expect(lease.git_runner_id).to eq(runner.id)
        expect(lease.runner_external_id).to eq("ext-1")
        expect(lease.purpose).to eq("generic")
        expect(lease.expires_at).to be_present

        expect(member.reload.pool_state).to eq("claimed")
      end

      it "defaults runner_scope to org (API_SCOPE_TO_RUNNER_SCOPE mapping)" do
        create(:git_runner, account: account,
                             name: ::System::CiRunnerRegistrationResolver.runner_name(member))

        lease = described_class.lease!(account: account, pool_name: pool.name, correlate_timeout: 0)
        expect(lease.runner_scope).to eq("org")
      end

      it "passes through purpose and workflow_run fields" do
        create(:git_runner, account: account,
                             name: ::System::CiRunnerRegistrationResolver.runner_name(member))

        lease = described_class.lease!(
          account: account, pool_name: pool.name, purpose: "module_build",
          workflow_run_id: 555, workflow_run_repo: "powernode/powernode-platform",
          correlate_timeout: 0
        )

        expect(lease.purpose).to eq("module_build")
        expect(lease.workflow_run_id).to eq(555)
        expect(lease.workflow_run_repo).to eq("powernode/powernode-platform")
      end
    end

    context "when no matching runner has surfaced yet" do
      let!(:member) { seed_pool_member }

      it "leaves the lease in :leased with a single correlate attempt (correlate_timeout: 0)" do
        lease = described_class.lease!(account: account, pool_name: pool.name, correlate_timeout: 0)

        expect(lease).to be_leased
        expect(lease.git_runner_id).to be_nil
      end
    end

    context "when the pool has no ready members" do
      it "raises PoolUnavailableError" do
        expect {
          described_class.lease!(account: account, pool_name: pool.name, correlate_timeout: 0)
        }.to raise_error(System::CiRunnerLeaseService::PoolUnavailableError)
      end
    end

    context "when lease bookkeeping fails after the instance was already claimed" do
      let!(:member) { seed_pool_member }

      it "returns the claimed instance to the pool and raises LeaseError" do
        allow(::System::CiRunnerLease).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(System::CiRunnerLease.new))
        allow(::System::ProvisioningService).to receive(:terminate_instance)

        expect {
          described_class.lease!(account: account, pool_name: pool.name, correlate_timeout: 0)
        }.to raise_error(System::CiRunnerLeaseService::LeaseError, /failed to create lease/)

        expect(member.reload.pool_state).to eq("draining") # InstancePoolService.release! recycle path
        expect(::System::ProvisioningService).to have_received(:terminate_instance).with(instance: member)
      end
    end
  end

  describe "#release!" do
    let!(:member) { seed_pool_member }
    let(:fake_gitea_client) { instance_double("Devops::Git::GiteaApiClient") }

    def leased_and_registered
      runner_name = ::System::CiRunnerRegistrationResolver.runner_name(member)
      gitea_provider = create(:git_provider, :gitea, account: account)
      gitea_credential = create(:git_provider_credential, :gitea, account: account, provider: gitea_provider)
      runner = create(:git_runner, :online, account: account, name: runner_name, credential: gitea_credential,
                                             runner_scope: "organization")
      lease = described_class.lease!(account: account, pool_name: pool.name, correlate_timeout: 0)
      [ lease, runner ]
    end

    before do
      allow(::Devops::Git::ApiClient).to receive(:for).and_return(fake_gitea_client)
      allow(fake_gitea_client).to receive(:supports_runners?).and_return(true)
      allow(fake_gitea_client).to receive(:delete_runner).and_return(success: true)
      allow(::System::ProvisioningService).to receive(:terminate_instance)
    end

    it "deregisters the runner, recycles the pooled instance, and completes the release" do
      lease, runner = leased_and_registered
      expect(lease).to be_registered

      result = described_class.release!(account: account, lease: lease)

      expect(result).to be_released
      expect(result.released_at).to be_present
      expect(fake_gitea_client).to have_received(:delete_runner)
      expect(::Devops::GitRunner.exists?(runner.id)).to be false
      expect(member.reload.pool_state).to eq("draining")
      expect(::System::ProvisioningService).to have_received(:terminate_instance).with(instance: member)
    end

    it "raises RunnerBusyError when the runner is busy and force is not set" do
      lease, runner = leased_and_registered
      runner.update!(status: "busy", busy: true)

      expect {
        described_class.release!(account: account, lease: lease)
      }.to raise_error(System::CiRunnerLeaseService::RunnerBusyError)

      expect(lease.reload).to be_registered
      expect(fake_gitea_client).not_to have_received(:delete_runner)
    end

    it "releases a busy runner when force: true" do
      lease, runner = leased_and_registered
      runner.update!(status: "busy", busy: true)

      result = described_class.release!(account: account, lease: lease, force: true)

      expect(result).to be_released
      expect(fake_gitea_client).to have_received(:delete_runner)
    end

    it "is idempotent on an already-finished lease" do
      lease, = leased_and_registered
      lease.begin_release!
      lease.complete_release!

      expect {
        described_class.release!(account: account, lease: lease)
      }.not_to raise_error
      expect(fake_gitea_client).not_to have_received(:delete_runner)
    end
  end

  describe "#ensure_standing_capacity!" do
    it "is report-only when no standing-capacity SiteSetting is configured" do
      report = described_class.ensure_standing_capacity!(account: account, pool_name: pool.name)

      expect(report[:pool]).to eq(pool.name)
      expect(report[:configured_standing_capacity]).to be_nil
      expect(report).not_to have_key(:adjusted_target_size)
      expect(pool.reload.target_size).to eq(3) # untouched
    end

    it "adjusts the pool target_size when the standing-capacity SiteSetting is present and differs" do
      allow(::SiteSetting).to receive(:get).and_call_original
      allow(::SiteSetting).to receive(:get).with("system.ci_builder.standing_capacity.amd64").and_return("4")

      report = described_class.ensure_standing_capacity!(account: account, pool_name: pool.name, arch: "amd64")

      expect(report[:configured_standing_capacity]).to eq(4)
      expect(report[:adjusted_target_size]).to eq(4)
      expect(pool.reload.target_size).to eq(4)
    end

    it "reports pool_found: false for an unknown pool name without raising" do
      report = described_class.ensure_standing_capacity!(account: account, pool_name: "does-not-exist")

      expect(report[:pool_found]).to eq(false)
      expect(report[:pool]).to be_nil
    end
  end
end
