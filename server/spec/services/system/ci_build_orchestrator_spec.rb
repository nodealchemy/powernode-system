# frozen_string_literal: true

require "rails_helper"

# Campaign 019f5885 inc4 — CiBuildOrchestrator.dispatch!. Thin seam tying the
# inc3 lease primitive (CiRunnerLeaseService) to a module build: lease an
# ephemeral fleet runner -> dispatch the build pinned to that runner's label
# -> best-effort correlate the Gitea workflow run the dispatch created ->
# attach the run id to the lease so the inc3 sweep
# (CiRunnerLeaseSweepService) releases + recycles on completion.
RSpec.describe System::CiBuildOrchestrator do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:node_module) do
    create(:system_node_module,
           account: account, node_platform: platform, category: category,
           variety: "subscription", name: "fleet-build-mod",
           gitea_repo_full_name: "powernode/fleet-build-mod")
  end

  let(:node_instance) { create(:system_node_instance, :running, account: account) }
  let(:runner_label)  { "fleet-amd64:docker://ghcr.io/catthehacker/ubuntu:act-24.04" }

  def build_lease(labels: [ runner_label ])
    System::CiRunnerLease.create!(
      account: account, node_instance: node_instance, status: "registered",
      purpose: "module_build", runner_labels: labels
    )
  end

  def stub_gitea_credential
    gitea_provider = create(:git_provider, :gitea, account: account)
    create(:git_provider_credential, :gitea, account: account, provider: gitea_provider)
  end

  def ok_dispatch_result(dispatch_id: "local-abc")
    System::ModuleBuildDispatchService::Result.new(ok?: true, dispatch_id: dispatch_id)
  end

  def failed_dispatch_result(error: "dispatch failed: boom")
    System::ModuleBuildDispatchService::Result.new(ok?: false, error: error)
  end

  describe ".dispatch!" do
    context "when the lease, dispatch, and run correlation all succeed" do
      it "threads the leased runner_label into the dispatch, attaches the correlated run to the lease, and returns an ok Result" do
        lease = build_lease
        allow(System::CiRunnerLeaseService).to receive(:lease!).and_return(lease)
        allow(System::ModuleBuildDispatchService).to receive(:dispatch_build!).and_return(ok_dispatch_result)

        stub_gitea_credential
        fake_client = instance_double("Devops::Git::GiteaApiClient")
        allow(::Devops::Git::ApiClient).to receive(:for).and_return(fake_client)
        allow(fake_client).to receive(:list_workflow_runs).and_return([
          { "id" => 999, "event" => "workflow_dispatch", "head_branch" => "main",
            "created_at" => Time.current.iso8601 }
        ])

        result = described_class.dispatch!(account: account, node_module: node_module, ref: "main")

        expect(System::ModuleBuildDispatchService).to have_received(:dispatch_build!)
          .with(node_module: node_module, ref: "main", runner_label: runner_label)

        expect(result.ok?).to be true
        expect(result.correlated).to be true
        expect(result.run_id).to eq(999)
        expect(result.dispatch_id).to eq("local-abc")
        expect(result.lease.reload.workflow_run_id).to eq(999)
        expect(result.lease.workflow_run_repo).to eq("powernode/fleet-build-mod")
      end

      it "ignores runs that don't match the event/ref/timestamp triad and picks the newest matching run" do
        lease = build_lease
        allow(System::CiRunnerLeaseService).to receive(:lease!).and_return(lease)
        allow(System::ModuleBuildDispatchService).to receive(:dispatch_build!).and_return(ok_dispatch_result)

        stub_gitea_credential
        fake_client = instance_double("Devops::Git::GiteaApiClient")
        allow(::Devops::Git::ApiClient).to receive(:for).and_return(fake_client)
        allow(fake_client).to receive(:list_workflow_runs).and_return([
          { "id" => 111, "event" => "push", "head_branch" => "main",
            "created_at" => Time.current.iso8601 }, # wrong event
          { "id" => 222, "event" => "workflow_dispatch", "head_branch" => "develop",
            "created_at" => Time.current.iso8601 }, # wrong branch
          { "id" => 333, "event" => "workflow_dispatch", "head_branch" => "main",
            "created_at" => 1.hour.ago.iso8601 }, # too old (before dispatch)
          { "id" => 444, "event" => "workflow_dispatch", "head_branch" => "main",
            "created_at" => Time.current.iso8601 } # the real match
        ])

        result = described_class.dispatch!(account: account, node_module: node_module, ref: "main")

        expect(result.run_id).to eq(444)
        expect(result.lease.reload.workflow_run_id).to eq(444)
      end
    end

    context "when the dispatch fails" do
      it "releases the stranded lease (force: true) and returns a failed, uncorrelated Result" do
        lease = build_lease
        allow(System::CiRunnerLeaseService).to receive(:lease!).and_return(lease)
        allow(System::CiRunnerLeaseService).to receive(:release!)
        allow(System::ModuleBuildDispatchService).to receive(:dispatch_build!).and_return(failed_dispatch_result)

        result = described_class.dispatch!(account: account, node_module: node_module)

        expect(result.ok?).to be false
        expect(result.error).to eq("dispatch failed: boom")
        expect(result.lease).to eq(lease)
        expect(System::CiRunnerLeaseService).to have_received(:release!)
          .with(account: account, lease: lease, force: true)
        expect(lease.reload.workflow_run_id).to be_nil
      end
    end

    context "when no matching Gitea run is found within the correlation window" do
      it "returns ok with correlated: false and leaves workflow_run_id nil (sweep/TTL remain the backstop)" do
        lease = build_lease
        allow(System::CiRunnerLeaseService).to receive(:lease!).and_return(lease)
        allow(System::ModuleBuildDispatchService).to receive(:dispatch_build!).and_return(ok_dispatch_result)

        stub_gitea_credential
        fake_client = instance_double("Devops::Git::GiteaApiClient")
        allow(::Devops::Git::ApiClient).to receive(:for).and_return(fake_client)
        allow(fake_client).to receive(:list_workflow_runs).and_return([])

        # Bounded retry, timed out immediately (single attempt, no sleep) —
        # mirrors CiRunnerLeaseService specs passing correlate_timeout: 0.
        allow(::SiteSetting).to receive(:get).and_call_original
        allow(::SiteSetting).to receive(:get).with("system.ci_builder.run_correlate_timeout_seconds").and_return("0")

        result = described_class.dispatch!(account: account, node_module: node_module)

        expect(result.ok?).to be true
        expect(result.correlated).to be false
        expect(result.run_id).to be_nil
        expect(result.lease.reload.workflow_run_id).to be_nil
      end

      it "returns ok with correlated: false when no Gitea credential is configured (best-effort, never raises)" do
        lease = build_lease
        allow(System::CiRunnerLeaseService).to receive(:lease!).and_return(lease)
        allow(System::ModuleBuildDispatchService).to receive(:dispatch_build!).and_return(ok_dispatch_result)
        # No git_provider_credential created for this account — resolver.credential is nil.

        result = described_class.dispatch!(account: account, node_module: node_module)

        expect(result.ok?).to be true
        expect(result.correlated).to be false
        expect(result.lease.reload.workflow_run_id).to be_nil
      end
    end
  end
end
