# frozen_string_literal: true

require "rails_helper"

# The worker's door onto the scheduled platform-health duty (campaign
# 01a07025 increment 3), driven END TO END: the worker's mTLS principal →
# this endpoint → ScheduledHealthCheckService → CompositeHealthProbe →
# PlatformMaintenanceExecutor → a persisted snapshot and an Ai::AgentExecution
# credited to the account's clone of the bound canonical.
#
# WHY THIS SPEC EXISTS. The service had a spec; the endpoint and the Sidekiq
# job that posts to it (extensions/system/worker/app/jobs/
# system_platform_health_sweep_job.rb) had none, so the only thing that had
# ever exercised the route was production — the campaign's dominant defect
# class ("exists, passes review, never executed"). Nothing below is stubbed
# except the subsystem probes themselves, which reach the network.
RSpec.describe "Api::V1::System::WorkerApi::PlatformHealth", type: :request do
  let(:seeding_account) { create(:account) }
  let(:account) { create(:account) }
  # An account-scoped worker sweeps its own account only (the controller's
  # first arm); the fleet-wide arm is exercised separately below.
  let(:worker) { create(:worker, account: account) }
  let(:headers) { worker_mtls_headers(worker).merge("Content-Type" => "application/json") }
  let(:path) { "/api/v1/system/worker_api/platform/health_sweep" }

  let(:user) { create(:user, account: account) }
  let!(:provider) { create(:ai_provider, account: account, is_active: true) }
  # The canonical the service credits is whichever one SkillBindings has
  # PlatformHealthCheckExecutor registered against (since IMP-80a353489ba4,
  # platform-health-monitor, no longer the concierge). Resolved through the
  # same registry the service reads, so a future binds_to change moves the
  # fixture with it instead of leaving the sweep with no clone to run.
  let(:bound_source_key) do
    executor = System::Ai::Skills::PlatformHealthCheckExecutor
    System::Ai::Skills::SkillBindings.all.find { |r| r[:executor] == executor }.fetch(:agents).sole
  end
  let!(:bound_canonical) do
    create(:ai_agent, :global, owner_account: seeding_account, status: "active",
                              name: "Platform Health Monitor", slug: bound_source_key,
                              source_key: bound_source_key, is_system: true)
  end
  let!(:clone) do
    ::Ai::Agents::AccountPrincipalResolver.for(canonical_slug: bound_canonical.source_key,
                                                account: account, user: user)
  end

  # The controller scopes a non-account worker to accounts that have at least
  # one NodeInstance — an account that never enabled fleet features is never
  # ticked.
  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let!(:instance) do
    node = create(:system_node, account: account, node_template: template, name: "health-node")
    create(:system_node_instance, node: node)
  end

  before do
    System::Platform::CompositeHealthProbe::SUBSYSTEMS.each do |name|
      allow_any_instance_of(System::Platform::CompositeHealthProbe)
        .to receive(:"probe_#{name}").and_return({ status: "ok", stubbed: true })
    end
  end

  it "runs the due account through the real service and persists the attributed result" do
    expect {
      post path, headers: headers
    }.to change { System::PlatformHealthSnapshot.for_account(account).count }.by(1)
      .and change { Ai::AgentExecution.where(account: account).count }.by(1)

    expect(response).to have_http_status(:ok)
    data = JSON.parse(response.body)["data"]
    expect(data["account_count"]).to eq(1)

    row = data["results"].find { |r| r["account_id"] == account.id }
    expect(row).to include("ran" => true, "agent_id" => clone.id, "success" => true)

    execution = Ai::AgentExecution.where(account: account).last
    expect(execution.ai_agent_id).to eq(clone.id)
    expect(execution.execution_context["kind"]).to eq("scheduled_health_check")
  end

  it "reports the account as not due on an immediate second sweep, and writes nothing more" do
    post path, headers: headers

    expect {
      post path, headers: headers
    }.not_to change { System::PlatformHealthSnapshot.for_account(account).count }

    row = JSON.parse(response.body)["data"]["results"].find { |r| r["account_id"] == account.id }
    expect(row).to include("ran" => false, "reason" => "not_due")
  end

  # IMP-80a353489ba4: the sweep tick is the bound agent's first use, so an
  # account with no clone yet gets one minted here rather than being skipped
  # forever.
  it "mints the bound agent's clone on the first sweep of an account that has none" do
    clone.destroy!

    post path, headers: headers

    expect(response).to have_http_status(:ok)
    row = JSON.parse(response.body)["data"]["results"].find { |r| r["account_id"] == account.id }
    minted = ::Ai::Agents::AccountPrincipalResolver.existing(bound_canonical, account: account)
    expect(minted).to be_present
    expect(minted.id).not_to eq(bound_canonical.id)
    expect(row).to include("ran" => true, "agent_id" => minted.id)
  end

  # `no_bound_agent_clone` is now only the genuinely un-mintable case: no user
  # in the account to own a clone. The tick never runs as the canonical.
  it "skips an account that cannot mint a clone of the bound agent instead of failing the sweep" do
    clone.destroy!
    account.users.each(&:destroy!)

    expect {
      post path, headers: headers
    }.not_to change { Ai::AgentExecution.where(account: account).count }

    expect(response).to have_http_status(:ok)
    row = JSON.parse(response.body)["data"]["results"].find { |r| r["account_id"] == account.id }
    expect(row).to include("ran" => false, "reason" => "no_bound_agent_clone")
  end

  # The fleet-wide arm: the SYSTEM worker (Worker#account? is !is_system?)
  # ticks every account that has at least one NodeInstance, and nothing else
  # — not even the account row it is itself homed on.
  it "sweeps only accounts with instances when the worker is the system worker" do
    idle_account = create(:account)
    fleet_worker = create(:worker, account: idle_account, is_system: true)

    post path, headers: worker_mtls_headers(fleet_worker).merge("Content-Type" => "application/json")

    expect(response).to have_http_status(:ok)
    ids = JSON.parse(response.body)["data"]["results"].map { |r| r["account_id"] }
    expect(ids).to include(account.id)
    expect(ids).not_to include(idle_account.id)
  end

  it "refuses a caller without the worker principal" do
    post path, headers: { "Content-Type" => "application/json" }

    expect(response).to have_http_status(:unauthorized)
  end
end
