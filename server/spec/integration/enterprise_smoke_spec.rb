# frozen_string_literal: true

require "rails_helper"
require "csv"

# AI-Driven Provisioning M4 Enterprise smoke.
#
# Mirrors the M0 happy-path smoke (`provisioning_m0_smoke_spec`) but
# exercises the four M4 enterprise-polish slices end-to-end against a
# Business+ tier:
#
#   Slice A — Account::TeamDelegation (per-team isolation)
#             • mission.delegation pointer
#             • delegation.effective_quota fallback to plan.limits
#             • delegation.ip_allowlist as the source of SG rules
#   Slice B — System::LifecycleAuditable + Billing::AuditExportService
#             • NodeInstance AASM transitions write to ::AuditLog
#             • Export joins audit + usage + mission rows into CSV/JSON
#   Slice C — Mission#requires_second_signature?
#             • plan.features["second_signature_required"] = true
#             • OrchestratorService.handle_approval! enforces 2 distinct
#               approvers at the `handoff` gate before advancing
#   Slice D — System::IpAllowlistService
#             • build_provider_params injects security_group_rules
#               sourced from delegation.ip_allowlist
#
# Stub seams (one canonical seam per concern):
#   - PlanComposerService is bypassed entirely; we manipulate
#     mission.configuration directly to keep the spec focused on the
#     M4 deliverables (the M0 smoke already covers compose).
#   - Provider adapter `create_instance` is stubbed at the registry
#     level to capture provider_params and assert security_group_rules.
#
# What this asserts:
#   1. Mission with delegation_id is created on a Business plan.
#   2. handle_approval!(gate: "review_plan", user: A) advances to execute.
#   3. handle_approval!(gate: "handoff", user: A) STAYS at handoff
#      (Slice C — first signature only).
#   4. handle_approval!(gate: "handoff", user: A) again STAYS (same
#      user — distinct approver count still 1).
#   5. handle_approval!(gate: "handoff", user: B) advances to adapting.
#   6. mission.approvals at handoff has 3 rows but exactly 2 distinct
#      approvers; both timestamps and user_ids are recorded.
#   7. AuditExportService.export(format: :csv) returns a CSV body that
#      contains rows attributed to BOTH user_a.email and user_b.email
#      (sourced from NodeInstance lifecycle transitions executed inside
#      `Audit::Context.with(user: …)` blocks).
#   8. ProvisioningService.provision_instance, when handed
#      `options[:delegation]`, surfaces `security_group_rules` to the
#      provider adapter with one rule per (CIDR × {22,80,443}).
RSpec.describe "AI-driven provisioning M4 enterprise smoke", type: :integration do
  include PermissionTestHelpers

  let(:account) { create(:account) }
  let(:user_a)  { user_with_permissions("ai.workflows.create", "ai.workflows.execute", account: account) }
  let(:user_b)  { user_with_permissions("ai.workflows.create", "ai.workflows.execute", account: account) }
  let(:agent)   { create(:ai_agent, account: account) }

  # ---------- Business plan with second-signature + ip_allowlist features ----
  let!(:business_plan) do
    create(:plan,
           slug: "business",
           name: "Business",
           features: {
             "second_signature_required" => true,
             "audit_export"              => true,
             "ip_allowlist"              => true
           },
           limits: {
             "max_active_instances"      => 50,
             "max_concurrent_provisions" => 5
           })
  end
  let!(:subscription) { create(:subscription, :active, account: account, plan: business_plan) }

  # ---------- Delegation with quota override + IP allowlist (Slices A + D) ---
  let(:delegation_cidr_a) { "203.0.113.0/24" }
  let(:delegation_cidr_b) { "198.51.100.0/24" }
  let(:delegation) do
    ::Account::TeamDelegation.create!(
      account: account,
      team_name: "Production",
      slug: "production",
      quota_overrides: { "max_active_instances" => 10 },
      ip_allowlist: [delegation_cidr_a, delegation_cidr_b]
    )
  end

  # ---------- System fixtures for ProvisioningService end-to-end -------------
  let(:provider) { create(:system_provider, account: account, provider_type: "mock") }
  let(:region)   { create(:system_provider_region, account: account, provider: provider) }
  let(:instance_type) { create(:system_provider_instance_type, account: account, provider: provider) }
  let!(:provider_connection) do
    create(:system_provider_connection, account: account, provider: provider, status: "connected")
  end
  let(:architecture) { create(:system_node_architecture, :with_checksums) }
  let(:platform)     { create(:system_node_platform, account: account, node_architecture: architecture) }
  let(:template)     { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)         { create(:system_node, account: account, node_template: template) }

  # Captured provider params from the stubbed adapter (Slice D assertion #8).
  let(:captured_params) { [] }

  before do
    # Force account materialization before seed loads (mirrors M0 smoke
    # idiom — the seed bails when Account.first is nil).
    account; agent; user_a; user_b
    load Rails.root.join("../extensions/system/server/db/seeds/system_provisioning_mission_template.rb")

    # ---- Stub provider adapter so provision_instance can run unstubbed ------
    fake_adapter = instance_double(System::Providers::MockProvider, provider_type: "mock")
    allow(System::Providers::Registry).to receive(:for_node).and_return(fake_adapter)
    allow(fake_adapter).to receive(:create_instance) do |params|
      captured_params << params
      {
        success: true,
        cloud_instance_id: "ci-#{SecureRandom.hex(4)}",
        private_ip_address: "10.0.0.#{rand(2..254)}",
        public_ip_address:  "203.0.113.#{rand(2..254)}",
        status: "running"
      }
    end
  end

  after { ::Audit::Context.reset! }

  it "drives a Business-tier mission through second-signature handoff and exports an audit CSV" do
    # ===========================================================================
    # 1. Mission with delegation_id
    # ===========================================================================
    mission = ::Ai::Mission.create!(
      account: account,
      created_by: user_a,
      delegation: delegation,
      name: "Enterprise smoke: 3-region web app",
      mission_type: "infrastructure",
      objective: "M4 second-signature smoke",
      status: "draft"
    )

    expect(mission.delegation).to eq(delegation)
    expect(mission.delegation.team_name).to eq("Production")
    expect(mission.delegation.ip_allowlist).to match_array([delegation_cidr_a, delegation_cidr_b])
    expect(mission.delegation.effective_quota("max_active_instances")).to eq(10) # team override
    expect(mission.delegation.effective_quota("max_concurrent_provisions")).to eq(5) # plan fallback

    # Predicate is false outside handoff — verify before transitioning.
    expect(mission.requires_second_signature?).to be false

    orchestrator = ::Ai::Missions::OrchestratorService.new(mission: mission)

    # ===========================================================================
    # 2. Walk to review_plan and approve with user A → execute
    # ===========================================================================
    orchestrator.start!
    expect(mission.reload.current_phase).to eq("capture_intent")

    mission.update!(configuration: mission.configuration.merge("brief" => { "intent" => "smoke" }))
    orchestrator.advance!(result: { brief_captured: true })
    expect(mission.reload.current_phase).to eq("compose_plan")

    orchestrator.advance!(result: { plan_id: SecureRandom.uuid })
    expect(mission.reload.current_phase).to eq("review_plan")
    expect(mission.awaiting_approval?).to be true

    orchestrator.handle_approval!(gate: "review_plan", user: user_a, decision: "approved")
    expect(mission.reload.current_phase).to eq("execute")

    # ===========================================================================
    # 3. Advance through execute → verify → handoff
    # ===========================================================================
    orchestrator.advance!(result: { provisioned_count: 0 })
    expect(mission.reload.current_phase).to eq("verify")

    orchestrator.advance!(result: { slo_targets_met: true })
    expect(mission.reload.current_phase).to eq("handoff")
    expect(mission.awaiting_approval?).to be true

    # Predicate flips on once we're at handoff on a Business plan.
    expect(mission.requires_second_signature?).to be true

    # ===========================================================================
    # 4. User A approves → STAYS at handoff (Slice C: second sig required)
    # ===========================================================================
    orchestrator.handle_approval!(gate: "handoff", user: user_a, decision: "approved")
    expect(mission.reload.current_phase).to eq("handoff"),
      "expected mission to remain at handoff after first approval; was #{mission.current_phase}"
    expect(mission.distinct_approver_count("handoff")).to eq(1)

    # ===========================================================================
    # 5. User A approves AGAIN → still at handoff (same user doesn't count twice)
    # ===========================================================================
    orchestrator.handle_approval!(gate: "handoff", user: user_a, decision: "approved")
    expect(mission.reload.current_phase).to eq("handoff")
    expect(mission.distinct_approver_count("handoff")).to eq(1)
    expect(mission.approvals.where(gate: "handoff").count).to eq(2) # both rows recorded

    # ===========================================================================
    # 6. User B approves → advances to adapting
    # ===========================================================================
    orchestrator.handle_approval!(gate: "handoff", user: user_b, decision: "approved")
    expect(mission.reload.current_phase).to eq("adapting")
    expect(mission.distinct_approver_count("handoff")).to eq(2)

    # ===========================================================================
    # 7. Both approvers + timestamps in mission.approvals
    # ===========================================================================
    handoff_approvals = mission.approvals.where(gate: "handoff").approved
    expect(handoff_approvals.count).to eq(3)
    distinct_user_ids = handoff_approvals.distinct.pluck(:user_id).compact
    expect(distinct_user_ids).to match_array([user_a.id, user_b.id])
    handoff_approvals.each do |ap|
      expect(ap.created_at).to be_present
    end

    # ===========================================================================
    # 8. Provision an instance with delegation → security_group_rules carry
    #    the delegation's allowlist CIDRs
    # ===========================================================================
    result = ::System::ProvisioningService.provision_instance(
      node: node,
      provider_region_id: region.id,
      provider_instance_type_id: instance_type.id,
      options: { delegation: delegation }
    )
    expect(result.success?).to be true
    expect(captured_params.size).to eq(1)
    rules = captured_params.first[:security_group_rules]
    expect(rules).to be_an(Array)
    expect(rules).not_to be_empty

    # Both CIDRs × 3 ports (22/80/443) = 6 rules.
    expect(rules.size).to eq(6)
    expect(rules.map { |r| r[:source] }.uniq).to match_array([delegation_cidr_a, delegation_cidr_b])
    expect(rules.map { |r| r[:port] }.uniq.sort).to eq([22, 80, 443])
    rules.each do |rule|
      expect(rule[:protocol]).to eq("tcp")
      expect(rule[:description]).to be_present
    end

    # ===========================================================================
    # 9. Drive NodeInstance lifecycle transitions in user A and user B contexts
    #    so AuditLog rows accrue with both actors. AuditExportService.export
    #    then surfaces them in the CSV body.
    # ===========================================================================
    instance = ::System::NodeInstance.where(node: node).first!
    expect(instance.status).to eq("running") # set by stubbed adapter result above

    ::Audit::Context.with(user: user_a, ip_address: "203.0.113.1", source: "api",
                          mission_id: mission.id) do
      instance.stop!         # running  → stopping
      instance.mark_stopped! # stopping → stopped
    end

    ::Audit::Context.with(user: user_b, ip_address: "198.51.100.1", source: "api",
                          mission_id: mission.id) do
      instance.start!        # stopped  → starting
      instance.mark_running! # starting → running
    end

    # AuditLog should now hold rows attributed to both users + the
    # mission_id for correlation. The two `mark_*` rows pre-date the
    # `with` blocks (they happen inside ProvisioningService /
    # ProvisioningMeterService callbacks); we only assert the four we
    # wrote explicitly above.
    audit_rows = ::AuditLog
                   .where(account_id: account.id)
                   .where(resource_type: "System::NodeInstance")
                   .where(action: ::AuditActions::SYSTEM_NODE_INSTANCE_ACTIONS)
                   .order(created_at: :asc)
                   .to_a

    user_a_rows = audit_rows.select { |l| l.user_id == user_a.id }
    user_b_rows = audit_rows.select { |l| l.user_id == user_b.id }
    expect(user_a_rows).not_to be_empty, "expected at least one AuditLog row attributed to user A"
    expect(user_b_rows).not_to be_empty, "expected at least one AuditLog row attributed to user B"

    # ===========================================================================
    # 10. AuditExportService → CSV with both approvers' rows
    # ===========================================================================
    export_result = ::Billing::AuditExportService.export(
      account: account,
      start_at: 1.hour.ago,
      end_at:   1.hour.from_now,
      format:   :csv,
      destination: :download
    )

    expect(export_result[:content_type]).to eq("text/csv")
    expect(export_result[:filename]).to match(/\Abilling-audit-export-#{account.id}-/)
    expect(export_result[:row_count]).to be >= user_a_rows.size + user_b_rows.size

    csv_rows = CSV.parse(export_result[:body], headers: true)
    expect(csv_rows.headers).to include("timestamp", "actor", "instance_id", "event",
                                         "before_state", "after_state", "mission_id")

    actors = csv_rows.map { |r| r["actor"] }.uniq
    expect(actors).to include(user_a.email)
    expect(actors).to include(user_b.email)

    events = csv_rows.map { |r| r["event"] }.uniq
    expect(events).to include("system.node_instance.stop")
    expect(events).to include("system.node_instance.start")

    # Mission correlation rides through the audit metadata.
    mission_ids = csv_rows.map { |r| r["mission_id"] }.compact.uniq
    expect(mission_ids).to include(mission.id)
  end
end
