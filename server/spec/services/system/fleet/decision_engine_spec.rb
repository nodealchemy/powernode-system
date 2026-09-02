# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M7.C — DecisionEngine routes signals to skills + actions.
RSpec.describe System::Fleet::DecisionEngine do
  let(:account)  { create(:account) }
  let(:agent)    { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy") }
  let(:service)  { System::Fleet::FleetAutonomyService.new(account: account, agent: agent) }
  let(:engine)   { described_class.new(autonomy_service: service) }

  # The `gated:` keyword on every executor invocation below is the tick loop's
  # contract since APO-1c (IMP-7e2bdc1774e4): BaseSkillExecutor#execute resolves
  # Ai::InterventionPolicy before #perform, and #execute_approved! (replaying an
  # approved request) and #invoke_skill (the F3-06 pre-gate) have ALREADY
  # resolved it — against the SIGNAL's action_category — by the time they build
  # the executor. Without the opt-out a side-effectful skill would park an
  # approval on top of the verdict this engine just acted on.
  #
  # It is `binding[:side_effectful]`, NOT a bare true, and the expectations
  # below spell out which: #invoke_skill's policy resolution runs only inside
  # `if binding.fetch(:side_effectful)`, so on a non-side-effectful binding
  # (DriftRemediate, SdwanFailover, SdwanBgpSessionRemediate, CveResponse) no
  # policy was resolved and there is nothing for the executor's own gate to
  # stand down for. That is invisible today — none of those four declares
  # `requires_approval` — which is exactly why the value is asserted here
  # rather than left to a comment.
  describe "#decide" do
    context "with an unrecognized signal kind" do
      it "skips with reason" do
        d = engine.decide(kind: "system.unknown_thing", severity: :low, payload: {}, fingerprint: "x")
        expect(d[:decision]).to eq(:skipped)
        expect(d[:reason]).to match(/no binding/)
      end
    end

    context "with a system.cert_expiring signal (no skill, just gate)" do
      before do
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: "system.cert_rotate",
                                       policy: "auto_approve", is_active: true)
      end

      it "routes to system.cert_rotate and proceeds via auto_approve" do
        d = engine.decide(kind: "system.cert_expiring", severity: :medium,
                          payload: { certificate_id: "c-1", instance_id: "i-1" },
                          fingerprint: "cert_expiring:c-1")
        expect(d[:action_category]).to eq("system.cert_rotate")
        expect(d[:decision]).to eq(:proceed)
        expect(d[:gate]).to eq("auto_approve")
      end
    end

    context "with a system.instance_silent signal (skill-driven)" do
      let(:platform) { create(:system_node_platform, account: account) }
      let(:template) { create(:system_node_template, account: account, node_platform: platform) }
      let(:node)     { create(:system_node, account: account, node_template: template) }
      let!(:instance) { create(:system_node_instance, :running, node: node) }

      # NOTE: an `ai_approval_chain` row was previously created here for
      # parity with the business-extension Ai::ApprovalChain model, but
      # the system-extension DecisionEngine has no path that consults
      # ApprovalChain — gating is driven entirely by Ai::InterventionPolicy
      # below. The chain row was cross-extension dead weight (the
      # ApprovalChain class lives in extensions/business and is absent in
      # core mode), so it was removed. Add it back only if a real code
      # path in the system extension starts consulting ApprovalChain.

      before do
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: "system.instance_reprovision",
                                       policy: "require_approval", is_active: true)
      end

      it "invokes the drift_remediate skill and gates as require_approval" do
        d = engine.decide(kind: "system.instance_silent", severity: :high,
                          payload: { "instance_id" => instance.id },
                          fingerprint: "instance_silent:#{instance.id}")
        expect(d[:action_category]).to eq("system.instance_reprovision")
        expect(d[:skill_result]).to be_present
        expect(d[:skill_result][:success]).to be true
        expect(d[:decision]).to eq(:pending)
        expect(d[:gate]).to eq("require_approval")
      end
    end

    context "with a system.boot_image_drift signal (campaign 019f505f inc 4)" do
      let(:platform) { create(:system_node_platform, account: account) }
      let(:template) { create(:system_node_template, account: account, node_platform: platform) }
      let(:node)     { create(:system_node, account: account, node_template: template) }
      let!(:drifted_instance) { create(:system_node_instance, :running, node: node) }

      before do
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: "system.node_boot_image_drift",
                                       policy: "require_approval", is_active: true)
      end

      it "invokes the boot_image_drift_rollout executor and gates as require_approval" do
        platform.update!(
          disk_image_git_sha: "promoted-sha",
          disk_image_oci_ref: "oci-ref"
        )
        System::DiskImagePublication.create!(
          account: account,
          node_platform: platform,
          git_sha: "promoted-sha",
          arch: "amd64",
          oci_ref: "oci-ref",
          sha256: "#{'a' * 64}",
          size_bytes: 1024,
          uki_cosign_bundle: "base64_bundle"
        )
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY")
          .and_return("-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEzKyqKWW5nHvyLMYqwP5xPeOXDw" \
                      "tz+sKlxGqKcvK9I5CDLQQRi8S6X8L6kqJMPj7pZ9nFNqnCwHGh/JFVRqZDjA==\n-----END PUBLIC KEY-----")
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

        drifted_instance.update!(booted_image_git_sha: "old-sha")

        d = engine.decide(kind: "system.boot_image_drift", severity: :medium,
                          payload: { "instance_id" => drifted_instance.id, "platform_id" => platform.id },
                          fingerprint: "boot_image_drift:#{drifted_instance.id}")

        expect(d[:action_category]).to eq("system.node_boot_image_drift")
        expect(d[:skill_result]).to be_present
        expect(d[:skill_result][:success]).to be true
        # dry_run: true is passed to the executor by default in the gate, so no tasks created
        expect(d[:skill_result][:data][:dispatched_task_ids]).to be_empty
        expect(d[:decision]).to eq(:pending)
        expect(d[:gate]).to eq("require_approval")
      end
    end

    # Audit finding F3-11: the validate arc never fed back — all 10k+
    # RemediationOutcome rows scored ineffective yet nothing consumed the
    # score, so the same futile remediation re-proceeded every dedup-TTL
    # forever. decide() now checks the fingerprint's recent ineffective
    # streak: at the threshold it emits ONE fleet.remediation_stuck event and
    # forces the gate to require_approval (operator intervention) instead of
    # repeating the proven-ineffective auto-proceed.
    context "stuck remediation escalation (F3-11)" do
      before do
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: "system.cert_rotate",
                                       policy: "auto_approve", is_active: true)
      end

      def record_ineffective!(fingerprint, count, kind: "system.cert_expiring")
        count.times do |i|
          System::Fleet::RemediationOutcome.create!(
            account: account, signal_kind: kind, fingerprint: fingerprint,
            action_category: "system.cert_rotate", status: "ineffective",
            acted_at: (count - i + 1).hours.ago, settle_until: (count - i).hours.ago,
            validated_at: (count - i).hours.ago
          )
        end
      end

      it "forces require_approval + emits one remediation_stuck event at the streak threshold" do
        record_ineffective!("cert_expiring:c-9", described_class::STUCK_STREAK_THRESHOLD)

        expect {
          @decision = engine.decide(kind: "system.cert_expiring", severity: :medium,
                                    payload: { certificate_id: "c-9" },
                                    fingerprint: "cert_expiring:c-9")
        }.to change { System::FleetEvent.where(kind: "fleet.remediation_stuck").count }.by(1)

        expect(@decision[:decision]).to eq(:pending)
        expect(@decision[:remediation_stuck]).to be true
        expect(@decision[:ineffective_streak]).to be >= described_class::STUCK_STREAK_THRESHOLD
      end

      it "proceeds normally below the threshold" do
        record_ineffective!("cert_expiring:c-9", described_class::STUCK_STREAK_THRESHOLD - 1)

        d = engine.decide(kind: "system.cert_expiring", severity: :medium,
                          payload: { certificate_id: "c-9" },
                          fingerprint: "cert_expiring:c-9")

        expect(d[:decision]).to eq(:proceed)
        expect(d[:remediation_stuck]).to be_nil
        expect(System::FleetEvent.where(kind: "fleet.remediation_stuck")).to be_empty
      end

      it "an effective outcome breaks the streak (only consecutive failures count)" do
        record_ineffective!("cert_expiring:c-9", described_class::STUCK_STREAK_THRESHOLD)
        System::Fleet::RemediationOutcome.create!(
          account: account, signal_kind: "system.cert_expiring",
          fingerprint: "cert_expiring:c-9", action_category: "system.cert_rotate",
          status: "effective", acted_at: 10.minutes.ago,
          settle_until: 8.minutes.ago, validated_at: 5.minutes.ago
        )

        d = engine.decide(kind: "system.cert_expiring", severity: :medium,
                          payload: { certificate_id: "c-9" },
                          fingerprint: "cert_expiring:c-9")

        expect(d[:decision]).to eq(:proceed)
      end
    end

    # IMP-01a025b3: the stuck lane had no terminal state. Once the streak
    # pinned at the threshold, decide() short-circuited here forever: the lane
    # skips both skill and remediation, and RemediationValidator only scores
    # decisions that PROCEEDED, so no fresh outcome was ever recorded for the
    # fingerprint and the streak could never move. The trio (fleet.remediation_stuck
    # HIGH + forced require_approval + decision.pending) re-fired every dedup TTL
    # forever. The ApprovalRequest was already deduped to one open row per
    # fingerprint — nothing READ that row before re-escalating.
    #
    # The collateral is the reason this is a bug and not just noise: every
    # non-advisory gate_action! consumes the target module's daily consent
    # budget (ConsentBudgetService#check_and_consume!, an atomic increment per
    # call), and config_drift's metadata carries the REAL module_id — so stuck
    # noise drained LIVE modules' budgets and forced their genuine remediations
    # into require_approval.
    #
    # The gate is the DATABASE (the same open ApprovalRequest
    # create_pending_approval dedupes on), never Rails.cache: the hub runs
    # CACHE_STORE=memory_store, which is per-Puma-process and flushes on
    # restart, so the cache can only ever be an optimization here.
    context "stuck escalation is terminal while an operator request is open (IMP-01a025b3)" do
      let(:platform) { create(:system_node_platform, account: account) }
      let(:node_module) do
        create(:system_node_module, account: account, node_platform: platform,
                                    consent_budget_per_day: 10,
                                    consent_budget_used_count: 0,
                                    consent_budget_window_start_at: Time.current)
      end
      let(:fingerprint) { "config_drift:#{node_module.id}" }
      let!(:chain) do
        create(:ai_approval_chain, account: account, trigger_type: "autonomy_action",
                                   name: "Fleet Autonomy Actions",
                                   timeout_hours: 4, timeout_action: "reject")
      end

      before do
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: "system.module_assign",
                                       policy: "auto_approve", is_active: true)
        described_class::STUCK_STREAK_THRESHOLD.times do |i|
          System::Fleet::RemediationOutcome.create!(
            account: account, signal_kind: "system.config_drift", fingerprint: fingerprint,
            action_category: "system.module_assign", status: "ineffective",
            acted_at: (10 - i).hours.ago, settle_until: (9 - i).hours.ago,
            validated_at: (9 - i).hours.ago
          )
        end
      end

      def decide!
        engine.decide(kind: "system.config_drift", severity: :medium,
                      payload: { "module_id" => node_module.id },
                      fingerprint: fingerprint)
      end

      # Mints the row the previous escalation's gate would have left behind:
      # same source_type/action_category/dedup key create_pending_approval uses.
      def escalation_request!(status: "pending", completed_at: nil,
                              module_id: nil, signal_fingerprint: nil)
        request = chain.create_request!(
          source_type: "system_fleet",
          source_id: "system.module_assign",
          description: "Remediation stuck",
          request_data: {
            "action_category" => "system.module_assign",
            "payload" => { "module_id" => (module_id || node_module.id),
                           "signal_fingerprint" => (signal_fingerprint || fingerprint) }
          }
        )
        # update_columns: a status flip through the model fires
        # #notify_source_of_decision, which has nothing to notify here.
        request.update_columns(status: status, completed_at: completed_at) unless status == "pending"
        request
      end

      it "emits no fleet.remediation_stuck AND consumes no consent budget while a request is open" do
        escalation_request!
        events_before   = System::FleetEvent.where(kind: "fleet.remediation_stuck").count
        budget_before   = node_module.reload.consent_budget_used_count
        requests_before = Ai::ApprovalRequest.count

        decision = decide!

        expect(System::FleetEvent.where(kind: "fleet.remediation_stuck").count).to eq(events_before)
        # The load-bearing half: gate_action! is not called at all, so the
        # module's daily autonomy budget is untouched.
        expect(node_module.reload.consent_budget_used_count).to eq(budget_before)
        expect(Ai::ApprovalRequest.count).to eq(requests_before)
        expect(decision[:decision]).to eq(:awaiting_operator)
        expect(decision[:remediation_stuck]).to be true
      end

      it "escalates exactly once — event, gate and consent budget — when no request is open" do
        expect {
          @decision = decide!
        }.to change { System::FleetEvent.where(kind: "fleet.remediation_stuck").count }.by(1)

        expect(@decision[:decision]).to eq(:pending)
        expect(@decision[:gate]).to eq("require_approval")
        expect(@decision[:remediation_stuck]).to be true
        expect(node_module.reload.consent_budget_used_count).to eq(1)
        expect(Ai::ApprovalRequest.pending.count).to eq(1)
      end

      it "escalates again once the operator has APPROVED the open request" do
        escalation_request!(status: "approved", completed_at: Time.current)

        expect {
          @decision = decide!
        }.to change { System::FleetEvent.where(kind: "fleet.remediation_stuck").count }.by(1)
        expect(@decision[:decision]).to eq(:pending)
      end

      it "stays quiet inside the rejection cooldown the gate itself honors" do
        escalation_request!(status: "rejected", completed_at: 5.minutes.ago)
        budget_before = node_module.reload.consent_budget_used_count

        expect {
          @decision = decide!
        }.not_to change { System::FleetEvent.where(kind: "fleet.remediation_stuck").count }
        expect(@decision[:decision]).to eq(:awaiting_operator)
        expect(node_module.reload.consent_budget_used_count).to eq(budget_before)
      end

      # The other direction of the same choice: a lane that alerts once and
      # then goes silent forever is worse than the noise. Once the rejection
      # cooldown lapses (1h for a non-advancement action) and the condition is
      # still stuck, the operator gets told again.
      it "escalates again once the rejection cooldown has lapsed" do
        escalation_request!(status: "rejected", completed_at: 3.hours.ago)

        expect {
          @decision = decide!
        }.to change { System::FleetEvent.where(kind: "fleet.remediation_stuck").count }.by(1)
        expect(@decision[:decision]).to eq(:pending)
      end

      # The gate's action-level fallback: ANY rejected request in the same
      # action_category inside the cooldown makes create_pending_approval
      # return nil regardless of dedup key. Escalating into that window emitted
      # a HIGH event and burned the module's consent budget to mint NOTHING —
      # the incident verbatim, re-armed by every rejection in the category — so
      # the predicate models this arm too.
      it "stays quiet inside the gate's ACTION-WIDE rejection cooldown" do
        other_module = create(:system_node_module, account: account, node_platform: platform)
        escalation_request!(status: "rejected", completed_at: 5.minutes.ago,
                            module_id: other_module.id, signal_fingerprint: "config_drift:other")
        budget_before = node_module.reload.consent_budget_used_count

        expect {
          @decision = decide!
        }.not_to change { System::FleetEvent.where(kind: "fleet.remediation_stuck").count }
        expect(@decision[:decision]).to eq(:awaiting_operator)
        expect(node_module.reload.consent_budget_used_count).to eq(budget_before)
      end

      # DELIBERATE, and the sharpest edge of this design: config_drift's
      # fingerprint is per-assignment while its gate dedup key is module_id, so
      # N stuck assignments on one module share ONE ApprovalRequest — and now
      # one escalation. The suppressed fingerprint is not dark (its raw
      # system.config_drift signal event and its own decision.awaiting_operator
      # still carry its correlation_id); it just does not raise a second HIGH
      # alert for a request the operator already holds. Change this only by
      # giving the lane a per-fingerprint durable marker — NOT by scoping the
      # query on signal_fingerprint, which flip-flops: the gate rewrites the
      # shared row's payload in place, so each fingerprint would re-escalate
      # every TTL forever.
      it "treats one module's open request as covering every fingerprint sharing its dedup key" do
        escalation_request!(signal_fingerprint: "config_drift:some-other-assignment")
        budget_before = node_module.reload.consent_budget_used_count

        expect {
          @decision = decide!
        }.not_to change { System::FleetEvent.where(kind: "fleet.remediation_stuck").count }
        expect(@decision[:decision]).to eq(:awaiting_operator)
        expect(node_module.reload.consent_budget_used_count).to eq(budget_before)
      end
    end

    # Audit finding F1-12: a member silent past the presumed-dead threshold
    # was re-detected every 60s tick forever — each tick re-emitted a
    # system.instance_silent FleetEvent (and a decision event) because the
    # instance never left the sensor's running/starting scan window. The
    # DecisionEngine now reaps a sustained-silent *running* instance: it
    # transitions status -> error (a non-destructive status correction, NOT
    # the gated reprovision) and emits ONE escalation event, after which the
    # sensor stops matching it and the per-tick stream stops at the source.
    context "sustained instance_silent reaping (F1-12)" do
      let(:platform) { create(:system_node_platform, account: account) }
      let(:template) { create(:system_node_template, account: account, node_platform: platform) }
      let(:node)     { create(:system_node, account: account, node_template: template) }

      def silent_signal(instance, severity: :critical)
        { kind: "system.instance_silent", severity: severity,
          payload: { "instance_id" => instance.id },
          fingerprint: "instance_silent:#{instance.id}" }
      end

      it "marks a sustained-silent running instance error and emits one escalation" do
        instance = create(:system_node_instance, :running, node: node,
                          last_heartbeat_at: 45.minutes.ago)

        expect { @decision = engine.decide(silent_signal(instance)) }
          .to change { System::FleetEvent.where(kind: "system.instance_presumed_dead").count }.by(1)

        expect(@decision[:decision]).to eq(:presumed_dead)
        expect(@decision[:instance_id]).to eq(instance.id)
        expect(instance.reload.status).to eq("error")
      end

      it "emits the escalation INSTEAD of the per-tick raw signal event" do
        instance = create(:system_node_instance, :running, node: node,
                          last_heartbeat_at: 45.minutes.ago)

        expect { engine.decide(silent_signal(instance)) }
          .not_to change { System::FleetEvent.where(kind: "system.instance_silent").count }
      end

      it "is idempotent — an already-error instance is not re-escalated" do
        instance = create(:system_node_instance, :running, node: node,
                          last_heartbeat_at: 45.minutes.ago)
        engine.decide(silent_signal(instance))

        expect { engine.decide(silent_signal(instance)) }
          .not_to change { System::FleetEvent.where(kind: "system.instance_presumed_dead").count }
      end

      it "leaves a recently-silent instance on the approval path (does not reap early)" do
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: "system.instance_reprovision",
                                       policy: "require_approval", is_active: true)
        instance = create(:system_node_instance, :running, node: node,
                          last_heartbeat_at: 5.minutes.ago)

        d = engine.decide(silent_signal(instance, severity: :medium))

        expect(d[:decision]).to eq(:pending)
        expect(instance.reload.status).to eq("running")
      end

      it "does not reap an instance whose heartbeat was never recorded (nil)" do
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: "system.instance_reprovision",
                                       policy: "require_approval", is_active: true)
        instance = create(:system_node_instance, :running, node: node, last_heartbeat_at: nil)

        d = engine.decide(silent_signal(instance, severity: :high))

        expect(d[:decision]).not_to eq(:presumed_dead)
        expect(instance.reload.status).to eq("running")
      end
    end

    # IMP-f5f03a7e8d3b: the approval TTL (1h) outlives the F1-12
    # presumed-dead reap threshold (30 min), so by the time an operator
    # approves a system.instance_reprovision request the instance has
    # USUALLY already been reaped running -> error above — "the race is the
    # norm", not an edge case. reboot_silent_instance hardcoded
    # action: "reboot", and NodeInstance's AASM :reboot event only
    # transitions from :running, so the approved self-heal returned
    # applied:false against exactly the states the reap/sensor loop itself
    # produces, stranding the instance for manual intervention every time.
    context "execute_approved! reboot_silent_instance self-heal (IMP-f5f03a7e8d3b)" do
      let(:platform) { create(:system_node_platform, account: account) }
      let(:template) { create(:system_node_template, account: account, node_platform: platform) }
      let(:node)     { create(:system_node, account: account, node_template: template) }
      let(:adapter)  { instance_double("System::Providers::BaseProvider", provider_type: "mock", supports?: true) }

      def approved_silent_request(instance)
        double("Ai::ApprovalRequest", id: SecureRandom.uuid,
               request_data: {
                 "payload" => {
                   "instance_id" => instance.id,
                   "signal_kind" => "system.instance_silent",
                   "signal_severity" => "high",
                   "signal_fingerprint" => "instance_silent:#{instance.id}"
                 }
               })
      end

      before { allow(System::Providers::Registry).to receive(:for_instance).and_return(adapter) }

      it "self-heals via start when the reap already flipped the instance to error (the normal race outcome)" do
        instance = create(:system_node_instance, node: node, status: "error", cloud_instance_id: "i-123")
        allow(adapter).to receive(:start_instance).with("i-123").and_return(success: true)

        result = engine.execute_approved!(approved_silent_request(instance))

        expect(result[:applied]).to be true
        expect(result[:action]).to eq("start")
        expect(instance.reload.status).to eq("running")
      end

      it "self-heals via start when an operator manually stopped the same silent instance before approving" do
        instance = create(:system_node_instance, node: node, status: "stopped", cloud_instance_id: "i-123")
        allow(adapter).to receive(:start_instance).with("i-123").and_return(success: true)

        result = engine.execute_approved!(approved_silent_request(instance))

        expect(result[:applied]).to be true
        expect(result[:action]).to eq("start")
        expect(instance.reload.status).to eq("running")
      end

      it "returns a status-specific reason instead of silently no-op'ing when stuck in :starting" do
        instance = create(:system_node_instance, node: node, status: "starting", cloud_instance_id: "i-123")

        result = engine.execute_approved!(approved_silent_request(instance))

        expect(result[:applied]).to be false
        expect(result[:reason]).to match(/starting/)
      end

      it "still reboots a genuinely-running instance (baseline, unaffected by the fix)" do
        instance = create(:system_node_instance, :running, node: node, cloud_instance_id: "i-123")
        allow(adapter).to receive(:reboot_instance).with("i-123").and_return(success: true)

        result = engine.execute_approved!(approved_silent_request(instance))

        expect(result[:applied]).to be true
        expect(result[:action]).to eq("reboot")
      end
    end

    # Audit finding F3-05: InstanceStateDriftSensor's signal kind had no
    # SIGNAL_BINDINGS entry, so every provider-state drift it detected was
    # discarded as decision :skipped.
    context "with a system.instance_state_drifted signal (provider-state drift)" do
      before do
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: "system.instance_reboot",
                                       policy: "notify_and_proceed", is_active: true)
      end

      it "routes to the system.instance_reboot gate instead of skipping" do
        d = engine.decide(kind: "system.instance_state_drifted", severity: :high,
                          payload: { instance_id: "inst-1", expected_status: "running",
                                     actual_status: "stopped" },
                          fingerprint: "instance_state_drifted:inst-1:stopped")
        expect(d[:decision]).to eq(:proceed)
        expect(d[:gate]).to eq("notify_and_proceed")
        expect(d[:action_category]).to eq("system.instance_reboot")
      end
    end

    # Audit finding F3-03: a :proceed gate decision produced a plan nothing
    # ever applied — the act arm of sense → decide → act did not exist, so
    # drift persisted forever and every RemediationOutcome scored ineffective.
    context "remediation apply on proceed (F3-03)" do
      let(:platform) { create(:system_node_platform, account: account) }
      let(:template) { create(:system_node_template, account: account, node_platform: platform) }
      let(:node)     { create(:system_node, account: account, node_template: template) }
      let!(:instance) { create(:system_node_instance, :running, node: node) }

      let(:drift_plan) do
        { success: true,
          data: { resolved: true, requires_approval: false, disruption_pct: 5,
                  planned_actions: { attach: [ "mod-1" ], detach: [], update: [] } } }
      end

      before do
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: "system.module_assign",
                                       policy: "notify_and_proceed", is_active: true)
        allow_any_instance_of(::System::Ai::Skills::DriftRemediateExecutor)
          .to receive(:execute).and_return(drift_plan)
      end

      def decide_drift(kind)
        engine.decide(kind: kind, severity: :medium,
                      payload: { "instance_id" => instance.id },
                      fingerprint: "#{kind.split('.').last}:#{instance.id}")
      end

      it "dispatches a sync_modules task when module drift proceeds" do
        d = decide_drift("system.module_drift")

        expect(d[:decision]).to eq(:proceed)
        expect(d[:remediation]).to include(applied: true, command: "sync_modules")
        task = System::Task.find_by(account: account, command: "sync_modules")
        expect(task).to be_present
        expect(task.operable).to eq(instance)
        expect(task.options["source"]).to eq("fleet_autonomy")
        expect(task.options["planned_actions"]).to be_present
      end

      it "dispatches an apply_config task when config drift proceeds" do
        d = decide_drift("system.config_drift")

        expect(d[:remediation]).to include(applied: true, command: "apply_config")
        expect(System::Task.find_by(account: account, command: "apply_config", operable: instance)).to be_present
      end

      # IMP-f1c1e6d61104 part (c) — break the dispatch -> fail -> redispatch loop.
      #
      # Once the agent fails apply_config for a module whose manifest declares
      # reboot_required (part (a) of this task), re-dispatching another
      # apply_config can never converge it: the module's content cannot be
      # materialized live no matter how many times the reconcile runs. Without
      # this, the lane re-dispatches every tick forever, and each failed task
      # also leaves the node unsuppressed, so the loop is loud AND useless.
      #
      # The escalation mirrors apply_template_closure_drift's arm: DECLARE
      # convergence_deferred rather than pretending an apply will fix it. The
      # declaration is what RemediationValidator reads to settle the outcome
      # `inconclusive` instead of scoring it — see
      # deferred_convergence_outcome_spec.rb, which asserts the ROW.
      it "escalates to reprovision instead of re-dispatching after a reboot_pending failure" do
        System::Task.create!(
          account: account, operable: instance, command: "apply_config", status: "failed",
          error_message: "reconcile did not converge 1 module(s): " \
                         "reconciler:reboot_pending [mod-base-os]: reboot_required=true",
          completed_at: 1.minute.ago
        )

        d = decide_drift("system.config_drift")

        expect(d[:remediation]).to include(applied: false, convergence_deferred: true)
        expect(System::Task.where(account: account, command: "apply_config",
                                  operable: instance, status: "pending").count).to eq(0),
                                                                                  "re-dispatched an apply that cannot converge a reboot_required module"
      end

      # CONTROL: an ordinary failure is NOT reboot_pending, so the lane must
      # still retry. Over-applying the escalation would strand every node whose
      # apply failed transiently (a scratch-budget abort clears on its own).
      it "still re-dispatches after a non-reboot_pending failure" do
        System::Task.create!(
          account: account, operable: instance, command: "apply_config", status: "failed",
          error_message: "reconcile did not converge 1 module(s): " \
                         "reconciler:recompose_budget [mod-a]: scratch exhausted",
          completed_at: 1.minute.ago
        )

        d = decide_drift("system.config_drift")

        expect(d[:remediation]).to include(applied: true, command: "apply_config")
      end

      # CONTROL: a reboot_pending failure that has since been SUPERSEDED by a
      # completed apply must not keep blocking dispatch — the condition cleared.
      it "resumes dispatching once a later apply completed" do
        System::Task.create!(
          account: account, operable: instance, command: "apply_config", status: "failed",
          error_message: "reconciler:reboot_pending [mod-base-os]: reboot_required=true",
          completed_at: 10.minutes.ago
        )
        System::Task.create!(
          account: account, operable: instance, command: "apply_config", status: "complete",
          completed_at: 1.minute.ago
        )

        d = decide_drift("system.config_drift")

        expect(d[:remediation]).to include(applied: true, command: "apply_config")
      end

      it "does not duplicate an in-flight reconcile task" do
        System::Task.create!(account: account, operable: instance, command: "sync_modules", status: "pending")

        d = decide_drift("system.module_drift")

        expect(d[:remediation][:applied]).to be false
        expect(d[:remediation][:reason]).to match(/in flight/)
        expect(System::Task.where(account: account, command: "sync_modules").count).to eq(1)
      end

      it "withholds apply when the plan exceeds the disruption budget" do
        drift_plan[:data][:requires_approval] = true

        d = decide_drift("system.module_drift")

        expect(d[:remediation][:applied]).to be false
        expect(System::Task.where(account: account, command: "sync_modules")).to be_empty
      end

      # IMP-43e94c9d46d4: this used to drive system.gitops.drift_detected,
      # which now HAS an applier — so it exercised the applier-less branch by
      # accident of that lane's gap rather than on purpose. system.slo_violation
      # is the lane the 2026-09-02 operator ruling deliberately left dormant
      # (skill: nil, no applier, declared in
      # RemediationValidator::NON_REMEDIATING_SIGNAL_KINDS), so it is the
      # stable subject for the no-applier fallback. It routes to
      # system.module_assign, whose notify_and_proceed policy the enclosing
      # `before` already seeds.
      it "records an unapplied proceed when no applier exists for the kind" do
        d = engine.decide(kind: "system.slo_violation", severity: :medium,
                          payload: { "instance_id" => instance.id },
                          fingerprint: "slo_violation:#{instance.id}")

        expect(d[:decision]).to eq(:proceed)
        expect(d[:remediation]).to include(applied: false)
        expect(d[:remediation][:reason]).to match(/no applier/)
      end

      # IMP-555e29eeb4ab: provider-state drift was notify-only — every
      # instance_state_drifted proceed recorded applied:false forever
      # because REMEDIATION_APPLIERS had no entry for the kind, so a VM
      # stopped/killed behind the platform's back stayed "running" in the
      # model across every hourly CloudSync pass.
      context "system.instance_state_drifted converges the model to the provider-reported state" do
        before do
          Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                         action_category: "system.instance_reboot",
                                         policy: "notify_and_proceed", is_active: true)
        end

        def decide_drifted(instance, actual_status)
          engine.decide(kind: "system.instance_state_drifted", severity: :high,
                        payload: { "instance_id" => instance.id, "expected_status" => "running",
                                   "actual_status" => actual_status },
                        fingerprint: "instance_state_drifted:#{instance.id}:#{actual_status}")
        end

        it "marks the instance stopped when the provider reports stopped" do
          d = decide_drifted(instance, "stopped")

          expect(d[:remediation]).to include(applied: true, converged_to: "stopped")
          expect(instance.reload.status).to eq("stopped")
        end

        it "marks the instance terminated when the provider reports terminated" do
          d = decide_drifted(instance, "terminated")

          expect(d[:remediation]).to include(applied: true, converged_to: "terminated")
          expect(instance.reload.status).to eq("terminated")
        end

        it "marks the instance errored when the provider reports error" do
          d = decide_drifted(instance, "error")

          expect(d[:remediation]).to include(applied: true, converged_to: "error")
          expect(instance.reload.status).to eq("error")
        end

        it "does not re-apply once the instance already matches the reported state" do
          instance.update!(status: "stopped")

          d = decide_drifted(instance, "stopped")

          expect(d[:remediation]).to include(applied: false)
          expect(d[:remediation][:reason]).to match(/already converged/)
          expect(instance.reload.status).to eq("stopped")
        end
      end
    end

    # IMP-df40782d3f4d — credential-expiry remediation must refresh the
    # CREDENTIAL, not rotate the key. An MC can only near expiry when the
    # agent is not pulling (Sdwan::TopologyCompiler#ensure_fresh! refreshes
    # it on every pull), so the F3-07 binding to SdwanPeerRemediateExecutor
    # under system.sdwan_key_rotate (auto_approve — no human in the loop)
    # did nothing for the MC while REVOKING the active WireGuard key: hubs
    # drop the old pubkey on their next compile and the still-connected,
    # not-yet-polling peer loses a WORKING tunnel. The remediation converted
    # a degraded control channel into a broken data plane.
    context "with a system.sdwan_credential_expiring signal (real peer + MC)" do
      def policy!(action_category, policy)
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: action_category,
                                       policy: policy, is_active: true)
      end

      let(:network) { create(:sdwan_network, account: account) }
      # :active — a still-connected peer with a working tunnel is exactly
      # the scenario: its agent has stopped pulling, so its MC ages out
      # while the data plane is fine.
      let(:peer) do
        p = create(:sdwan_peer, :active, account: account, network: network,
                                         last_compiled_at: 1.hour.ago)
        Sdwan::KeyDistributor.ensure_key_for!(p)
        p.reload
      end
      # A real signed MC aged into the sensor's advisory window: refresh is
      # long overdue, hard expiry is 10 minutes out — the exact state the
      # SdwanCredentialExpirySensor fingerprints. Aged coherently (as if
      # issued 50 minutes into its 1h TTL) so the row still validates when
      # the signer supersedes it.
      let(:expiring_mc) do
        mc = Sdwan::MembershipCredentialSigner.issue!(peer: peer)
        mc.update_columns(issued_at: 50.minutes.ago, not_before: 50.minutes.ago,
                          refresh_after: 20.minutes.ago, not_after: 10.minutes.from_now)
        mc
      end

      before do
        # Both categories seeded as db/seeds/fleet_autonomy_agent.rb ships
        # them, so this example pins the PROPERTY (which remediation runs)
        # rather than mirroring whichever binding is currently live.
        policy!("system.sdwan_key_rotate", "auto_approve")
        policy!("system.sdwan_credential_refresh", "notify_and_proceed")
      end

      def decide_expiring!
        engine.decide(kind: "system.sdwan_credential_expiring", severity: :high,
                      payload: { "membership_credential_id" => expiring_mc.id,
                                 "peer_id" => peer.id,
                                 "network_id" => network.id,
                                 "revision" => expiring_mc.revision },
                      fingerprint: "sdwan_credential_expiring:#{expiring_mc.id}")
      end

      it "refreshes the membership credential without revoking the active WireGuard key" do
        wg_key = peer.active_key

        d = decide_expiring!

        # THE HARM, pinned first: the working tunnel's key material must be
        # untouched — key rotation is drift/compromise remediation, not
        # credential refresh. Under the old binding this is what failed:
        # the auto_approved SdwanPeerRemediateExecutor revoked the active
        # key of exactly the peer that isn't polling for a replacement.
        expect(wg_key.reload.revoked?).to be(false)
        expect(peer.reload.active_key.id).to eq(wg_key.id)
        expect(peer.status).to eq("active") # no forced re-handshake
        expect(peer.last_compiled_at).to be_present # no forced recompile

        expect(d[:decision]).to eq(:proceed)
        expect(d[:action_category]).to eq("system.sdwan_credential_refresh")

        # A fresh MC now supersedes the expiring one, ready for the agent's
        # next pull...
        fresh = Sdwan::MembershipCredential
                  .where(sdwan_peer_id: peer.id, sdwan_network_id: network.id)
                  .order(revision: :desc).first
        expect(fresh.id).not_to eq(expiring_mc.id)
        expect(fresh.status).to eq("active")
        expect(fresh.not_after).to be > 30.minutes.from_now
        expect(d.dig(:skill_result, :success)).to be(true)
      end

      it "clears the sensor's fingerprint so the validate arc scores the refresh honestly" do
        decide_expiring!

        # The superseded row leaves the sensor's `.live` window and the new
        # row is an hour from expiry — the fingerprint
        # "sdwan_credential_expiring:<mc.id>" vanishes on the next sense
        # pass, so RemediationValidator scores this lane effective on real
        # convergence. No NON_REMEDIATING exemption needed (or wanted).
        sensor = System::Fleet::Sensors::SdwanCredentialExpirySensor.new(account: account)
        fingerprints = sensor.sense.map(&:fingerprint)
        expect(fingerprints).not_to include("sdwan_credential_expiring:#{expiring_mc.id}")
        expect(fingerprints.grep(/^sdwan_credential_refresh_stalled/)).to be_empty
      end
    end

    # Audit finding F3-07: three sensors existed but were never registered,
    # and their signal kinds had no bindings — even if invoked they would
    # have been discarded as decision :skipped.
    context "F3-07 sensor signal bindings" do
      def policy!(action_category, policy)
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: action_category,
                                       policy: policy, is_active: true)
      end

      # IMP-df40782d3f4d rebound this kind from the key-rotate gate (which
      # revoked the active WG key) to the credential-refresh gate. The real
      # end-to-end behavior is pinned in the dedicated context above; this
      # example keeps the F3-07 registration story: the kind has a binding
      # and its executor is invoked.
      it "routes sdwan_credential_expiring to the credential-refresh gate and invokes the refresh executor" do
        policy!("system.sdwan_credential_refresh", "notify_and_proceed")
        allow_any_instance_of(::System::Ai::Skills::SdwanCredentialRefreshExecutor)
          .to receive(:execute).and_return({ success: true, data: { resolved: true } })

        d = engine.decide(kind: "system.sdwan_credential_expiring", severity: :high,
                          payload: { "membership_credential_id" => "mc-1", "peer_id" => "peer-1" },
                          fingerprint: "sdwan_credential_expiring:mc-1")

        expect(d[:action_category]).to eq("system.sdwan_credential_refresh")
        expect(d[:decision]).to eq(:proceed)
        expect(d[:skill_result]).to include(success: true)
      end

      it "routes sdwan_credential_refresh_stalled to observation instead of skipping" do
        policy!("system.observation", "auto_approve")

        d = engine.decide(kind: "system.sdwan_credential_refresh_stalled", severity: :high,
                          payload: { "peer_id" => "peer-1", "network_id" => "net-1" },
                          fingerprint: "sdwan_credential_refresh_stalled:peer-1:net-1")

        expect(d[:action_category]).to eq("system.observation")
        expect(d[:decision]).to eq(:proceed)
      end

      it "routes package_drift_pressure to the package repository sync gate" do
        policy!("system.package_repository.sync", "auto_approve")

        d = engine.decide(kind: "system.package_drift_pressure", severity: :medium,
                          payload: { "package_module_link_id" => "lnk-1", "package_repository_id" => "repo-1" },
                          fingerprint: "pkg_drift:lnk-1:2.0")

        expect(d[:action_category]).to eq("system.package_repository.sync")
        expect(d[:decision]).to eq(:proceed)
      end

      it "reconciles a stale storage assignment when storage_assignment_drift proceeds" do
        policy!("system.storage_assignment_reconcile", "notify_and_proceed")
        platform = create(:system_node_platform, account: account)
        template = create(:system_node_template, account: account, node_platform: platform)
        node = create(:system_node, account: account, node_template: template)
        inst = create(:system_node_instance, :running, node: node)
        file_storage = create(:file_storage, :nfs, :node_mountable, account: account)
        assignment = create(:system_storage_assignment, account: account, node_instance: inst,
                            file_storage_id: file_storage.id)
        assignment.update_columns(status: "degraded", last_status_at: 10.minutes.ago)
        allow(::System::Storage::AssignmentReconciliationService).to receive(:reconcile_assignment!)

        d = engine.decide(kind: "system.storage_assignment_drift", severity: :medium,
                          payload: { "storage_assignment_id" => assignment.id },
                          fingerprint: "storage_assignment_drift:#{assignment.id}")

        expect(d[:action_category]).to eq("system.storage_assignment_reconcile")
        expect(d[:decision]).to eq(:proceed)
        expect(d[:remediation]).to include(applied: true)
        expect(::System::Storage::AssignmentReconciliationService)
          .to have_received(:reconcile_assignment!).with(assignment)
      end
    end

    # Audit finding F3-04: invoke_skill's class-name case statement silently
    # dropped the four SDWAN executors bound in SIGNAL_BINDINGS (fell through
    # to `else nil`), so peer key rotation and BGP session remediation never
    # ran. Dispatch now flows through each binding's input_mapper.
    context "with SDWAN signals (executor dispatch)" do
      it "invokes SdwanPeerRemediateExecutor with peer_id and proceeds via notify_and_proceed" do
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: "system.sdwan_peer_remediate",
                                       policy: "notify_and_proceed", is_active: true)
        executor = instance_double(System::Ai::Skills::SdwanPeerRemediateExecutor)
        allow(System::Ai::Skills::SdwanPeerRemediateExecutor).to receive(:new).and_return(executor)
        expect(executor).to receive(:execute).with(gated: true, peer_id: "peer-1")
                                             .and_return({ success: true, data: { resolved: true } })

        d = engine.decide(kind: "system.sdwan_peer_drift", severity: :high,
                          payload: { peer_id: "peer-1", network_id: "net-1" },
                          fingerprint: "sdwan_peer_drift:peer-1")
        expect(d[:decision]).to eq(:proceed)
        expect(d[:skill_result]).to eq({ success: true, data: { resolved: true } })
      end

      it "invokes SdwanFailoverExecutor with the network_id" do
        executor = instance_double(System::Ai::Skills::SdwanFailoverExecutor)
        allow(System::Ai::Skills::SdwanFailoverExecutor).to receive(:new).and_return(executor)
        expect(executor).to receive(:execute).with(gated: false, network_id: "net-1")
                                             .and_return({ success: true, data: {} })

        engine.decide(kind: "system.sdwan_hub_unreachable", severity: :critical,
                      payload: { network_id: "net-1" },
                      fingerprint: "sdwan_hub_unreachable:net-1")
      end

      it "invokes SdwanBgpSessionRemediateExecutor with session, peer and neighbor address" do
        executor = instance_double(System::Ai::Skills::SdwanBgpSessionRemediateExecutor)
        allow(System::Ai::Skills::SdwanBgpSessionRemediateExecutor).to receive(:new).and_return(executor)
        expect(executor).to receive(:execute)
          .with(gated: false, bgp_session_id: "bgp-1", peer_id: "peer-1", neighbor_address: "10.0.0.2")
          .and_return({ success: true, data: {} })

        engine.decide(kind: "system.sdwan_bgp_session_unhealthy", severity: :high,
                      payload: { bgp_session_id: "bgp-1", peer_id: "peer-1",
                                 neighbor_address: "10.0.0.2" },
                      fingerprint: "bgp:bgp-1")
      end

      it "invokes SdwanVipFailoverExecutor plan-only by default (approval-gated, side-effectful)" do
        executor = instance_double(System::Ai::Skills::SdwanVipFailoverExecutor)
        allow(System::Ai::Skills::SdwanVipFailoverExecutor).to receive(:new).and_return(executor)
        # No intervention policy row → resolves to the require_approval
        # default, so the side-effectful failover runs as a dry_run plan.
        expect(executor).to receive(:execute).with(gated: true, virtual_ip_id: "vip-1", dry_run: true)
                                             .and_return({ success: true, data: {} })

        engine.decide(kind: "system.sdwan_vip_unreachable", severity: :critical,
                      payload: { virtual_ip_id: "vip-1" },
                      fingerprint: "vip:vip-1")
      end
    end

    # Audit finding F3-09: ConfigDriftSensor emits node_id/module_id/
    # assignment_id (never instance_id), but the config_drift binding mapped
    # instance_id straight out of the payload — every executor invocation ran
    # with instance_id: nil, and the act arm's reconcile dispatch resolved no
    # instance, so the highest-volume live signal never produced a plan or a
    # task.
    context "with the real config_drift sensor payload shape (F3-09)" do
      let(:platform) { create(:system_node_platform, account: account) }
      let(:template) { create(:system_node_template, account: account, node_platform: platform) }
      let(:node)     { create(:system_node, account: account, node_template: template) }
      let!(:instance) { create(:system_node_instance, :running, node: node) }

      let(:sensor_payload) do
        { "node_id" => node.id, "module_id" => "mod-1", "assignment_id" => "asgn-1",
          "instance_ids" => [ instance.id ] }
      end

      before do
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: "system.module_assign",
                                       policy: "notify_and_proceed", is_active: true)
      end

      it "invokes DriftRemediateExecutor with the instance resolved from instance_ids" do
        executor = instance_double(System::Ai::Skills::DriftRemediateExecutor)
        allow(System::Ai::Skills::DriftRemediateExecutor).to receive(:new).and_return(executor)
        expect(executor).to receive(:execute).with(gated: false, instance_id: instance.id)
                                             .and_return({ success: true, data: { resolved: true } })

        engine.decide(kind: "system.config_drift", severity: :medium,
                      payload: sensor_payload, fingerprint: "config_drift:asgn-1")
      end

      it "dispatches the apply_config reconcile task against the resolved instance" do
        allow_any_instance_of(::System::Ai::Skills::DriftRemediateExecutor)
          .to receive(:execute)
          .and_return({ success: true,
                        data: { resolved: true, requires_approval: false, disruption_pct: 5,
                                planned_actions: { attach: [ "mod-1" ], detach: [], update: [] } } })

        d = engine.decide(kind: "system.config_drift", severity: :medium,
                          payload: sensor_payload, fingerprint: "config_drift:asgn-1b")

        expect(d[:remediation]).to include(applied: true, command: "apply_config")
        expect(System::Task.find_by(account: account, command: "apply_config", operable: instance)).to be_present
      end

      it "skips the executor instead of invoking it with a nil instance when no instances are running" do
        executor = instance_double(System::Ai::Skills::DriftRemediateExecutor)
        allow(System::Ai::Skills::DriftRemediateExecutor).to receive(:new).and_return(executor)
        expect(executor).not_to receive(:execute)

        engine.decide(kind: "system.config_drift", severity: :medium,
                      payload: sensor_payload.merge("instance_ids" => []),
                      fingerprint: "config_drift:asgn-2")
      end
    end

    # Audit finding F3-06: side-effectful executors ran BEFORE the policy
    # gate, so flipping a policy to require_approval/block did not stop the
    # action — it only changed how the already-performed action was recorded.
    context "policy gating of side-effectful executors" do
      it "does not invoke PlatformMaintenanceExecutor when acme cert rotation requires approval" do
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: "system.acme_cert_rotate",
                                       policy: "require_approval", is_active: true)
        expect(System::Ai::Skills::PlatformMaintenanceExecutor).not_to receive(:new)

        d = engine.decide(kind: "system.acme_cert_expiring", severity: :medium,
                          payload: { certificate_id: "cert-1" },
                          fingerprint: "acme:cert-1")
        expect(d[:decision]).to eq(:pending)
        expect(d[:skill_result]).to be_nil
      end

      it "does not invoke PlatformMaintenanceExecutor when the policy is block" do
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: "system.acme_cert_rotate",
                                       policy: "block", is_active: true)
        expect(System::Ai::Skills::PlatformMaintenanceExecutor).not_to receive(:new)

        d = engine.decide(kind: "system.acme_cert_expiring", severity: :medium,
                          payload: { certificate_id: "cert-1" },
                          fingerprint: "acme:cert-1-block")
        expect(d[:decision]).to eq(:blocked)
        expect(d[:skill_result]).to be_nil
      end

      it "still invokes PlatformMaintenanceExecutor for real on notify_and_proceed" do
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: "system.acme_cert_rotate",
                                       policy: "notify_and_proceed", is_active: true)
        executor = instance_double(System::Ai::Skills::PlatformMaintenanceExecutor)
        allow(System::Ai::Skills::PlatformMaintenanceExecutor).to receive(:new).and_return(executor)
        expect(executor).to receive(:execute).with(gated: true, action: "cert_rotate", certificate_id: "cert-1")
                                             .and_return({ success: true, data: {} })

        d = engine.decide(kind: "system.acme_cert_expiring", severity: :medium,
                          payload: { certificate_id: "cert-1" },
                          fingerprint: "acme:cert-1-auto")
        expect(d[:decision]).to eq(:proceed)
      end

      it "runs FederationPeerRemediateExecutor plan-only (dry_run) when approval is required" do
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: "system.federation_peer_remediate",
                                       policy: "require_approval", is_active: true)
        executor = instance_double(System::Ai::Skills::FederationPeerRemediateExecutor)
        allow(System::Ai::Skills::FederationPeerRemediateExecutor).to receive(:new).and_return(executor)
        expect(executor).to receive(:execute)
          .with(gated: true, federation_peer_id: "fp-1", reason: "heartbeat_stale", dry_run: true)
          .and_return({ success: true, data: { plan: "degrade" } })

        d = engine.decide(kind: "system.federation_peer_liveness", severity: :high,
                          payload: { federation_peer_id: "fp-1", reason: "heartbeat_stale" },
                          fingerprint: "fed:fp-1")
        expect(d[:decision]).to eq(:pending)
        expect(d[:skill_result]).to eq({ success: true, data: { plan: "degrade" } })
      end

      it "runs SdwanPeerRemediateExecutor plan-only (dry_run) when approval is required" do
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: "system.sdwan_peer_remediate",
                                       policy: "require_approval", is_active: true)
        executor = instance_double(System::Ai::Skills::SdwanPeerRemediateExecutor)
        allow(System::Ai::Skills::SdwanPeerRemediateExecutor).to receive(:new).and_return(executor)
        expect(executor).to receive(:execute).with(gated: true, peer_id: "peer-9", dry_run: true)
                                             .and_return({ success: true, data: {} })

        engine.decide(kind: "system.sdwan_peer_drift", severity: :high,
                      payload: { peer_id: "peer-9" },
                      fingerprint: "sdwan_peer_drift:peer-9")
      end
    end

    # Campaign 019f6084 §2.4.3 — TemplateClosureDriftSensor's remediation.
    # Blast radius is TemplateApprovalPolicy's call (carried on the signal by
    # the sensor), not the seeded InterventionPolicy's — decide() forces the
    # gate off that flag. The actual apply (TemplateApplyService#apply! +
    # either a live sync_modules task or a pivot rolling-reprovision flag)
    # only runs on the execute_approved! replay, mirroring how every other
    # blast-radius-gated remediation in this engine works.
    context "with a system.template_closure_drift signal (campaign 019f6084 §2.4.3)" do
      let(:platform)  { create(:system_node_platform, account: account) }
      let(:template)  { create(:system_node_template, account: account, node_platform: platform) }
      let(:node)      { create(:system_node, account: account, node_template: template) }
      let!(:instance) { create(:system_node_instance, :running, node: node) }
      let(:module_a)  { create(:system_node_module, account: account, name: "closure-a-#{SecureRandom.hex(3)}") }

      before do
        create(:system_template_module, node_template: template, node_module: module_a)
      end

      def closure_signal(requires_approval:)
        { kind: "system.template_closure_drift", severity: :medium,
          payload: { "instance_id" => instance.id, "node_id" => node.id, "template_id" => template.id,
                     "missing_module_ids" => [ module_a.id ], "missing_count" => 1,
                     "requires_approval" => requires_approval },
          fingerprint: "template_closure_drift:#{instance.id}" }
      end

      def approved_closure_request
        double("Ai::ApprovalRequest", id: SecureRandom.uuid,
               request_data: { "payload" => {
                 "instance_id" => instance.id,
                 "signal_kind" => "system.template_closure_drift",
                 "signal_severity" => "medium",
                 "signal_fingerprint" => "template_closure_drift:#{instance.id}",
                 "missing_module_ids" => [ module_a.id ]
               } })
      end

      it "forces require_approval off the signal's own flag, even under a permissive seeded policy" do
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: "system.template_closure_apply",
                                       policy: "auto_approve", is_active: true)

        d = engine.decide(closure_signal(requires_approval: true))

        expect(d[:action_category]).to eq("system.template_closure_apply")
        expect(d[:decision]).to eq(:pending)
        expect(d[:gate]).to eq("require_approval")
        expect(System::NodeModuleAssignment.exists?(node: node, node_module: module_a)).to be false
      end

      it "proceeds under the seeded policy when the signal itself says requires_approval: false" do
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: "system.template_closure_apply",
                                       policy: "notify_and_proceed", is_active: true)

        d = engine.decide(closure_signal(requires_approval: false))

        expect(d[:decision]).to eq(:proceed)
        expect(d[:remediation]).to include(applied: true)
        expect(d[:remediation]).not_to have_key(:convergence_deferred)
        expect(System::NodeModuleAssignment.find_by(node: node, node_module: module_a)).to be_present
        expect(System::Task.find_by(account: account, command: "sync_modules", operable: instance)).to be_present
      end

      it "creates the missing assignment and queues sync_modules for a cloud_init (non-pivot) instance on approval" do
        result = engine.execute_approved!(approved_closure_request)

        expect(result[:applied]).to be true
        expect(result).not_to have_key(:convergence_deferred)
        expect(result[:assignments_created]).to contain_exactly(module_a.id)
        expect(System::NodeModuleAssignment.find_by(node: node, node_module: module_a)).to be_present
        task = System::Task.find_by(account: account, command: "sync_modules", operable: instance)
        expect(task).to be_present
        expect(result[:task_id]).to eq(task.id)
      end

      it "creates the missing assignment WITHOUT a live sync for a pivot-booted instance, flagging reprovision" do
        template.update!(config: { "boot_mode" => "direct_kernel" })

        result = engine.execute_approved!(approved_closure_request)

        expect(result[:applied]).to be true
        expect(result[:convergence_deferred]).to be true
        expect(result[:assignments_created]).to contain_exactly(module_a.id)
        expect(System::NodeModuleAssignment.find_by(node: node, node_module: module_a)).to be_present
        expect(System::Task.where(account: account, command: "sync_modules", operable: instance)).to be_empty
      end

      it "does not duplicate an in-flight sync_modules task for the non-pivot path" do
        System::Task.create!(account: account, operable: instance, command: "sync_modules", status: "pending")

        result = engine.execute_approved!(approved_closure_request)

        # The assignment is still created — only the live-sync dispatch is withheld.
        expect(System::NodeModuleAssignment.find_by(node: node, node_module: module_a)).to be_present
        expect(result[:applied]).to be false
        expect(result[:reason]).to match(/in flight/)
        expect(System::Task.where(account: account, command: "sync_modules").count).to eq(1)
      end
    end

    # IMP-4019664a524b — CapabilityGapSensor has been emitting
    # system.capability_gap into a SIGNAL_BINDINGS table with no entry for the
    # kind, so every unresolved `capability:<tag>` requirement terminated in
    # the no-binding branch as decision :skipped. The binding routes the gap
    # to the operator and deliberately stops there: closing a gap means
    # AUTHORING a module, which must pass the R1/R2/R3 reuse gate
    # (docs/runbooks/module-authoring.md Phase 0).
    context "with a system.capability_gap signal (IMP-4019664a524b)" do
      let(:consumer) { create(:system_node_module, account: account, name: "gap-consumer-#{SecureRandom.hex(3)}") }

      def gap_signal
        { kind: "system.capability_gap", severity: :medium,
          payload: { "capability" => "runtime.rust", "constraint" => nil,
                     "module_id" => consumer.id, "module_name" => consumer.name },
          fingerprint: "capability_gap:#{consumer.id}:runtime.rust" }
      end

      before do
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: "system.capability_gap_review",
                                       policy: "require_approval", is_active: true)
      end

      it "routes the gap to the operator review gate instead of dropping it as :skipped" do
        d = engine.decide(gap_signal)

        expect(d[:decision]).not_to eq(:skipped)
        expect(d[:action_category]).to eq("system.capability_gap_review")
        expect(d[:decision]).to eq(:pending)
        expect(d[:gate]).to eq("require_approval")
      end

      it "invokes no executor — the binding carries no skill, so nothing runs pre-gate" do
        d = engine.decide(gap_signal)

        expect(d[:skill_result]).to be_nil
        expect(described_class::SIGNAL_BINDINGS["system.capability_gap"][:skill]).to be_nil
      end

      # A gap only closes when a human authors a providing module — days, not
      # ticks. Entering the remediation-validate arc would score the standing
      # fingerprint ineffective forever and manufacture false
      # fleet.remediation_stuck escalations (F3-11). require_approval keeps
      # #decide at :pending, which record_proceeded! never snapshots.
      it "records no RemediationOutcome for a standing gap" do
        validator = System::Fleet::RemediationValidator.new(account: account, agent: agent)
        signal = System::Fleet::Signal.from_hash(gap_signal)

        d = engine.decide(signal)

        # Discriminates: an unbound kind ALSO records nothing (it never
        # reaches :proceed either), so the outcome assertion alone would pass
        # against a deleted binding. The gap must have been routed first.
        expect(d[:decision]).to eq(:pending)
        expect(d[:action_category]).to eq("system.capability_gap_review")
        expect { validator.record_proceeded!(decisions: [ d ], signals: [ signal ]) }
          .not_to change { System::Fleet::RemediationOutcome.count }
      end

      # gate_action! consumes the per-module consent budget BEFORE resolving
      # policy (fleet_autonomy_service.rb:314-316), keyed off metadata
      # module_id — and CapabilityGapSensor stamps the REQUIRING module's id.
      # A standing gap re-decides every dedup TTL (144x/day at 600s), so
      # without an exemption an advisory no-op exhausts the operator's ceiling
      # and forces that module's REAL remediations (module_drift, config_drift,
      # promote) down the budget-exhausted require_approval branch.
      it "consumes no per-module consent budget" do
        consumer.update!(consent_budget_per_day: 5, consent_budget_used_count: 0,
                         consent_budget_window_start_at: Time.current)

        engine.decide(gap_signal)

        expect(consumer.reload.consent_budget_used_count).to eq(0)
      end

      # End-to-end: signal -> real binding -> gate -> durable approval request.
      # The binding and the durability rules are otherwise covered in disjoint
      # halves (decision shape here, gate mechanics in
      # fleet_autonomy_service_spec), so nothing proved they meet.
      it "carries a real gap signal through the binding into one deadline-free, durable request" do
        skip "requires Ai::ApprovalChain (business extension)" unless defined?(::Ai::ApprovalChain)
        create(:ai_approval_chain, account: account,
               trigger_type: "autonomy_action", name: "Fleet Autonomy Actions")

        first = engine.decide(gap_signal)
        request = first[:decision_record]

        expect(first[:decision]).to eq(:pending)
        expect(request).to be_present
        expect(request.request_data["payload"]["signal_kind"]).to eq("system.capability_gap")
        # No deadline: a clock must never bury a gap only a human can close.
        expect(request.expires_at).to be_nil

        # The operator answers it, and the gap stops re-asking. The dedup cache
        # is bypassed (a fresh engine) so this exercises the approval-side
        # durability, not the 600s decide-cache.
        request.record_decision!(approver: create(:user, account: account), decision: "approved")

        expect {
          described_class.new(autonomy_service: service).decide(gap_signal)
        }.not_to change(Ai::ApprovalRequest, :count)
        expect(Ai::ApprovalRequest.count).to eq(1)
      end

      it "leaves the budget consumption of non-advisory module actions intact" do
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: "system.module_promote_to_live",
                                       policy: "require_approval", is_active: true)
        consumer.update!(consent_budget_per_day: 5, consent_budget_used_count: 0,
                         consent_budget_window_start_at: Time.current)

        engine.decide(kind: "system.module_promotion_ready", severity: :medium,
                      payload: { "module_id" => consumer.id },
                      fingerprint: "module_promotion_ready:#{consumer.id}")

        expect(consumer.reload.consent_budget_used_count).to eq(1)
      end

      # Approving the review acknowledges the gap; it must not author or
      # assign anything. The absent REMEDIATION_APPLIERS entry is the
      # mechanism, and the execution stamp says so rather than silently
      # reporting success.
      it "does not auto-remediate when the operator approves the review" do
        request = double("Ai::ApprovalRequest", id: SecureRandom.uuid,
                         request_data: { "payload" => {
                           "module_id" => consumer.id,
                           "capability" => "runtime.rust",
                           "signal_kind" => "system.capability_gap",
                           "signal_severity" => "medium",
                           "signal_fingerprint" => "capability_gap:#{consumer.id}:runtime.rust"
                         } })

        result = engine.execute_approved!(request)

        expect(result[:applied]).to be false
        expect(result[:reason]).to match(/no applier/)
        expect(described_class::REMEDIATION_APPLIERS).not_to have_key("system.capability_gap")
        # Discriminates: execute_approved! reports the same "no applier" for a
        # kind with NO binding at all, so pin that the gap is genuinely routed
        # and merely un-remediated, rather than unrouted.
        expect(engine.decide(gap_signal)[:decision]).to eq(:pending)
      end
    end
  end

  # RCP v2 (campaign 019f9250, increment p0c) — INV-1: no self-management.
  # Distinct from (and layered alongside) the existing ControlPlaneFence —
  # see System::Autonomy::SelfManagementFence's doc comment. Exercised
  # through the same #decide entry point the pre-existing instance_silent
  # tests above use, so this proves the REAL reap_presumed_dead! short-
  # circuit at the top of #decide, not just the fence predicate in
  # isolation (already covered by self_management_fence_spec.rb).
  describe "INV-1 self-management fence" do
    let(:platform) { create(:system_node_platform, account: account) }
    let(:template) { create(:system_node_template, account: account, node_platform: platform) }
    let(:node)     { create(:system_node, account: account, node_template: template) }
    let!(:instance) do
      create(:system_node_instance, :running, node: node,
             last_heartbeat_at: Time.current - (System::Fleet::DecisionEngine::PRESUMED_DEAD_SILENCE_SECONDS + 60))
    end

    def signal
      { kind: "system.instance_silent", severity: :high,
        payload: { instance_id: instance.id }, fingerprint: "instance_silent:#{instance.id}" }
    end

    it "reaps (marks :error) a silent instance when self_hosting_node_id is unconfigured (unchanged default behavior)" do
      d = engine.decide(signal)
      expect(d[:decision]).to eq(:presumed_dead)
      expect(instance.reload.status).to eq("error")
    end

    it "does NOT reap a silent instance on this deployment's own configured self-hosting node" do
      SiteSetting.set("self_hosting_node_id", node.id)

      d = engine.decide(signal)

      # reap_presumed_dead! returns nil for a self-managed target -> #decide
      # falls through to its NORMAL signal routing (whatever that resolves
      # to is orthogonal to this invariant) — the one thing INV-1 requires
      # is that the reap-arm specifically never fired.
      expect(d[:decision]).not_to eq(:presumed_dead)
      expect(instance.reload.status).to eq("running") # unchanged — no self-management reap
    end

    it "still reaps once a DIFFERENT node is configured as self-hosting (the fence is target-specific)" do
      SiteSetting.set("self_hosting_node_id", create(:system_node, account: account).id)

      d = engine.decide(signal)

      expect(d[:decision]).to eq(:presumed_dead)
      expect(instance.reload.status).to eq("error")
    end
  end

  describe "SIGNAL_BINDINGS" do
    it "declares a callable input_mapper for every binding with a skill" do
      missing = described_class::SIGNAL_BINDINGS
                  .select { |_kind, b| b[:skill] && !b[:input_mapper].respond_to?(:call) }
      expect(missing.keys).to eq([])
    end

    it "declares side_effectful for every binding with a skill" do
      missing = described_class::SIGNAL_BINDINGS
                  .select { |_kind, b| b[:skill] && ![ true, false ].include?(b[:side_effectful]) }
      expect(missing.keys).to eq([])
    end
  end

  describe "#decide_all" do
    it "returns one decision per signal" do
      signals = [
        { kind: "system.unknown1", severity: :low, payload: {}, fingerprint: "x" },
        { kind: "system.unknown2", severity: :low, payload: {}, fingerprint: "y" }
      ]
      decisions = engine.decide_all(signals)
      expect(decisions.size).to eq(2)
      expect(decisions.map { |d| d[:decision] }).to all(eq(:skipped))
    end
  end

  # The staging→blessed pipeline was fully built for DETECTION and GATING and
  # dead-ended at actuation. ModulePromotionSensor finds eligible versions and
  # SIGNAL_BINDINGS routes them through the approval gate, but the binding's
  # comment claims "ModulePromotionService is invoked directly" and that is
  # false: promote! has zero call sites in application code, and
  # REMEDIATION_APPLIERS had no entry for the kind — so an operator could
  # approve a promotion and apply_remediation! fell through to
  # {applied: false, reason: "no applier..."}. Same class of defect as
  # IMP-555e29eeb4ab and IMP-83471cc28e1a, both fixed by adding the entry.
  describe "system.module_promotion_ready actuates the promotion" do
    let(:node_module) { create(:system_node_module, account: account) }

    def staging_version(number: 1)
      create(:system_node_module_version, node_module: node_module, version_number: number,
             promotion_state: "staging",
             artifacts: { "erofs" => { "oci_digest" => "sha256:#{'a' * 64}", "size" => 12_345_000 } })
    end

    before do
      Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                     action_category: "system.module_promote_to_live",
                                     policy: "notify_and_proceed", is_active: true)
      # Eligibility itself has its own specs; stub it so the real
      # ModulePromotionService.promote! runs and the assertion is the version
      # ACTUALLY transitioning rather than a mock being called.
      allow(::System::Fleet::PromotionCriteria).to receive(:evaluate).and_return({ eligible: true })
    end

    def decide_promotion(version_id)
      engine.decide(kind: "system.module_promotion_ready", severity: :medium,
                    payload: { "module_version_id" => version_id },
                    fingerprint: "promotion_ready:#{version_id}")
    end

    it "promotes the version to blessed" do
      version = staging_version

      d = decide_promotion(version.id)

      expect(d[:remediation]).to include(applied: true)
      expect(version.reload.promotion_state).to eq("blessed")
    end

    # The approval gate has a TTL, so the version can move between the sensor
    # firing and an operator approving. Re-promoting is not idempotent here —
    # it would be an invalid transition — so the applier must re-check.
    it "refuses when the version has already left staging" do
      version = staging_version
      version.update!(promotion_state: "blessed")

      d = decide_promotion(version.id)

      expect(d[:remediation]).to include(applied: false)
      expect(d[:remediation][:reason]).to match(/staging/i)
    end

    it "refuses a version belonging to another account" do
      other_account = create(:account)
      other_module  = create(:system_node_module, account: other_account)
      foreign = create(:system_node_module_version, node_module: other_module, version_number: 1,
                       promotion_state: "staging",
                       artifacts: { "erofs" => { "oci_digest" => "sha256:#{'b' * 64}", "size" => 9_000_000 } })

      d = decide_promotion(foreign.id)

      expect(d[:remediation]).to include(applied: false)
      expect(foreign.reload.promotion_state).to eq("staging")
    end

    it "refuses when the payload carries no version id" do
      d = engine.decide(kind: "system.module_promotion_ready", severity: :medium,
                        payload: {}, fingerprint: "promotion_ready:none")

      expect(d[:remediation]).to include(applied: false)
    end
  end

  # IMP-4f7f7a0c9d33 — the project.* adaptation lane. SIGNAL_BINDINGS routes
  # system.project_slo_violation / project_drift / project_cost_breach to the
  # project.adapt / project.cost_control gates, but REMEDIATION_APPLIERS had no
  # entry for any of them and AdaptationProposerService#propose_from_signals had
  # ZERO production call sites — so a proceed recorded applied:false, minted a
  # RemediationOutcome nothing could ever settle, and surfaced later as a false
  # fleet.remediation_stuck escalation. Same class as IMP-41eb6ddbc490 /
  # IMP-555e29eeb4ab / IMP-83471cc28e1a.
  #
  # These examples drive engine.decide — the real gate → applier path. The M2
  # adaptive smoke calls AdaptationProposerService DIRECTLY, so a green M2 run
  # only ever proved the proposer works when something calls it, which is
  # precisely what was missing.
  describe "project.* adaptation lane actuates the adaptation proposer" do
    let(:owner) { create(:user, account: account) }

    let(:brief) do
      { "intent" => "3-region web app",
        "scale" => { "initial" => 3, "target" => 5, "growth_profile" => "linear" },
        "regions" => %w[us-east-1 eu-west-1 ap-southeast-1] }
    end

    # ---------------------------------------------------------------------
    # FIXTURE-ONLY EDIT — IMP-02b4bc9f8bd8 (INC-3), 2026-08-12, authorized by
    # the campaign lead. No assertion in this file was changed and no
    # production code in this submodule was touched.
    #
    # Why: INC-3 gave AdaptationProposerService a compose-time precondition —
    # a scale-out is only composed when the mission's own provisioning plan
    # supplies the footprint (template / region / instance type) the scaling
    # skill requires. Without it the composer now declines rather than
    # emitting a step that fails at execution with "missing required input:
    # project_id". These fixtures predate that precondition, so they built
    # missions with no provisioning plan and every composition assertion here
    # went red for a reason unrelated to what it tests.
    #
    # This stamps the plan a real mission always has. The assertions below
    # are unchanged and continue to test the lane, not the fixture.
    #
    # Two further fixture-only edits from the same task, same authorization:
    #
    #   * `"replica_count" => 3` was added to the SLO payloads below.
    #     ProjectSloSensor now stamps the observed fleet size onto every SLO
    #     violation (an SLO payload's `observed` is the breached METRIC, not a
    #     count), and the proposer reads only that — it will not substitute
    #     `brief.scale.initial` for a fleet it cannot see, because a constant
    #     baseline is what made the old proposals ratchet. Hand-built payloads
    #     here predate that field.
    #
    #   * Two account-wide counts in "composes one plan per pass…" were scoped
    #     to adaptation goals/plans. Those were CORRECTED, not relaxed — see
    #     the comments at the assertions themselves.
    #
    # (A note here used to flag the cost_control example as deliberately RED
    # pending INC-4's `remove_replicas`. INC-4 landed and IMP-e68a93c47106
    # wired the composer, so the example was revised to the composed shape.)
    # ---------------------------------------------------------------------
    def build_mission(status: "active")
      m = create(:ai_mission, account: account, created_by: owner,
                 mission_type: "infrastructure",
                 custom_phases: [ { "key" => "adapting", "label" => "Adapting", "order" => 0 } ],
                 configuration: {
                   "brief" => brief,
                   "slo_targets" => { "p99_latency_ms" => 250, "cost_ceiling_usd" => 200.0 },
                   "watch_policies" => { "auto_scale_max_replicas" => 5 }
                 })
      m.update_columns(status: status)
      stamp_provisioning_plan!(m.reload)
    end

    # See the note on #build_mission — the provisioning plan whose provision
    # step names the footprint an adaptation scale-out replicates.
    def stamp_provisioning_plan!(target)
      goal = Ai::AgentGoal.create!(
        account: account, agent: agent, title: "Provision",
        description: "initial provisioning", goal_type: "improvement",
        status: "pending", priority: 3, progress: 0.0,
        success_criteria: {}, metadata: {}
      )
      plan = Ai::GoalPlan.create!(
        account: account, goal: goal, agent: agent, status: "draft",
        version: 1, plan_data: { "kind" => "provisioning" }
      )
      plan.steps.create!(
        step_number: 1, step_type: "provisioning_skill", status: "pending",
        description: "Provision full stack",
        execution_config: {
          "skill" => "provision_full_stack",
          "inputs" => { "template_id" => "tmpl-fixture",
                        "provider_region_id" => "region-fixture",
                        "provider_instance_type_id" => "itype-fixture" },
          "on_failure" => "rollback"
        },
        dependencies: []
      )
      target.update!(configuration: target.configuration.merge(
        "plan" => { "plan_id" => plan.id }
      ))
      target
    end

    let!(:mission) { build_mission }

    before do
      %w[project.adapt project.cost_control].each do |category|
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: category,
                                       policy: "notify_and_proceed", is_active: true)
      end
      # Force the heuristic diff path — the LLM seam is the only stub, matching
      # the M2 smoke. Everything downstream (plan persistence, step composition,
      # approval routing) runs for real.
      allow_any_instance_of(Ai::Provisioning::AdaptationProposerService)
        .to receive(:diff_from_llm).and_return(nil)
    end

    def decide_slo_violation(mission_id: mission.id)
      engine.decide(kind: "system.project_slo_violation", severity: :high,
                    payload: { "mission_id" => mission_id, "metric" => "p99_latency_ms",
                               "observed" => 500.0, "target" => 250, "breach_pct" => 100.0,
                               "replica_count" => 3,
                               "correlation_id" => "project_slo:#{mission_id}:abc123" },
                    fingerprint: "project_slo_violation:#{mission_id}:p99_latency_ms")
    end

    it "persists an adaptation diff plan when the SLO gate proceeds" do
      decision = nil
      expect { decision = decide_slo_violation }.to change { Ai::GoalPlan.count }.by(1)

      expect(decision[:decision]).to eq(:proceed)
      expect(decision[:action_category]).to eq("project.adapt")
      # COMPOSITION is what this example pins. Whether the plan then gets
      # applied is the gate's call and belongs to the dispatch examples — in
      # this context there is no project.scale_horizontal policy, so it is not.
      expect(decision[:remediation]).to include(proposal: true, mission_id: mission.id)

      plan = Ai::GoalPlan.find(decision[:remediation][:plan_id])
      expect(plan.plan_data["kind"]).to eq("adaptation_diff")
      expect(plan.plan_data["change_type"]).to eq("scale_horizontal")
      expect(plan.plan_data["signal_kind"]).to eq("system.project_slo_violation")
      expect(plan.plan_data["mission_id"]).to eq(mission.id)

      expect(plan.steps.count).to eq(1)
      step = plan.steps.in_order.first
      expect(step.step_type).to eq("provisioning_skill")
      expect(step.execution_config["skill"]).to eq("scale_project")
      expect(step.execution_config.dig("inputs", "change_type")).to eq("scale_horizontal")
      # initial=3, breach_pct=100 → +2 → 5
      expect(step.execution_config.dig("inputs", "desired_replica_count")).to eq(5)
      expect(step.execution_config.dig("inputs", "correlation_id")).to eq("project_slo:#{mission.id}:abc123")
    end

    # The sanctioned departure from the mutating appliers: a project.*
    # remediation stops at a PROPOSAL. Nothing scales, relocates or re-shapes
    # storage here — the diff plan is composed and left gated for a decision.
    it "gates the proposal instead of mutating the workload" do
      decision = decide_slo_violation

      # No on-node task is dispatched for this lane — contrast system.module_drift,
      # which queues a sync_modules Task. Adaptation actuates through the
      # mission's live plan, never through the on-node reconcile path.
      expect(System::Task.where(account: account)).to be_empty
      expect(decision[:remediation]).to include(proposal: true)
    end

    # The lane must not stop at composition. Without the dispatch call the plan
    # is a persisted record and the lane dead-ends exactly where it did when it
    # had no applier at all — the defect this task exists to close.
    it "hands the composed plan to the adaptation dispatch consumer" do
      expect_any_instance_of(Ai::Provisioning::AdaptationDispatchService)
        .to receive(:dispatch!).with(hash_including(:plan)).and_call_original

      decision = decide_slo_violation

      expect(decision[:remediation]).to include(proposal: true, plan_id: kind_of(String))
      expect(decision[:remediation][:gate])
        .to be_in(Ai::Provisioning::AdaptationDispatchService::GATE_DISPOSITIONS)
    end

    # The gate resolves policy by CHANGE TYPE — AdaptationGate maps
    # scale_horizontal to `project.scale_horizontal`, not to the `project.adapt`
    # category the SIGNAL binding gates on. An account holding a project.adapt
    # policy but none for project.scale_horizontal therefore takes the gate's
    # :blocked arm on every SLO breach, which returns ROUTED with NO request
    # minted — declared policy_missing, because nothing answered
    # (IMP-7a6c9a70e050).
    #
    # The question this pins is "what would an operator actually see", not "what
    # did the code return": nothing was minted, so nobody owns this plan. It must
    # NOT report applied — the plan wedges in draft, and the validate-arc
    # exemption means F3-11 cannot escalate it either.
    it "reports a gate-refused plan as unapplied, with nothing minted to act on" do
      decision = nil
      expect { decision = decide_slo_violation }
        .not_to change { Ai::ApprovalRequest.where(account: account).count }

      expect(decision[:remediation]).to include(
        applied: false, proposal: true, dispatched: false,
        gate: Ai::Provisioning::AdaptationDispatchService::GATE_ROUTED
      )
      expect(decision[:remediation][:approval_request_id]).to be_nil
      # IMP-7a6c9a70e050: no row exists here, so the reason names the MISSING
      # configuration. It used to say "blocked by policy" — a policy decision
      # nobody had made.
      expect(decision[:remediation][:reason]).to match(/no intervention policy row for project\.scale_horizontal/)
      expect(Ai::GoalPlan.find(decision[:remediation][:plan_id]).status).to eq("draft")
    end

    # A plan the gate routed is dispatched by NOTHING else in the system, so the
    # applier has to re-ask on a later tick — that is the only way an operator's
    # approval ever reaches the runner. Returning early on the in-flight check
    # (as this once did) left an approved adaptation in draft forever.
    it "re-asks the gate for an undispatched plan instead of deduping it away" do
      # Counted across INSTANCES — the applier builds a fresh dispatcher per
      # decision, so an any_instance message expectation cannot see the second.
      dispatch_calls = 0
      allow_any_instance_of(Ai::Provisioning::AdaptationDispatchService)
        .to receive(:dispatch!).and_wrap_original do |original, **kwargs|
          dispatch_calls += 1
          original.call(**kwargs)
        end

      first = decide_slo_violation
      second = nil
      expect {
        second = engine.decide(kind: "system.project_slo_violation", severity: :high,
                               payload: { "mission_id" => mission.id, "metric" => "availability_pct",
                                          "observed" => 98.0, "target" => 99.5, "breach_pct" => 1.5,
                                          "replica_count" => 3 },
                               fingerprint: "project_slo_violation:#{mission.id}:availability_pct")
      }.not_to change { Ai::GoalPlan.count }

      # Same plan re-offered to the gate — the brake still stops a SECOND
      # composition, it just no longer stops the retry.
      expect(second[:remediation][:plan_id]).to eq(first[:remediation][:plan_id])
      expect(dispatch_calls).to eq(2)
    end

    # The loop closing, end to end: policy clears the plan, the consumer appends
    # onto the mission's live plan and dispatches, and the plan leaves `draft` —
    # which is precisely what RELEASES the one-open-proposal brake so the next
    # genuine breach can propose again. Brake and release are one mechanism,
    # which is why this lane could not land before the consumer existed.
    context "when operator policy auto-approves the scale-out" do
      let(:live_plan) { Ai::GoalPlan.find(mission.configuration.dig("plan", "plan_id")) }

      before do
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: "project.scale_horizontal",
                                       policy: "auto_approve", is_active: true)
        # Seam: the runner's enqueue is its own subject with its own specs.
        # Asserting through it would test the runner, not this lane.
        allow_any_instance_of(Ai::Provisioning::SkillCompositionRunner)
          .to receive(:execute_appended!)
          .and_return({ dispatched: 1, already_running: false, runner_id: "runner-1" })
      end

      it "dispatches the adaptation onto the live plan and releases the brake" do
        decision = decide_slo_violation

        expect(decision[:remediation]).to include(
          applied: true, proposal: true, dispatched: true,
          gate: Ai::Provisioning::AdaptationDispatchService::GATE_AUTO_APPLY
        )

        diff_plan = Ai::GoalPlan.find(decision[:remediation][:plan_id])
        expect(diff_plan.status).to eq("executing")

        # The steps landed on the LIVE plan, stamped with their provenance —
        # that plan is what VerificationService walks, so an adaptation run out
        # of the diff plan would be invisible to its own verification.
        appended = live_plan.steps.reload.select do |s|
          s.execution_config["adapted_from_plan_id"].to_s == diff_plan.id
        end
        expect(appended).not_to be_empty
        expect(appended.map(&:step_number)).to all(be > 1)

        # The brake HOLDS through execution — `executing` is in flight, not
        # settled. Releasing at dispatch time was a real defect: the second
        # signal of the same pass would compose a competing scale_project run
        # and append it onto this same live plan.
        expect(described_class.new(autonomy_service: service)
                 .send(:in_flight_adaptation_plan, mission)).to eq(diff_plan)

        # It releases once the plan settles, so a later genuine breach proposes.
        diff_plan.update!(status: "completed")
        expect(described_class.new(autonomy_service: service)
                 .send(:in_flight_adaptation_plan, mission)).to be_nil
      end

      # Finding 3: with auto_approve seeded, the first signal's plan reaches
      # `executing` inside the same pass. If `executing` were treated as settled,
      # the second signal would compose plan B and append a CONCURRENT
      # scale_project run onto the same live plan.
      it "does not append a concurrent second run when a pass carries two signals" do
        slo = { kind: "system.project_slo_violation", severity: :critical,
                payload: { "mission_id" => mission.id, "metric" => "p99_latency_ms",
                           "observed" => 500.0, "target" => 250, "breach_pct" => 100.0,
                           "replica_count" => 3 },
                fingerprint: "project_slo_violation:#{mission.id}:p99_latency_ms" }
        drift = { kind: "system.project_drift", severity: :medium,
                  payload: { "mission_id" => mission.id, "drift_type" => "replica_count",
                             "observed" => 3, "target" => 5 },
                  fingerprint: "project_drift:#{mission.id}:replica_count" }

        decisions = nil
        expect { decisions = engine.decide_all([ slo, drift ]) }
          .to change { Ai::GoalPlan.count }.by(1)

        plan_ids = decisions.map { |d| d[:remediation][:plan_id] }.uniq
        expect(plan_ids.size).to eq(1)

        appended = live_plan.steps.reload.select { |s| s.execution_config["adapted_from_plan_id"].present? }
        expect(appended.map { |s| s.execution_config["adapted_from_plan_id"] }.uniq.size).to eq(1)
      end
    end

    # Was a DECLINE-BY-DESIGN example: `scale_project` offered only additive
    # strategies, so a cost breach had no actuator to bind to. INC-4
    # (IMP-216a6dbc7e32) added `remove_replicas` and IMP-e68a93c47106 wired the
    # composer, so the lane composes now.
    #
    # THE PROPERTY THAT REPLACES IT IS THE ONE THAT MATTERS HERE: the `before`
    # block seeds `project.cost_control => notify_and_proceed`, i.e. an
    # operator policy that WOULD let this lane act unattended. A cost_control
    # plan destroys replicas, so core hands the gate auto_apply_eligible:
    # false, the gate forces its approval arm, and the seeded proceed policy is
    # overridden. If this example ever reports applied/auto-apply, an
    # autonomous system has gained the ability to terminate instances on a
    # notify_and_proceed policy alone.
    it "composes a cost_control plan and holds it for approval despite a proceed policy" do
      decision = nil
      expect {
        decision = engine.decide(kind: "system.project_cost_breach", severity: :high,
                                 payload: { "mission_id" => mission.id, "observed_usd" => 260.0,
                                            "target_usd" => 200.0, "breach_pct" => 30.0,
                                            "correlation_id" => "project_slo:#{mission.id}:cost" },
                                 fingerprint: "project_cost_breach:#{mission.id}")
      }.to change { Ai::GoalPlan.count }.by(1)

      expect(decision[:action_category]).to eq("project.cost_control")
      expect(decision[:remediation]).to include(proposal: true)
      expect(decision[:remediation][:gate])
        .to eq(Ai::Provisioning::AdaptationDispatchService::GATE_ROUTED)

      diff_plan = Ai::GoalPlan.find(decision[:remediation][:plan_id])
      expect(diff_plan.plan_data["change_type"]).to eq("cost_control")
      expect(diff_plan.steps.first.execution_config.dig("inputs", "scaling_strategy"))
        .to eq("remove_replicas")
      # Ground truth: nothing was appended to the mission's LIVE plan, so
      # nothing ran.
      mission_live_plan = Ai::GoalPlan.find(mission.reload.configuration.dig("plan", "plan_id"))
      expect(mission_live_plan.steps.select { |s|
        s.execution_config["adapted_from_plan_id"].present?
      }).to be_empty
    end

    # Also a decline by design: `relocate_workload` declares required inputs the
    # heuristic composer cannot supply, so the bindability guard at the single
    # exit of #build_steps_for drops the step. Missing composers are tracked as
    # offer 019ff49b-a8e5 — do NOT "fix" this by removing the guard.
    it "declines region_count drift while relocate_workload has no composer" do
      decision = nil
      expect {
        decision = engine.decide(kind: "system.project_drift", severity: :medium,
                                 payload: { "mission_id" => mission.id, "drift_type" => "region_count",
                                            "observed" => 2, "target" => 3,
                                            "correlation_id" => "project_slo:#{mission.id}:drift" },
                                 fingerprint: "project_drift:#{mission.id}:region_count")
      }.not_to change { Ai::GoalPlan.count }

      expect(decision[:remediation]).to include(applied: false, proposal: true)
      expect(decision[:remediation][:reason]).to match(/no diff plan composed/)
    end

    # The false-stuck escalation this task exists to remove. A proposal cannot
    # clear its own signal inside SETTLE_WINDOW — the mission keeps breaching
    # until an operator approves the diff plan and it executes — so recording a
    # pending outcome would score INEFFECTIVE on the next tick, and three of
    # those trip STUCK_STREAK_THRESHOLD into a false fleet.remediation_stuck.
    # Ground truth: zero rows, not a returned success.
    it "keeps a proposal remediation out of the validate arc" do
      decision = decide_slo_violation
      # The exemption is keyed on `proposal`, deliberately NOT on `applied` — a
      # policy-blocked or declined proposal is exactly the case that must not be
      # scored, since its signal keeps firing with nothing able to clear it.
      expect(decision[:remediation]).to include(proposal: true)

      signal = System::Fleet::Signal.from_hash(
        kind: "system.project_slo_violation", severity: :high,
        payload: { "mission_id" => mission.id, "replica_count" => 3 },
        fingerprint: "project_slo_violation:#{mission.id}:p99_latency_ms"
      )

      recorded = nil
      expect {
        recorded = System::Fleet::RemediationValidator.new(account: account, agent: agent)
                                                      .record_proceeded!(decisions: [ decision ], signals: [ signal ])
      }.not_to change { System::Fleet::RemediationOutcome.where(account: account).count }

      expect(recorded).to eq(0)
      expect(System::Fleet::RemediationOutcome.find_by(account: account, fingerprint: signal.fingerprint)).to be_nil
      expect(System::Fleet::RemediationOutcome.ineffective_streak(
        account: account, fingerprint: signal.fingerprint
      )).to eq(0)
    end

    # Guard the exemption against over-reach: a MUTATING proceed must still be
    # scored, or the whole validate arc silently stops working.
    it "still records an outcome for a mutating remediation" do
      mutating = { decision: :proceed, signal_kind: "system.module_drift",
                   action_category: "system.module_assign",
                   fingerprint: "module_drift:inst-1",
                   remediation: { applied: true, command: "sync_modules" } }
      signal = System::Fleet::Signal.from_hash(
        kind: "system.module_drift", severity: :medium, payload: {}, fingerprint: "module_drift:inst-1"
      )

      recorded = System::Fleet::RemediationValidator.new(account: account, agent: agent)
                                                    .record_proceeded!(decisions: [ mutating ], signals: [ signal ])

      expect(recorded).to eq(1)
      expect(System::Fleet::RemediationOutcome.find_by(account: account, fingerprint: signal.fingerprint)).to be_present
    end

    # ProjectSloSensor emits up to three signals per mission per tick, and they
    # map to DIFFERENT change_types (slo_violation → scale_horizontal,
    # cost_breach → cost_control). Deciding each in isolation composed one plan
    # PER SIGNAL — "scale to 5" from the latency breach and "scale to 2" from the
    # cost breach, contradictory diffs on the SAME AgentGoal in one pass. The
    # per-mission open-proposal key is what closes this; a (mission, change_type)
    # key would let exactly this pair through.
    it "composes one plan per pass even when a mission breaches on two axes" do
      slo = { kind: "system.project_slo_violation", severity: :critical,
              payload: { "mission_id" => mission.id, "metric" => "p99_latency_ms",
                         "observed" => 500.0, "target" => 250, "breach_pct" => 100.0,
                         "replica_count" => 3 },
              fingerprint: "project_slo_violation:#{mission.id}:p99_latency_ms" }
      cost = { kind: "system.project_cost_breach", severity: :medium,
               payload: { "mission_id" => mission.id, "observed_usd" => 260.0,
                          "target_usd" => 200.0, "breach_pct" => 30.0 },
               fingerprint: "project_cost_breach:#{mission.id}" }

      decisions = nil
      expect { decisions = engine.decide_all([ slo, cost ]) }.to change { Ai::GoalPlan.count }.by(1)

      expect(decisions.map { |d| d[:decision] }).to all(eq(:proceed))
      remediations = decisions.map { |d| d[:remediation] }
      expect(remediations).to all(include(proposal: true))
      # Exactly one plan, and both signals resolve to it — the second finds the
      # in-flight plan rather than composing a competing diff.
      expect(remediations.map { |r| r[:plan_id] }.uniq.size).to eq(1)

      # One goal per mission, not one per signal — intent unchanged, scoped to
      # ADAPTATION goals (IMP-02b4bc9f8bd8, 2026-08-12, lead-authorized).
      # CORRECTED, NOT RELAXED: the account-wide count was a proxy that only
      # held for a mission that had never been provisioned. `Ai::GoalPlan
      # belongs_to :goal` is required, so any genuinely provisioned mission
      # also carries a provisioning goal and the account-wide total is 2 after
      # one adaptation — this example would have been wrong in production.
      # Scoping to kind=adaptation measures exactly what the line above claims.
      expect(
        Ai::AgentGoal.where(account: account)
                     .where("metadata @> ?", { "kind" => "adaptation" }.to_json)
                     .count
      ).to eq(1)

      # No contradictory downscale step was composed alongside the scale-up.
      plan = Ai::GoalPlan.find(remediations.first[:plan_id])
      expect(plan.plan_data["change_type"]).to eq("scale_horizontal")
      expect(plan.steps.in_order.first.execution_config.dig("inputs", "desired_replica_count")).to eq(5)
      # Same correction as the goal count above, same reason (IMP-02b4bc9f8bd8):
      # the mission's own provisioning plan is an Ai::GoalPlan too, so an
      # account-wide total only equalled 1 pre-provisioning. Scoped to the
      # adaptation diff this example is actually about — corrected, not relaxed.
      expect(
        Ai::GoalPlan.where(account: account)
                    .where("plan_data @> ?", { "kind" => "adaptation_diff" }.to_json)
                    .count
      ).to eq(1)
    end

    it "still composes per mission when one pass carries two different missions" do
      other = build_mission
      sig = lambda do |m|
        { kind: "system.project_slo_violation", severity: :high,
          payload: { "mission_id" => m.id, "metric" => "p99_latency_ms", "breach_pct" => 100.0,
                     "replica_count" => 3 },
          fingerprint: "project_slo_violation:#{m.id}:p99_latency_ms" }
      end

      decisions = nil
      expect { decisions = engine.decide_all([ sig.call(mission), sig.call(other) ]) }
        .to change { Ai::GoalPlan.count }.by(2)

      plan_ids = decisions.map { |d| d[:remediation][:plan_id] }
      expect(plan_ids.uniq.size).to eq(2)
      expect(decisions.map { |d| d[:remediation][:mission_id] }).to match_array([ mission.id, other.id ])
    end

    # Mirrors the in-flight guard the reconcile-task lanes already have ("does
    # not duplicate an in-flight reconcile task"). A breaching mission re-fires
    # every dedup TTL, and each metric breaches under its own fingerprint, so
    # without this every pass composed ANOTHER draft plan — and, wherever the
    # governance capability is enabled, another operator approval — for a
    # proposal nobody has decided yet. One condition, an unbounded queue.
    it "does not compose a second proposal while one is still in flight" do
      first = decide_slo_violation
      first_plan_id = first[:remediation][:plan_id]

      second = nil
      expect {
        second = engine.decide(kind: "system.project_slo_violation", severity: :high,
                               payload: { "mission_id" => mission.id, "metric" => "availability_pct",
                                          "observed" => 98.0, "target" => 99.5, "breach_pct" => 1.5,
                                          "replica_count" => 3 },
                               fingerprint: "project_slo_violation:#{mission.id}:availability_pct")
      }.not_to change { Ai::GoalPlan.count }

      expect(second[:decision]).to eq(:proceed)
      # proposal: true is load-bearing — it keeps this decision out of the
      # validate arc too, so an in-flight proposal cannot be scored ineffective.
      expect(second[:remediation]).to include(proposal: true, plan_id: first_plan_id)
    end

    # `approved` and `executing` are IN FLIGHT, not settled — the runner owns the
    # plan and a second composition would append a competing scale_project run
    # onto the same live plan. Only a settled plan releases the brake.
    it "still blocks a second proposal while the plan is approved or executing" do
      first = decide_slo_violation
      plan = Ai::GoalPlan.find(first[:remediation][:plan_id])

      %w[approved executing].each do |status|
        plan.update!(status: status)
        expect {
          engine.decide(kind: "system.project_slo_violation", severity: :high,
                        payload: { "mission_id" => mission.id, "metric" => "availability_pct",
                                   "observed" => 98.0, "target" => 99.5, "breach_pct" => 1.5,
                                   "replica_count" => 3 },
                        fingerprint: "project_slo_violation:#{mission.id}:#{status}")
        }.not_to change { Ai::GoalPlan.count }
      end
    end

    it "composes again once the in-flight proposal has settled" do
      first = decide_slo_violation
      Ai::GoalPlan.find(first[:remediation][:plan_id]).update!(status: "completed")

      second = nil
      expect {
        second = engine.decide(kind: "system.project_slo_violation", severity: :high,
                               payload: { "mission_id" => mission.id, "metric" => "availability_pct",
                                          "observed" => 98.0, "target" => 99.5, "breach_pct" => 1.5,
                                          "replica_count" => 3 },
                               fingerprint: "project_slo_violation:#{mission.id}:availability_pct")
      }.to change { Ai::GoalPlan.count }.by(1)

      expect(second[:remediation]).to include(proposal: true)
    end

    it "does not let another mission's in-flight proposal block this one" do
      other = build_mission
      engine.decide(kind: "system.project_slo_violation", severity: :high,
                    payload: { "mission_id" => other.id, "metric" => "p99_latency_ms", "breach_pct" => 100.0,
                               "replica_count" => 3 },
                    fingerprint: "project_slo_violation:#{other.id}:p99_latency_ms")

      decision = nil
      expect { decision = decide_slo_violation }.to change { Ai::GoalPlan.count }.by(1)
      expect(decision[:remediation]).to include(proposal: true, mission_id: mission.id)
    end

    # THE DEFAULT PATH, not an edge case. The fleet chain runs 4h with
    # timeout_action "reject", so ANY routed adaptation an operator does not
    # answer inside that window is auto-rejected. Nothing moved such a plan out
    # of `draft` — core only transitions on dispatch, and dispatch only happens
    # on AUTO_APPLY — so the brake stayed engaged forever against a condition
    # that was still breaching. The gate owns the approval lifecycle, so it now
    # closes the plan the approval was about.
    context "when the approval for an in-flight proposal is rejected" do
      let(:chain) do
        Ai::ApprovalChain.create!(
          account: account, name: "Fleet Autonomy Actions", trigger_type: "autonomy_action",
          status: "active", is_sequential: true, timeout_action: "reject", timeout_hours: 4,
          steps: [ { "name" => "Operator Approval", "approvers" => [ "*" ], "required_approvals" => 1 } ]
        )
      end

      def reject_request_for!(plan_id, status: "rejected")
        Ai::ApprovalRequest.create!(
          account: account, approval_chain: chain, request_id: SecureRandom.uuid,
          source_type: "system_fleet", source_id: agent.id, status: status,
          description: "adaptation", request_data: { "payload" => { "plan_id" => plan_id } }
        )
      end

      it "closes the proposal and lets the mission propose again" do
        first = decide_slo_violation
        plan_id = first[:remediation][:plan_id]
        reject_request_for!(plan_id)

        # Next tick re-offers the plan to the gate, which sees the rejection.
        second = nil
        expect {
          second = engine.decide(kind: "system.project_slo_violation", severity: :high,
                                 payload: { "mission_id" => mission.id, "metric" => "availability_pct",
                                            "observed" => 98.0, "target" => 99.5, "breach_pct" => 1.5,
                                            "replica_count" => 3 },
                                 fingerprint: "project_slo_violation:#{mission.id}:availability_pct")
        }.not_to change { Ai::GoalPlan.count }

        expect(Ai::GoalPlan.find(plan_id).status).to eq("rejected")
        expect(second[:remediation][:reason]).to match(/rejected/)

        # Brake released — the breach is still live, so a LATER tick composes.
        expect(described_class.new(autonomy_service: service)
                 .send(:in_flight_adaptation_plan, mission)).to be_nil
      end

      it "treats an expired approval as terminal too" do
        first = decide_slo_violation
        plan_id = first[:remediation][:plan_id]
        reject_request_for!(plan_id, status: "expired")

        engine.decide(kind: "system.project_slo_violation", severity: :high,
                      payload: { "mission_id" => mission.id, "metric" => "availability_pct",
                                 "observed" => 98.0, "target" => 99.5, "breach_pct" => 1.5,
                                 "replica_count" => 3 },
                      fingerprint: "project_slo_violation:#{mission.id}:expired")

        expect(Ai::GoalPlan.find(plan_id).status).to eq("rejected")
      end
    end

    # THE ALARM, RESTORED. The validate-arc exemption removed F3-11 as this
    # lane's escalation path, which is only safe because the EXECUTION side now
    # records failures: AdaptationDispatchService#settle! mints an `ineffective`
    # outcome on its unhealthy branch, through this same gate seam. Three of
    # those and the lane escalates like any other.
    #
    # Without that recording, an adaptation that ran and broke on every tick was
    # indistinguishable from one nobody had gotten to — silent, forever.
    it "escalates a repeatedly-failing adaptation once its failures are recorded" do
      fingerprint = "project_slo_violation:#{mission.id}:p99_latency_ms"
      plan = Ai::GoalPlan.create!(
        account: account, goal: Ai::AgentGoal.create!(
          account: account, agent: agent, title: "Adapt", description: "d",
          goal_type: "improvement", status: "pending", priority: 3, progress: 0.0
        ), agent: agent, status: "failed", version: 1,
        plan_data: { "kind" => "adaptation_diff", "change_type" => "scale_horizontal",
                     "mission_id" => mission.id, "signal_kind" => "system.project_slo_violation",
                     "signal_fingerprint" => fingerprint }
      )

      # Three failed adaptations, recorded through the SAME seam settle!'s
      # unhealthy branch calls.
      described_class::STUCK_STREAK_THRESHOLD.times do
        System::AdaptationGate.record_adaptation_outcome!(
          account: account, mission: mission, plan: plan,
          fingerprint: fingerprint, signal_kind: "system.project_slo_violation",
          status: "ineffective"
        )
      end

      expect(System::Fleet::RemediationOutcome.ineffective_streak(account: account, fingerprint: fingerprint))
        .to be >= described_class::STUCK_STREAK_THRESHOLD

      # The breach fires again — and now the lane escalates instead of quietly
      # composing a fourth doomed proposal.
      decision = nil
      expect { decision = decide_slo_violation }
        .to change { System::FleetEvent.where(kind: "fleet.remediation_stuck").count }.by(1)

      expect(decision[:decision]).to eq(:pending)
      expect(decision[:remediation_stuck]).to be true
      expect(decision[:ineffective_streak]).to be >= described_class::STUCK_STREAK_THRESHOLD
    end

    it "records an ineffective outcome for a failed adaptation, not silence" do
      fingerprint = "project_slo_violation:#{mission.id}:failed-run"
      plan = Ai::GoalPlan.create!(
        account: account, goal: Ai::AgentGoal.create!(
          account: account, agent: agent, title: "Adapt", description: "d",
          goal_type: "improvement", status: "pending", priority: 3, progress: 0.0
        ), agent: agent, status: "failed", version: 1,
        plan_data: { "kind" => "adaptation_diff", "change_type" => "scale_horizontal",
                     "mission_id" => mission.id, "signal_kind" => "system.project_slo_violation",
                     "signal_fingerprint" => fingerprint }
      )

      outcome = nil
      expect {
        outcome = System::AdaptationGate.record_adaptation_outcome!(
          account: account, mission: mission, plan: plan,
          fingerprint: fingerprint, signal_kind: "system.project_slo_violation",
          status: "ineffective"
        )
      }.to change { System::Fleet::RemediationOutcome.where(account: account).count }.by(1)

      expect(outcome.status).to eq("ineffective")
      # validated_at must be set or ineffective_streak, which orders by it,
      # sorts this row out of the streak it exists to contribute to.
      expect(outcome.validated_at).to be_present
      expect(System::Fleet::RemediationOutcome.ineffective_streak(
        account: account, fingerprint: fingerprint
      )).to eq(1)
    end

    # A pending row THIS PLAN minted is the same unresolved condition — settle it
    # rather than accumulating a second row for one problem.
    #
    # IMP-fec9abb225c6 (5): this used to say "for the same fingerprint", and the
    # fixture below carried no metadata, so the example asserted that ANY
    # same-fingerprint pending row is settled in place. That is the cross-talk
    # defect itself — the row may belong to another lane, or to a previous
    # still-settling SUCCESSFUL adaptation, and re-labelling it fabricates a data
    # point in the table LEARN reads. The example's intent (one row per
    # condition, no duplicates) is preserved; its fixture now expresses whose
    # row it is.
    it "settles an existing pending outcome it minted instead of duplicating it" do
      fingerprint = "project_slo_violation:#{mission.id}:settling"
      plan = Ai::GoalPlan.create!(
        account: account, goal: Ai::AgentGoal.create!(
          account: account, agent: agent, title: "Adapt", description: "d",
          goal_type: "improvement", status: "pending", priority: 3, progress: 0.0
        ), agent: agent, status: "failed", version: 1,
        plan_data: { "kind" => "adaptation_diff", "change_type" => "scale_horizontal",
                     "mission_id" => mission.id, "signal_fingerprint" => fingerprint }
      )
      now = Time.current
      pending = System::Fleet::RemediationOutcome.create!(
        account: account, signal_kind: "system.project_slo_violation", fingerprint: fingerprint,
        action_category: "project.scale_horizontal", status: "pending",
        acted_at: now, settle_until: now + 90,
        metadata: { "gate" => "adaptation_applied", "plan_id" => plan.id }
      )

      expect {
        System::AdaptationGate.record_adaptation_outcome!(
          account: account, mission: mission, plan: plan,
          fingerprint: fingerprint, signal_kind: "system.project_slo_violation",
          status: "ineffective"
        )
      }.not_to change { System::Fleet::RemediationOutcome.where(account: account).count }

      expect(pending.reload.status).to eq("ineffective")
      expect(pending.validated_at).to be_present
    end

    # IMP-fec9abb225c6 (2) — THE MISLABELLED ALARM.
    #
    # held_with_nothing_to_act_on was INFERRED from (gate == ROUTED &&
    # approval_request_id.nil?). Three different things produce that shape, and
    # only one of them is a policy gap:
    #
    #   * the gate's :blocked arm      — no permitting policy   (a real gap)
    #   * :pending, request nil        — rejected cooldown       (you just said no)
    #   * :pending, request nil        — no chain / request store
    #
    # The hinge is create_pending_approval returning nil while gate_action! still
    # reports decision: :pending. Immediately after an operator REJECTS an
    # adaptation the mission re-proposes, the cooldown suppresses the request,
    # and the lane raised a HIGH-severity event whose payload said "no permitting
    # policy" — sending an operator hunting a configuration gap that does not
    # exist while the truth is that they had just declined it.
    #
    # So the gate now DECLARES its cause (the same discipline core already
    # applies to `authority`) and the engine branches on it, rather than editing
    # a detail string that nothing parses.
    context "when the request is suppressed by the rejection cooldown" do
      let!(:chain) do
        Ai::ApprovalChain.create!(
          account: account, name: "Fleet Autonomy Actions", trigger_type: "autonomy_action",
          status: "active", is_sequential: true, timeout_action: "reject", timeout_hours: 4,
          steps: [ { "name" => "Operator Approval", "approvers" => [ "*" ], "required_approvals" => 1 } ]
        )
      end

      before do
        # The policy PERMITS the category and asks for a human — this is the
        # configuration an operator who hit the high-severity alarm would be
        # told to go and create. It is already here.
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: "project.scale_horizontal",
                                       policy: "require_approval", is_active: true)

        # ...and they already answered. A rejection inside decision_ttl_for
        # (1h for a non-advancement action) is what silences the next mint.
        Ai::ApprovalRequest.create!(
          account: account, approval_chain: chain, request_id: SecureRandom.uuid,
          source_type: "system_fleet", source_id: "project.scale_horizontal",
          status: "rejected", completed_at: 5.minutes.ago,
          description: "adaptation",
          request_data: { "action_category" => "project.scale_horizontal",
                          "payload" => { "mission_id" => mission.id } }
        )
      end

      it "reports the operator's own rejection rather than a phantom policy gap" do
        expect { decide_slo_violation }
          .to change { System::FleetEvent.where(kind: "fleet.adaptation_blocked").count }.by(1)

        event = System::FleetEvent.where(kind: "fleet.adaptation_blocked").last
        expect(event.payload["cause"]).to eq("suppressed_by_rejection_cooldown")
        expect(event.severity).to eq("low"),
                                  "an operator's own rejection is not a high-severity configuration alarm"
        expect(event.payload["detail"].to_s).not_to match(/blocked by policy/)
      end
    end

    # The blocked arm had no reader. applied: false is honest but inert, so the
    # only symptom of a missing policy was a mission that silently never
    # adapted. It has to say so out loud.
    #
    # IMP-7a6c9a70e050 — and it has to say the RIGHT thing. There is no
    # project.scale_horizontal row in this context, so nothing has answered:
    # that is a deploy defect (db:seed is first-boot-only), not a policy
    # decision. It used to arrive as "policy_blocked / blocked by policy",
    # sending an operator to the Autonomy modal to tune a row that does not
    # exist.
    it "raises a fleet event naming the MISSING configuration when no policy row exists" do
      expect { decide_slo_violation }
        .to change { System::FleetEvent.where(kind: "fleet.adaptation_blocked").count }.by(1)

      event = System::FleetEvent.where(kind: "fleet.adaptation_blocked").last
      expect(event.severity).to eq("high")
      expect(event.payload["mission_id"]).to eq(mission.id)
      expect(event.payload["action_category"]).to eq("project.scale_horizontal")
      expect(event.payload["cause"]).to eq("policy_missing")
      expect(event.payload["detail"]).not_to match(/blocked by policy/)
    end

    # THE OTHER DIRECTION, and it is not symmetric decoration: a change that
    # collapsed both cases into policy_missing would report an operator's own
    # decision as a configuration error — the same misdiagnosis inverted. A
    # one-directional oracle passes it.
    it "still reports an operator's explicit block as a policy decision" do
      Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                     action_category: "project.scale_horizontal",
                                     policy: "block", is_active: true)

      expect { decide_slo_violation }
        .to change { System::FleetEvent.where(kind: "fleet.adaptation_blocked").count }.by(1)

      event = System::FleetEvent.where(kind: "fleet.adaptation_blocked").last
      expect(event.severity).to eq("high")
      expect(event.payload["cause"]).to eq("policy_blocked")
      expect(event.payload["detail"]).to match(/blocked by policy/)
    end

    # IMP-fec9abb225c6 (3) — THE UNBOUNDED ALARM.
    #
    # The escalation's comment claimed dedup happened "through the ordinary
    # fleet event path". EventBroadcaster.emit! does none — it create!s a row
    # unconditionally and never reads correlation_id — so the only throttle was
    # the 600s decide cache. The brake is deliberately held, so the SAME plan
    # re-blocks on every tick: ~144 high-severity rows/day for one mission
    # missing one policy.
    it "raises ONE event for a plan that keeps re-blocking, not one per tick" do
      expect {
        decide_slo_violation
        # A second breach on a different fingerprint (the decide cache would
        # swallow a repeat of the first) folds into the SAME still-blocked plan
        # and re-offers it to the gate — the re-block this alarm storms on.
        engine.decide(kind: "system.project_cost_breach", severity: :high,
                      payload: { "mission_id" => mission.id, "observed_usd" => 260.0,
                                 "target_usd" => 200.0, "breach_pct" => 30.0 },
                      fingerprint: "project_cost_breach:#{mission.id}")
      }.to change { System::FleetEvent.where(kind: "fleet.adaptation_blocked").count }.by(1)
    end

    # The dedup gate fails CLOSED, unlike the decide cache it sits next to.
    # A cache we cannot read is not a licence to emit every 60s — failing open
    # here lifts the storm to 1440/day exactly when the platform is already
    # unhealthy enough to have lost its cache.
    it "suppresses the alarm when the dedup cache is broken" do
      allow(Rails.cache).to receive(:exist?).and_raise(Redis::BaseConnectionError.new("no cache"))

      expect { decide_slo_violation }
        .not_to change { System::FleetEvent.where(kind: "fleet.adaptation_blocked").count }
    end

    # An unrelated second breach absorbed by the in-flight plan must not be
    # reported as though that plan addressed it — it gets the scale-out's ids.
    it "names the in-flight plan's change_type when it absorbs a different breach" do
      decide_slo_violation

      cost = engine.decide(kind: "system.project_cost_breach", severity: :high,
                           payload: { "mission_id" => mission.id, "observed_usd" => 260.0,
                                      "target_usd" => 200.0, "breach_pct" => 30.0 },
                           fingerprint: "project_cost_breach:#{mission.id}")

      expect(cost[:remediation][:superseded_by_change_type]).to eq("scale_horizontal")
      expect(cost[:remediation][:folded_into]).to match(/project_cost_breach folded into the in-flight/)
    end

    # IMP-fec9abb225c6 (4) — the fold used to overwrite `reason` unconditionally.
    #
    # `reason` is dispatch_adaptation!'s ONLY statement of why nothing moved; it
    # is present precisely when applied is false. Overwriting it said "folded
    # into the in-flight proposal" for a plan that was itself policy-blocked —
    # indistinguishable from a healthy fold into a plan that IS progressing, and
    # the same ambiguity dispatch_adaptation! documents as a past bug. The fold
    # note now rides its own key so both facts survive.
    it "keeps the blocked plan's own reason when it absorbs a different breach" do
      decide_slo_violation # gate blocks: no project.scale_horizontal policy here

      cost = engine.decide(kind: "system.project_cost_breach", severity: :high,
                           payload: { "mission_id" => mission.id, "observed_usd" => 260.0,
                                      "target_usd" => 200.0, "breach_pct" => 30.0 },
                           fingerprint: "project_cost_breach:#{mission.id}")

      expect(cost[:remediation][:applied]).to be(false),
                                              "fixture drifted — this example needs a plan that did NOT proceed"
      expect(cost[:remediation][:reason]).to match(/no intervention policy row for project\.scale_horizontal/),
                                             "the fold clobbered the only statement of why nothing moved"
      expect(cost[:remediation][:folded_into]).to match(/project_cost_breach folded into the in-flight/)
    end

    # The most dangerous thing this lane could do is create a goal the autonomy
    # scheduler will drive on its own. GoalDrivenSchedulerService only walks
    # ACTIVE goals, and from there it runs draft -> validate -> auto-approve ->
    # execute_step; `can_auto_approve?` fails closed for supervised agents but
    # the `autonomous` tier has an infinite cost threshold. `pending` is the
    # whole reason a sensor-composed adaptation cannot self-execute — and
    # GoalsController#update permits :status, so nothing but this status stands
    # between a UI edit and unattended destructive provisioning.
    it "creates the adaptation goal as pending so the scheduler cannot drive it" do
      decide_slo_violation

      goal = Ai::AgentGoal
               .where(account_id: account.id)
               .where("metadata @> ?", { "kind" => "adaptation" }.to_json)
               .first
      expect(goal).to be_present
      expect(goal.status).to eq("pending")
      # The scheduler's OWN selection query, not the `active` scope — that scope
      # is `%w[pending active paused]`, so it would pass vacuously while the
      # scheduler (which matches status: "active" strictly) is what decides
      # whether this goal gets driven.
      expect(Ai::AgentGoal.where(ai_agent_id: goal.ai_agent_id, status: "active")).to be_empty
    end

    it "refuses a mission belonging to another account" do
      foreign_account = create(:account)
      foreign_owner = create(:user, account: foreign_account)
      foreign = create(:ai_mission, account: foreign_account, created_by: foreign_owner,
                       mission_type: "infrastructure",
                       custom_phases: [ { "key" => "adapting", "label" => "Adapting", "order" => 0 } ],
                       configuration: { "brief" => brief })
      foreign.update_columns(status: "active")

      decision = nil
      expect { decision = decide_slo_violation(mission_id: foreign.id) }
        .not_to change { Ai::GoalPlan.count }
      expect(decision[:remediation]).to include(applied: false)
      expect(decision[:remediation][:reason]).to match(/mission not found/)
    end

    it "refuses when the payload carries no mission id" do
      decision = nil
      expect {
        decision = engine.decide(kind: "system.project_slo_violation", severity: :high,
                                 payload: {}, fingerprint: "project_slo_violation:none")
      }.not_to change { Ai::GoalPlan.count }

      expect(decision[:remediation]).to include(applied: false)
      expect(decision[:remediation][:reason]).to match(/mission not found/)
    end

    # The gate has a TTL, so the mission can finish between the sensor firing
    # and the proceed landing — the same re-check module_promotion_ready makes.
    it "refuses to adapt a mission that has reached a terminal status" do
      mission.update_columns(status: "completed")

      decision = nil
      expect { decision = decide_slo_violation }.not_to change { Ai::GoalPlan.count }
      expect(decision[:remediation]).to include(applied: false)
      expect(decision[:remediation][:reason]).to match(/completed/)
    end

    it "surfaces an unapplied proceed when the proposer composes no diff" do
      allow_any_instance_of(Ai::Provisioning::AdaptationProposerService)
        .to receive(:propose_from_signals).and_return(nil)

      decision = decide_slo_violation

      expect(decision[:decision]).to eq(:proceed)
      expect(decision[:remediation]).to include(applied: false)
      expect(decision[:remediation][:reason]).to match(/no diff plan/)
    end
  end

  # Structural guard against the finding recurring: the whole project.* lane is
  # gated, so every one of its bound kinds needs an applier. Without this, a new
  # project.* binding could re-open the same dead end.
  describe "REMEDIATION_APPLIERS covers the gated project.* lane" do
    it "declares an applier for every binding routed to a project.* action category" do
      project_kinds = described_class::SIGNAL_BINDINGS
                        .select { |_kind, b| b[:action_category].to_s.start_with?("project.") }
                        .keys
      expect(project_kinds).to match_array(
        %w[system.project_slo_violation system.project_drift system.project_cost_breach]
      )

      unwired = project_kinds.reject { |kind| described_class::REMEDIATION_APPLIERS.key?(kind) }
      expect(unwired).to eq([])
    end
  end
end
