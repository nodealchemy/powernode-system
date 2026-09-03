# frozen_string_literal: true

require "rails_helper"

# IMP-95198e6a57d3 — sync_now called result.success? on Reconciler::Result,
# whose struct defines only ok?, so the operator sync-now endpoint raised
# NoMethodError on EVERY invocation from 2026-05-10 onward. A chronically
# broken endpoint produces no bug reports — which is how the standby
# orphaned-run bug (IMP-0ad117c2feb8) hid on this exact path. First request
# coverage for the action; diff_summary is now surfaced so gate-skip markers
# reach the operator.
RSpec.describe "Operator API — GitOps sync_now", type: :request do
  let(:account) { create(:account) }
  let(:user)    { user_with_permissions("system.gitops.sync", account: account) }
  let(:headers) { auth_headers_for(user) }

  let(:repo) do
    System::GitopsRepository.create!(
      account: account, name: "fleet",
      repo_url: "https://example.com/fleet.git",
      branch: "main", path_prefix: "", enabled: true, auto_apply: false
    )
  end

  def stub_reconcile(result)
    # Class-level stub bypasses reconcile!'s finalize, so the nested sync_run
    # in the response stays at "running" — a test-isolation artifact (the real
    # reconcile! always finalizes); no example asserts on sync_run fields.
    allow(::System::Gitops::Reconciler).to receive(:reconcile!).and_return(result)
  end

  def result_with(ok:, diff_count: 0, diff_summary: nil, error: nil)
    ::System::Gitops::Reconciler::Result.new(
      ok?: ok, diff_count: diff_count, proposal_ids: [],
      applied_proposal_ids: [], failed_proposal_ids: [],
      diff_summary: diff_summary, error: error
    )
  end

  it "returns the reconcile outcome for a clean sync" do
    stub_reconcile(result_with(ok: true, diff_count: 2))

    post "/api/v1/system/gitops_repositories/#{repo.id}/sync_now", headers: headers

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body.dig("data", "ok")).to be(true)
    expect(body.dig("data", "diff_count")).to eq(2)
  end

  # SWEEP-2026-09-03 (carried out of IMP-8ce4d88499a0, which fixed the MCP
  # twin) — a reconcile that FAILED is a failure, and a failure must not ride
  # the success channel. This action used to render_success(ok: false, ...):
  # the reason sat in the payload while the one field a program branches on
  # said the sync succeeded. Sync PRECEDES apply, so a caller that read a
  # failed sync as success concluded the fleet matched the repository.
  it "reports a failed reconcile as a failure, with the run id and reason, without raising" do
    stub_reconcile(result_with(ok: false, error: "clone failed"))

    post "/api/v1/system/gitops_repositories/#{repo.id}/sync_now", headers: headers

    expect(response).to have_http_status(:unprocessable_content)
    body = response.parsed_body
    expect(body["success"]).to be(false)
    expect(body["error"]).to include("clone failed")
    expect(body.dig("details", "ok")).to be(false)
    expect(body.dig("details", "sync_run", "id")).to eq(repo.sync_runs.order(:created_at).last.id)
  end

  # Same task, same shape as the MCP verb: on a standby control plane the
  # reconciler's own fence performs nothing and returns ok?: true with a
  # `skipped` note — the exact shape of an in-sync repository — and this
  # action minted a GitopsSyncRun finalized as "success" for a reconcile that
  # never happened. Refuse BEFORE the run exists, on the same authority the
  # reconciler asks (ControlPlaneRole), rather than asking the operator to
  # sniff diff_summary for a marker.
  it "refuses on a standby control plane before minting a sync run" do
    allow(::System::Autonomy::ControlPlaneRole).to receive(:active?).and_return(false)
    expect(::System::Gitops::Reconciler).not_to receive(:reconcile!)

    expect {
      post "/api/v1/system/gitops_repositories/#{repo.id}/sync_now", headers: headers
    }.not_to change(::System::GitopsSyncRun, :count)

    expect(response).to have_http_status(:conflict)
    body = response.parsed_body
    expect(body["success"]).to be(false)
    expect(body["code"]).to eq("standby_control_plane")
    expect(body["error"]).to match(/standby control plane/)
  end
end
