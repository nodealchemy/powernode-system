# frozen_string_literal: true

require "rails_helper"

# Campaign 01a07025 increment 3 — the scheduled, attributed, persisted
# platform-health duty. Before this service, System::Platform::
# CompositeHealthProbe and PlatformMaintenanceExecutor's health_check action
# both worked but had no caller on any schedule (no sensor binding, no cron)
# — the increment-3 investigation's cleanest finding: a capability that
# existed, was correct, and had never once run unattended.
#
# The two properties this spec exists to pin, because a health check that
# runs but proves neither is not the duty the operator asked for:
#   - PERSISTED: a System::PlatformHealthSnapshot row exists afterward.
#   - ATTRIBUTED: an Ai::AgentExecution row exists naming the agent that ran
#     it — and specifically the account's OWN Concierge CLONE, never the
#     global canonical ("a global canonical never executes" — HIER-P1 /
#     extensions/system/CLAUDE.md convention 4).
RSpec.describe System::Platform::ScheduledHealthCheckService do
  let(:seeding_account) { create(:account) }
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let!(:provider) { create(:ai_provider, account: account, is_active: true) }

  let!(:global_concierge) do
    create(:ai_agent, :global, owner_account: seeding_account, is_concierge: true, status: "active",
                              name: "Powernode Assistant", slug: "powernode-assistant",
                              source_key: "powernode-assistant", is_system: true)
  end

  def stub_probes_ok
    System::Platform::CompositeHealthProbe::SUBSYSTEMS.each do |name|
      allow_any_instance_of(System::Platform::CompositeHealthProbe)
        .to receive(:"probe_#{name}").and_return({ status: "ok", stubbed: true })
    end
  end

  describe "#run_if_due!" do
    it "skips the account when no Concierge clone has been minted yet" do
      stub_probes_ok

      result = described_class.new(account: account).run_if_due!

      expect(result).to include(ran: false, reason: "no_concierge_clone")
      expect(System::PlatformHealthSnapshot.for_account(account)).to be_empty
      expect(Ai::AgentExecution.where(account: account)).to be_empty
    end

    context "with an account Concierge clone" do
      let!(:clone) { Ai::Agents::AccountPrincipalResolver.concierge_for(account, user: user) }

      it "persists a snapshot and attributes an Ai::AgentExecution to the clone, never the canonical" do
        stub_probes_ok

        result = described_class.new(account: account).run_if_due!

        expect(result[:ran]).to be(true)
        expect(result[:agent_id]).to eq(clone.id)

        snapshot = System::PlatformHealthSnapshot.for_account(account).recent.first
        expect(snapshot).to be_present

        execution = Ai::AgentExecution.where(account: account).order(:created_at).last
        expect(execution).to be_present
        expect(execution.ai_agent_id).to eq(clone.id)
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
