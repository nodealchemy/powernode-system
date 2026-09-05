# frozen_string_literal: true

require "rails_helper"

# Campaign 01a07025 increment 3 — the scheduled, attributed, persisted
# platform-health duty. Before this service, System::Platform::
# CompositeHealthProbe and PlatformMaintenanceExecutor's health_check action
# both worked but had no caller on any schedule (no sensor binding, no cron)
# — the increment-3 investigation's cleanest finding: a capability that
# existed, was correct, and had never once run unattended.
#
# THE MIS-ATTRIBUTION THIS SPEC NOW GUARDS AGAINST (found by another lane
# cross-checking this increment's report against its own): an earlier version
# resolved the attributed agent via Ai::Agent.resolve_concierge_for, which
# answers "the account's `is_concierge`-flagged agent" — Powernode Assistant,
# a CORE agent this executor has no relationship to. The executor
# `binds_to "concierge"`, which SkillBindings::AGENT_ALIASES maps to the
# source_key "system-concierge" — a DIFFERENT agent. So every prior run
# credited the wrong one. `global_concierge` below is that decoy: present in
# every example so a resolver that drifts back toward it fails loudly, never
# absent-by-omission.
#
# The three properties this spec exists to pin, because a health check that
# runs but proves none of them is not the duty the operator asked for:
#   - PERSISTED: a System::PlatformHealthSnapshot row exists afterward.
#   - ATTRIBUTED: an Ai::AgentExecution row exists naming the agent that ran
#     it — and specifically the agent PlatformMaintenanceExecutor is actually
#     bound to, resolved through SkillBindings + source_key, never the
#     is_concierge decoy and never the global canonical itself ("a global
#     canonical never executes" — HIER-P1 / extensions/system/CLAUDE.md
#     convention 4).
#   - STABLE UNDER RENAME: the bound canonical's slug and display name are
#     deliberately NOT "system concierge"-shaped below, mirroring the live
#     rename this campaign is mid-way through — only source_key is asserted
#     to matter.
RSpec.describe System::Platform::ScheduledHealthCheckService do
  let(:seeding_account) { create(:account) }
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let!(:provider) { create(:ai_provider, account: account, is_active: true) }

  # THE DECOY. Flagged `is_concierge: true` — what
  # Ai::Agent.resolve_concierge_for answers — and present in every example on
  # purpose, including with its OWN account clone minted, so "no decoy clone
  # exists" can never be why a test passes.
  let!(:global_concierge) do
    create(:ai_agent, :global, owner_account: seeding_account, is_concierge: true, status: "active",
                              name: "Powernode Assistant", slug: "powernode-assistant",
                              source_key: "powernode-assistant", is_system: true)
  end

  # THE REAL OWNER. Named and slugged to NOT look like "System Concierge" —
  # the display name and slug are exactly what a rename moves — with only
  # source_key matching System::Ai::Skills::SkillBindings::AGENT_ALIASES's
  # "concierge" -> "system-concierge" mapping, read from the constant rather
  # than restated as a literal so this spec cannot drift from the registry.
  let(:bound_source_key) { System::Ai::Skills::SkillBindings::AGENT_ALIASES.fetch("concierge") }

  let!(:bound_canonical) do
    create(:ai_agent, :global, owner_account: seeding_account, status: "active",
                              name: "Infrastructure Generalist", slug: "infrastructure-generalist",
                              source_key: bound_source_key, is_system: true)
  end

  def stub_probes_ok
    System::Platform::CompositeHealthProbe::SUBSYSTEMS.each do |name|
      allow_any_instance_of(System::Platform::CompositeHealthProbe)
        .to receive(:"probe_#{name}").and_return({ status: "ok", stubbed: true })
    end
  end

  describe "#run_if_due!" do
    it "skips the account when no clone of the bound agent has been minted yet" do
      stub_probes_ok

      result = described_class.new(account: account).run_if_due!

      expect(result).to include(ran: false, reason: "no_bound_agent_clone")
      expect(System::PlatformHealthSnapshot.for_account(account)).to be_empty
      expect(Ai::AgentExecution.where(account: account)).to be_empty
    end

    context "with a clone of the bound agent, and ALSO a clone of the is_concierge decoy" do
      let!(:clone) do
        ::Ai::Agents::AccountPrincipalResolver.for(canonical_slug: bound_canonical.source_key,
                                                    account: account, user: user)
      end
      # The decoy gets its own clone too — proves the credited row is chosen
      # BY BINDING, not merely because the decoy has no clone to compete with.
      let!(:decoy_clone) do
        ::Ai::Agents::AccountPrincipalResolver.for(canonical_slug: global_concierge.source_key,
                                                    account: account, user: user)
      end

      it "persists a snapshot and attributes the Ai::AgentExecution to the BOUND clone, never the decoy or either canonical" do
        stub_probes_ok

        result = described_class.new(account: account).run_if_due!

        expect(result[:ran]).to be(true)
        expect(result[:agent_id]).to eq(clone.id)

        snapshot = System::PlatformHealthSnapshot.for_account(account).recent.first
        expect(snapshot).to be_present

        execution = Ai::AgentExecution.where(account: account).order(:created_at).last
        expect(execution).to be_present
        expect(execution.ai_agent_id).to eq(clone.id)
        expect(execution.ai_agent_id).not_to eq(decoy_clone.id)
        expect(execution.ai_agent_id).not_to eq(bound_canonical.id)
        expect(execution.ai_agent_id).not_to eq(global_concierge.id)
        expect(execution.execution_context["kind"]).to eq("scheduled_health_check")
        expect(execution.status).to eq("completed")
      end

      it "is not due again immediately after a run (default interval)" do
        stub_probes_ok
        described_class.new(account: account).run_if_due!

        result = described_class.new(account: account).run_if_due!

        expect(result).to include(ran: false, reason: "not_due")
      end

      it "honors a configured interval shorter than the default, read from SiteSetting rather than hardcoded" do
        stub_probes_ok
        described_class.new(account: account).run_if_due!
        SiteSetting.set(described_class::INTERVAL_SETTING, "1", setting_type: "integer")

        # 2 minutes past the last run is due against a configured 1-minute
        # interval but would still be skipped against the DEFAULT_INTERVAL_
        # MINUTES fallback (15) — proves the configured value is actually
        # read, not the hardcoded default silently winning.
        travel_to(2.minutes.from_now) do
          result = described_class.new(account: account).run_if_due!
          expect(result[:ran]).to be(true)
        end
      end

      it "does not raise and reports the failure when the executor itself fails" do
        allow_any_instance_of(System::Platform::CompositeHealthProbe).to receive(:call).and_raise("boom")

        # BaseSkillExecutor#execute's own top-level rescue converts the raise
        # into failure(e.message) — so this proves the SERVICE stays inert
        # around that, not that Ruby happens not to raise.
        result = nil
        expect { result = described_class.new(account: account).run_if_due! }.not_to raise_error
        expect(result[:ran]).to be(true)
        expect(result[:success]).to be(false)
      end
    end
  end
end
