# frozen_string_literal: true

require "rails_helper"

# IMP-594bfa5e1be5 — the refresh executor used to call
# `SystemPackageModuleRefreshJob.perform_async` directly. That constant is
# defined only in the worker app (extensions/system/worker/app/jobs/), which
# the Rails server never autoloads, so for the callers that reach this
# executor (the CVE Responder's inline dispatch, the orchestrator's
# #dispatch_refreshes) the call was a silent no-op and the CVE chain never
# materialized a candidate version. The server's route to Sidekiq is
# System::WorkerJobEnqueuer (the raw-Redis wire seam
# PackageRepositorySyncService already uses); these specs pin the refresh to
# it. The MCP door (Ai::Tools::SystemPackageRepositoryTool
# #refresh_package_module) carried the identical no-op until
# IMP-915d1dbdcdba routed it through this executor; its own delegation is
# pinned in system_package_repository_tool_spec.rb.
RSpec.describe System::Ai::Skills::PackageModuleRefreshExecutor do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:mod) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "openssl-base")
  end
  let(:repo) { create(:system_package_repository, account: account) }
  let!(:link) do
    create(:system_package_module_link, node_module: mod, package_repository: repo,
           package_name: "openssl", package_version: "3.1.3", architecture: "amd64")
  end

  let(:exec) { described_class.new(account: account) }
  let(:jid)  { SecureRandom.hex(12) }

  # Never let a spec LPUSH into the worker's real Redis (DB 1 on this host is
  # live): every example stubs the seam and asserts on the call.
  before { allow(::System::WorkerJobEnqueuer).to receive(:enqueue).and_return(jid) }

  describe "#execute" do
    it "routes the refresh through WorkerJobEnqueuer to the worker's system queue" do
      # Precondition, not an assertion about the fix: the worker-only job
      # class must NOT resolve here, or this spec would be green against the
      # old `perform_async if defined?` path for the wrong reason.
      expect(defined?(SystemPackageModuleRefreshJob)).to be_nil

      r = exec.execute(package_module_link_id: link.id, force: true)

      # Wire contract of SystemPackageModuleRefreshJob#execute:
      # args [package_module_link_id, force], queue "system".
      expect(::System::WorkerJobEnqueuer).to have_received(:enqueue).with(
        job_class: "SystemPackageModuleRefreshJob",
        args:      [ link.id, true ],
        queue:     "system"
      )
      expect(r[:success]).to be true
      expect(r.dig(:data, :enqueued)).to be true
      expect(r.dig(:data, :package_module_link_id)).to eq(link.id)
    end

    it "sends force=false on the wire when the caller omits it" do
      exec.execute(package_module_link_id: link.id)

      expect(::System::WorkerJobEnqueuer).to have_received(:enqueue).with(
        hash_including(job_class: "SystemPackageModuleRefreshJob", args: [ link.id, false ])
      )
    end

    it "fails, and reports no enqueue, when the enqueuer returns no jid" do
      # WorkerJobEnqueuer is fail-soft: an unreachable Redis logs and returns
      # nil instead of raising. Nothing was queued, so the executor must not
      # claim success — a caller reading only `success` would otherwise mark
      # remediation in flight on the strength of a dropped job.
      allow(::System::WorkerJobEnqueuer).to receive(:enqueue).and_return(nil)

      r = exec.execute(package_module_link_id: link.id)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/enqueue/i)
      # `enqueued` is read off :data by every caller (the orchestrator does
      # `result.dig(:data, :enqueued) == true`), and a failure envelope has
      # none — so the absence below IS the "nothing was queued" report.
      expect(r.dig(:data, :enqueued)).to be_nil

      # And the envelope must stay BARE. BaseSkillExecutor#failure's `**extra`
      # is SkillCompositionRunner's rollback payload, documented to carry only
      # ids of resources THIS run created; the pre-existing link is not one,
      # and a "present" failure-outputs hash displaces a retried step's real
      # last_outputs. Re-adding `package_module_link_id:` here fails this.
      expect(r.keys).to contain_exactly(:success, :error)
    end

    it "enqueues nothing for a link whose module belongs to another account" do
      other = create(:account)
      other_platform = create(:system_node_platform, account: other)
      other_category = create(:system_node_module_category, account: other)
      other_mod = create(:system_node_module, account: other, node_platform: other_platform,
                         category: other_category, variety: "subscription", name: "foreign")
      other_link = create(:system_package_module_link, node_module: other_mod,
                          package_repository: create(:system_package_repository, account: other))

      r = exec.execute(package_module_link_id: other_link.id)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/not found or not accessible/)
      expect(::System::WorkerJobEnqueuer).not_to have_received(:enqueue)
    end
  end
end
