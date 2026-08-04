# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M7.C — DecisionEngine routes signals to skills + actions.
RSpec.describe System::Fleet::DecisionEngine do
  let(:account)  { create(:account) }
  let(:agent)    { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy") }
  let(:service)  { System::Fleet::FleetAutonomyService.new(account: account, agent: agent) }
  let(:engine)   { described_class.new(autonomy_service: service) }

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
          disk_image_oci_ref: "oci-ref",
          disk_image_uki_oci_ref: "uki-ref",
          disk_image_uki_sha256: "sha256:uki"
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

      it "records an unapplied proceed when no applier exists for the kind" do
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: "system.gitops_drift_remediate",
                                       policy: "notify_and_proceed", is_active: true)

        d = engine.decide(kind: "system.gitops.drift_detected", severity: :medium,
                          payload: {},
                          fingerprint: "gitops_drift:repo-1")

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

    # Audit finding F3-07: three sensors existed but were never registered,
    # and their signal kinds had no bindings — even if invoked they would
    # have been discarded as decision :skipped.
    context "F3-07 sensor signal bindings" do
      def policy!(action_category, policy)
        Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                       action_category: action_category,
                                       policy: policy, is_active: true)
      end

      it "routes sdwan_credential_expiring to the key-rotate gate and invokes the peer remediate executor" do
        policy!("system.sdwan_key_rotate", "auto_approve")
        allow_any_instance_of(::System::Ai::Skills::SdwanPeerRemediateExecutor)
          .to receive(:execute).and_return({ success: true, data: { rotated: true } })

        d = engine.decide(kind: "system.sdwan_credential_expiring", severity: :high,
                          payload: { "membership_credential_id" => "mc-1", "peer_id" => "peer-1" },
                          fingerprint: "sdwan_credential_expiring:mc-1")

        expect(d[:action_category]).to eq("system.sdwan_key_rotate")
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
        expect(executor).to receive(:execute).with(peer_id: "peer-1")
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
        expect(executor).to receive(:execute).with(network_id: "net-1")
                                             .and_return({ success: true, data: {} })

        engine.decide(kind: "system.sdwan_hub_unreachable", severity: :critical,
                      payload: { network_id: "net-1" },
                      fingerprint: "sdwan_hub_unreachable:net-1")
      end

      it "invokes SdwanBgpSessionRemediateExecutor with session, peer and neighbor address" do
        executor = instance_double(System::Ai::Skills::SdwanBgpSessionRemediateExecutor)
        allow(System::Ai::Skills::SdwanBgpSessionRemediateExecutor).to receive(:new).and_return(executor)
        expect(executor).to receive(:execute)
          .with(bgp_session_id: "bgp-1", peer_id: "peer-1", neighbor_address: "10.0.0.2")
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
        expect(executor).to receive(:execute).with(virtual_ip_id: "vip-1", dry_run: true)
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
        expect(executor).to receive(:execute).with(instance_id: instance.id)
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
        expect(executor).to receive(:execute).with(action: "cert_rotate", certificate_id: "cert-1")
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
          .with(federation_peer_id: "fp-1", reason: "heartbeat_stale", dry_run: true)
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
        expect(executor).to receive(:execute).with(peer_id: "peer-9", dry_run: true)
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
        expect(d[:remediation]).to include(applied: true, requires_reprovision: false)
        expect(System::NodeModuleAssignment.find_by(node: node, node_module: module_a)).to be_present
        expect(System::Task.find_by(account: account, command: "sync_modules", operable: instance)).to be_present
      end

      it "creates the missing assignment and queues sync_modules for a cloud_init (non-pivot) instance on approval" do
        result = engine.execute_approved!(approved_closure_request)

        expect(result[:applied]).to be true
        expect(result[:requires_reprovision]).to be false
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
        expect(result[:requires_reprovision]).to be true
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
    # AUTHORING a module, which must pass the human R1/R2/R3 reuse gate
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
end
