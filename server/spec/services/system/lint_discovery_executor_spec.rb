# frozen_string_literal: true

require "rails_helper"

# D1b — the system extension's improvement-discovery executor (campaign
# 01a08c9b). The boundary faked here is fleet acquisition
# (CiRunnerLeaseService.lease!), which would otherwise need a warm pooled VM;
# the lease row it returns, the task, the gates and core's own dispatch all run
# for real. Every gate is pinned on both arms.
RSpec.describe System::LintDiscoveryExecutor do
  let(:account) { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }
  let(:node) { create(:system_node, account: account, node_template: node_template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }
  let(:token) { "gta_#{SecureRandom.hex(20)}" }
  let!(:repository) do
    create(:git_repository, account: account, name: "core").tap do |repo|
      repo.credential.update!(credentials: { "access_token" => token })
    end
  end

  def make_pool(owner = account, name: "lint-builders")
    template = owner == account ? node_template : create(:system_node_template, account: owner)
    System::InstancePool.create!(
      account: owner, node_template: template, environment: Ai::Environment.default_for(owner),
      name: name, target_size: 0, min_size: 0, max_size: 1, lifecycle_class: "ephemeral", status: "active"
    )
  end

  def configure_pool(name = "lint-builders")
    SiteSetting.set(described_class::POOL_SETTING, name, setting_type: "string")
  end

  # The lease a warm builder would give: a real row on a real instance.
  def lease_row
    System::CiRunnerLease.create!(account: account, node_instance: instance, status: "leased",
                                  purpose: described_class::PURPOSE, expires_at: 2.hours.from_now)
  end

  let(:leased) { [] }

  before do
    allow(System::CiRunnerLeaseService).to receive(:lease!) do |**kwargs|
      leased << kwargs
      lease_row
    end
  end

  def dispatch!(repos = [ repository ]) = described_class.dispatch!(account: account, repositories: repos)

  describe "the tenant's own pool (ruling b)" do
    it "runs nothing, and says why, when no pool is configured" do
      make_pool

      expect(dispatch!).to include(status: "skipped", reason: "no_ci_runner_pool_configured")
      expect(leased).to be_empty
    end

    it "runs nothing when only ANOTHER account has a pool of that name" do
      configure_pool
      make_pool(create(:account))

      expect(dispatch!).to include(status: "skipped", reason: "no_ci_runner_pool")
      expect(leased).to be_empty
    end

    it "leases from the account's own pool by id" do
      configure_pool
      pool = make_pool

      expect(dispatch!).to include(status: "dispatched")
      expect(leased).to contain_exactly(hash_including(account: account, pool_id: pool.id,
                                                       purpose: described_class::PURPOSE))
    end
  end

  describe "one lease per account (ruling c)" do
    before do
      configure_pool
      make_pool
    end

    it "does not lease a second runner while one is live" do
      first = dispatch!

      expect(dispatch!).to include(status: "skipped", reason: "discovery_already_running")
      expect(leased.size).to eq(1)
      expect(first).to include(status: "dispatched")
    end

    it "leases again once the earlier lease has ended" do
      dispatch!
      System::CiRunnerLease.where(account: account).update_all(status: "released")

      expect(dispatch!).to include(status: "dispatched")
      expect(leased.size).to eq(2)
    end
  end

  describe "the dispatch" do
    before do
      configure_pool
      make_pool
    end

    it "sends a ci.lint_discovery task to the leased instance, naming repositories and no credential" do
      result = dispatch!

      lease = System::CiRunnerLease.find(result[:run_ref])
      task = System::Task.find(lease.build_task_id)
      expect(task).to have_attributes(command: "ci.lint_discovery", operable: instance, status: "pending")
      expect(task.options).to eq("run_ref" => lease.id, "repository_ids" => [ repository.id ])
      expect(task.attributes.to_json).not_to include(token)
      expect(lease.metadata).to include("repository_ids" => [ repository.id ], "reported_repository_ids" => [])
      expect(lease.attributes.to_json).not_to include(token)
      expect(lease.expires_at).to be_within(5.seconds).of(Time.current + described_class.deadline_seconds)
      expect(result[:repositories]).to contain_exactly(id: repository.id, status: "dispatched")
    end

    it "skips a repository with no usable credential, and runs nothing when none has one" do
      repository.credential.update!(is_active: false)

      expect(dispatch!).to include(status: "skipped", reason: "no_analyzable_repository",
                                   repositories: [ { id: repository.id, status: "skipped",
                                                     reason: "no_repository_credential" } ])
      expect(leased).to be_empty
    end

    it "says so when the pool has no ready runner" do
      allow(System::CiRunnerLeaseService).to receive(:lease!)
        .and_raise(System::CiRunnerLeaseService::PoolUnavailableError, "no ready members")

      expect(dispatch!).to include(status: "skipped", reason: "no_ready_runner")
    end

    it "releases the lease it took when the task cannot be created, and reports the class only" do
      allow(System::Task).to receive(:create!).and_raise(ActiveRecord::RecordInvalid)
      released = []
      allow(System::CiRunnerLeaseService).to receive(:release!) { |**kwargs| released << kwargs }

      result = dispatch!

      expect(result).to include(status: "failed", reason: "ActiveRecord::RecordInvalid")
      expect(released).to contain_exactly(hash_including(account: account, force: true))
    end
  end

  # The wiring core reads: with the extension loaded, core's discovery tick
  # dispatches through THIS executor, not a stand-in.
  describe "registration as the core provider" do
    it "is what core finds under :lint_discovery_executor, and core dispatches through it" do
      configure_pool
      make_pool

      expect(Powernode::ExtensionRegistry.provider(:lint_discovery_executor)).to eq(described_class)

      summary = Ai::Improvement::DiscoveryRunService.new(account: account).run!
      expect(summary).to include(status: "dispatched")
      expect(System::CiRunnerLease.find(summary[:run_ref]).purpose).to eq("lint_discovery")
    end
  end
end
