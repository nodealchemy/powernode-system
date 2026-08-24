# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M7.A — FleetAutonomyService.
RSpec.describe System::Fleet::FleetAutonomyService do
  # gate_action! examples in this file create an Ai::ApprovalChain in
  # their setup blocks — chain model lives in business extension. In core
  # mode the require_approval gate path skips chain creation entirely via
  # AutonomyGate#require_approval_or_proceed, but the spec specifically
  # asserts chain-creation. Skip cleanly when business isn't loaded.
  before do
    skip "FleetAutonomyService spec requires Ai::ApprovalChain (business extension)" unless defined?(::Ai::ApprovalChain)
  end

  let(:account)  { create(:account) }
  let(:agent)    { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy") }
  let(:service)  { described_class.new(account: account, agent: agent) }

  describe "#permitted_actions" do
    it "returns the list of action_categories from active InterventionPolicy rows for this agent" do
      Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                     action_category: "system.cert_rotate",
                                     policy: "auto_approve", is_active: true)
      Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                     action_category: "system.instance_reprovision",
                                     policy: "require_approval", is_active: true)
      expect(service.permitted_actions).to contain_exactly(
        "system.cert_rotate",
        "system.instance_reprovision"
      )
    end
  end

  describe ".all_fleet_actions" do
    it "returns only system.* actions across the account" do
      Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                     action_category: "system.cert_rotate",
                                     policy: "auto_approve", is_active: true)
      Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                     action_category: "trading.create_session",
                                     policy: "require_approval", is_active: true)
      expect(described_class.all_fleet_actions(account)).to eq([ "system.cert_rotate" ])
    end
  end

  describe "#gate_action!" do
    # IMP-5a450411d873 split this arm in two. "No policy row" means different
    # things depending on whether the platform ROUTES signals to the category:
    # for a routed lane it is a deploy defect (the code declares a lane the
    # database has no policy for, so every signal is silently blocked); for
    # anything else it is an ordinary refusal.
    context "with an action not in the agent's policies" do
      it "blocks an UNROUTED action with reason :not_permitted" do
        result = service.gate_action!("system.definitely_not_a_routed_category")

        expect(result[:decision]).to eq(:blocked)
        expect(result[:reason]).to eq("not_permitted")
        expect(result[:gate]).to be_nil
      end

      # system.cert_rotate IS routed by DecisionEngine, so an absent row here is
      # a misconfiguration, not a policy decision — it still blocks (fail-safe),
      # but it now says so distinguishably instead of looking like a refusal.
      it "blocks a ROUTED action as a misconfiguration" do
        allow(Rails.logger).to receive(:error)

        result = service.gate_action!("system.cert_rotate")

        expect(result[:decision]).to eq(:blocked)
        expect(result[:gate]).to eq(described_class::GATE_POLICY_MISSING)
        expect(Rails.logger).to have_received(:error).with(/MISCONFIGURED LANE/)
      end
    end

    context "with auto_approve policy" do
      before do
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: "system.cert_rotate",
                                       policy: "auto_approve", is_active: true)
      end

      it "returns proceed without creating an ApprovalRequest" do
        expect {
          result = service.gate_action!("system.cert_rotate")
          expect(result[:decision]).to eq(:proceed)
          expect(result[:gate]).to eq("auto_approve")
        }.not_to change(Ai::ApprovalRequest, :count)
      end
    end

    context "with notify_and_proceed policy" do
      before do
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: "system.module_assign",
                                       policy: "notify_and_proceed", is_active: true)
      end

      it "returns proceed and logs the action" do
        result = service.gate_action!("system.module_assign", reasoning: { summary: "drift" })
        expect(result[:decision]).to eq(:proceed)
        expect(result[:gate]).to eq("notify_and_proceed")
      end
    end

    context "with require_approval policy" do
      let!(:chain) do
        create(:ai_approval_chain, account: account,
               trigger_type: "autonomy_action", name: "Fleet Autonomy Actions")
      end

      before do
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: "system.instance_reprovision",
                                       policy: "require_approval", is_active: true)
      end

      it "creates a pending ApprovalRequest with source_type=system_fleet" do
        expect {
          result = service.gate_action!("system.instance_reprovision",
                                        metadata: { instance_id: "inst-1" },
                                        reasoning: { summary: "instance silent" })
          expect(result[:decision]).to eq(:pending)
          expect(result[:gate]).to eq("require_approval")
          expect(result[:decision_record]).to be_present
        }.to change(Ai::ApprovalRequest, :count).by(1)

        req = Ai::ApprovalRequest.last
        expect(req.source_type).to eq("system_fleet")
        expect(req.request_data["action_category"]).to eq("system.instance_reprovision")
        expect(req.request_data["payload"]).to eq("instance_id" => "inst-1")
      end

      it "dedups concurrent requests for the same instance + action" do
        service.gate_action!("system.instance_reprovision",
                             metadata: { instance_id: "inst-1" },
                             reasoning: { summary: "first" })
        expect {
          service.gate_action!("system.instance_reprovision",
                               metadata: { instance_id: "inst-1" },
                               reasoning: { summary: "second" })
        }.not_to change(Ai::ApprovalRequest, :count)

        # The dedup branch updates the existing request rather than creating new
        req = Ai::ApprovalRequest.last
        expect(req.description).to eq("second")
      end
    end
  end

  describe "ADVANCEMENT_ACTIONS" do
    it "covers fleet-advancement classes (4h TTL bucket)" do
      expect(described_class::ADVANCEMENT_ACTIONS).to include(
        "system.module_promote_to_live",
        "system.fleet_rolling_upgrade",
        "system.region_expansion"
      )
    end
  end

  # Audit finding F3-02: expired-but-still-pending fleet requests accumulated
  # forever (check_expiration! had no callers) and escaped the dedup match
  # (which filtered expires_at > now), so each persisting signal re-minted a
  # duplicate request every TTL window.
  describe "expired pending approval handling" do
    let!(:chain) do
      # Factory defaults: timeout_hours 24, timeout_action "reject".
      create(:ai_approval_chain, account: account,
             trigger_type: "autonomy_action", name: "Fleet Autonomy Actions")
    end

    before do
      Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                     action_category: "system.instance_reprovision",
                                     policy: "require_approval", is_active: true)
    end

    def mint_expired_pending_request
      service.gate_action!("system.instance_reprovision",
                           metadata: { instance_id: "inst-1" },
                           reasoning: { summary: "instance silent" })
      Ai::ApprovalRequest.last.tap { |r| r.update_columns(expires_at: 2.hours.ago) }
    end

    describe "#tick! expiry sweep" do
      it "fires the chain's timeout_action on expired pending fleet requests" do
        request = mint_expired_pending_request

        service.tick!

        expect(request.reload.status).to eq("rejected")
      end

      it "does not re-mint a request for the same signal after the sweep rejects it" do
        mint_expired_pending_request
        service.tick!

        expect {
          service.gate_action!("system.instance_reprovision",
                               metadata: { instance_id: "inst-1" },
                               reasoning: { summary: "still silent" })
        }.not_to change(Ai::ApprovalRequest, :count)
      end
    end

    describe "dedup against expired pending requests" do
      it "matches an expired-but-pending request instead of minting a duplicate" do
        mint_expired_pending_request

        expect {
          service.gate_action!("system.instance_reprovision",
                               metadata: { instance_id: "inst-1" },
                               reasoning: { summary: "still silent" })
        }.not_to change(Ai::ApprovalRequest, :count)

        expect(Ai::ApprovalRequest.last.description).to eq("still silent")
      end
    end
  end

  # IMP-4019664a524b — advisory approval durability. The pending/rejected dedup
  # above is built for a condition that RESOLVES: a request is matched only
  # while pending, and a rejection suppresses re-mint only for a cooldown
  # window. An advisory condition (a capability gap) does neither — it stands
  # until a human ships a module — so an APPROVED advisory matched nothing and
  # the next sense pass past the 600s decide-cache minted a fresh request,
  # forever. Scoped strictly to advisory (no-applier) categories: everything
  # else keeps re-mint-on-recurrence.
  describe "advisory approval durability" do
    let!(:chain) do
      create(:ai_approval_chain, account: account,
             trigger_type: "autonomy_action", name: "Fleet Autonomy Actions")
    end

    before do
      Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                     action_category: "system.capability_gap_review",
                                     policy: "require_approval", is_active: true)
    end

    def gate_gap!(fingerprint: "capability_gap:m-1:runtime.rust", summary: "capability gap")
      service.gate_action!("system.capability_gap_review",
                           metadata: { "module_id" => "m-1", "capability" => "runtime.rust",
                                       "signal_fingerprint" => fingerprint },
                           reasoning: { summary: summary },
                           advisory: true)
    end

    # A real operator decision: record_decision! writes an Ai::ApprovalDecision
    # row and then transitions the request. check_expiration! transitions it
    # WITHOUT one — that difference is what separates "a person answered" from
    # "a clock fired", and it is what the durable suppressor keys on.
    let(:operator) { create(:user, account: account) }

    def operator_decides!(decision, completed_at: Time.current)
      request = Ai::ApprovalRequest.last
      request.record_decision!(approver: operator, decision: decision)
      request.reload.tap { |r| r.update_columns(completed_at: completed_at) }
    end

    it "mints one request for a gap fingerprint" do
      expect { gate_gap! }.to change(Ai::ApprovalRequest, :count).by(1)
    end

    it "keeps exactly one standing request across repeated ticks, refreshed in place" do
      gate_gap!
      3.times { gate_gap!(summary: "gap still open") }

      expect(Ai::ApprovalRequest.count).to eq(1)
      expect(Ai::ApprovalRequest.last.description).to eq("gap still open")
    end

    # R1. The whole point of a durable advisory is that a HUMAN answers it.
    # The Fleet chain is timeout_hours 4 / timeout_action "reject", so an
    # unattended gap minted at 02:00 would be auto-rejected at 06:00 with no
    # human involved — and the durable dedup would then suppress it forever,
    # restoring the original "never reaches anyone" defect on the COMMON path.
    # An advisory request therefore carries no deadline at all: expired? is
    # false for a nil expires_at, and every sweep filters on expires_at, so
    # nothing can settle it except a person.
    it "carries no expiry deadline" do
      gate_gap!

      expect(Ai::ApprovalRequest.last.expires_at).to be_nil
    end

    it "survives this service's tick-start sweep still pending, while a non-advisory request is swept" do
      Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                     action_category: "system.instance_reprovision",
                                     policy: "require_approval", is_active: true)
      gate_gap!
      advisory_request = Ai::ApprovalRequest.last
      service.gate_action!("system.instance_reprovision",
                           metadata: { instance_id: "inst-1" }, reasoning: { summary: "silent" })
      real_request = Ai::ApprovalRequest.last.tap { |r| r.update_columns(expires_at: 2.hours.ago) }

      service.tick!

      expect(real_request.reload.status).to eq("rejected") # sweep genuinely ran
      expect(advisory_request.reload.status).to eq("pending")
    end

    # The extension sweep is not the only one: AiApprovalExpiryJob (worker cron)
    # drives core's Ai::Autonomy::ApprovalWorkflowService#expire_overdue!, which
    # sweeps EVERY pending request for the account regardless of source_type.
    # A deadline-free request is invisible to that too — which is why the fix
    # is a nil expires_at rather than a filter in our own sweep.
    it "is not settled by core's account-wide expire_overdue! sweep either" do
      gate_gap!
      advisory_request = Ai::ApprovalRequest.last

      Ai::Autonomy::ApprovalWorkflowService.new(account: account).expire_overdue!

      expect(advisory_request.reload.status).to eq("pending")
    end

    it "re-mints nothing after the sweep — the standing request is still the dedup match" do
      gate_gap!
      service.tick!

      expect { gate_gap!(summary: "gap still open") }.not_to change(Ai::ApprovalRequest, :count)
      expect(Ai::ApprovalRequest.last.status).to eq("pending")
    end

    it "does not re-mint after the operator APPROVES — approval is a durable acknowledgment" do
      gate_gap!
      approved = operator_decides!("approved")

      expect(approved.status).to eq("approved")
      expect { gate_gap!(summary: "gap still open") }.not_to change(Ai::ApprovalRequest, :count)
    end

    it "does not re-mint after an operator REJECTION ages out of the cooldown window" do
      gate_gap!
      rejected = operator_decides!("rejected", completed_at: 30.days.ago)

      expect(rejected.status).to eq("rejected")
      expect { gate_gap! }.not_to change(Ai::ApprovalRequest, :count)
    end

    # The second layer of the R1 fix, and the one that holds even if a deadline
    # ever leaks back onto an advisory request. A timeout-rejected request has
    # no Ai::ApprovalDecision row, so it is NOT a durable operator decision:
    # the gap re-mints on the ordinary cadence and stays visible, rather than
    # being silently suppressed forever by a clock.
    it "re-mints after a TIMEOUT rejection clears its cooldown — a clock is not an operator" do
      gate_gap!
      timed_out = Ai::ApprovalRequest.last
      timed_out.update_columns(expires_at: 2.hours.ago)
      service.tick!

      expect(timed_out.reload.status).to eq("rejected")
      expect(timed_out.decisions).to be_empty # no human answered

      # Inside the ordinary rejection cooldown, re-mint is suppressed as it is
      # for any other category...
      expect { gate_gap! }.not_to change(Ai::ApprovalRequest, :count)

      # ...and once that window passes the gap comes BACK, instead of being
      # durably silenced by a decision nobody made.
      timed_out.update_columns(completed_at: 2.hours.ago)
      expect { gate_gap! }.to change(Ai::ApprovalRequest, :count).by(1)
    end

    it "still mints for a DIFFERENT gap fingerprint — a changed gap is a new fact" do
      gate_gap!
      operator_decides!("approved")

      expect { gate_gap!(fingerprint: "capability_gap:m-1:runtime.zig") }
        .to change(Ai::ApprovalRequest, :count).by(1)
    end

    it "leaves re-mint-on-recurrence intact for non-advisory categories" do
      Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                     action_category: "system.instance_reprovision",
                                     policy: "require_approval", is_active: true)
      service.gate_action!("system.instance_reprovision",
                           metadata: { instance_id: "inst-1" }, reasoning: { summary: "silent" })
      operator_decides!("approved")

      expect {
        service.gate_action!("system.instance_reprovision",
                             metadata: { instance_id: "inst-1" }, reasoning: { summary: "silent again" })
      }.to change(Ai::ApprovalRequest, :count).by(1)
    end
  end
end
