# frozen_string_literal: true

require "rails_helper"

# IMP-e2f53e87d090 (APO-2b) — the sense arm for "this instance cannot be
# rebooted back to life".
#
# THE DEFECT
#
# Before this sensor the ONLY "instance is unhealthy" signal was
# system.instance_silent (InstanceStatusSensor: status running/starting +
# stale heartbeat). Three materially different conditions produced that one
# signal, and DecisionEngine's applier #reboot_silent_instance answered all
# three with a provider-side reboot/start:
#
#   * the VM itself is gone — the provider reports terminated/error, so no
#     reboot can revive it;
#   * the host that runs the VM is unreachable — a connection test to that
#     provider actually failed and no usable connection is left, so the reboot
#     cannot even be dispatched;
#   * the platform has ALREADY rebooted it and the validate arc scored those
#     remediations ineffective — re-running the proven-futile action.
#
# Disaster recovery's answer to all three is REPLACE, which needs a distinct
# signal carrying a distinct, operator-tunable policy. This sensor emits it.
#
# WHAT IT DELIBERATELY DOES NOT DO
#
# Absence of provider state is NOT unrecoverable. A missing adapter, a blank
# cloud_instance_id, a failed sync_status read, a provider with no connection
# rows, and connections nobody has tested yet (the `pending` default) are all
# UNKNOWN, and unknown must keep the existing instance_silent lane rather than
# escalate to a replace proposal.
RSpec.describe System::Fleet::Sensors::InstanceUnrecoverableSensor do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:adapter)  { instance_double("System::Providers::BaseProvider") }
  let(:sensor)   { described_class.new(account: account) }

  # Silent by InstanceStatusSensor's own definition: running with a heartbeat
  # older than SILENT_THRESHOLD.
  def silent_instance(cloud_instance_id: "i-#{SecureRandom.hex(4)}")
    inst = create(:system_node_instance, node: node, status: "running",
                                         cloud_instance_id: cloud_instance_id)
    inst.update!(last_heartbeat_at: 30.minutes.ago)
    inst
  end

  def stub_provider_status(status)
    allow(System::Providers::Registry).to receive(:for_instance).and_return(adapter)
    allow(adapter).to receive(:sync_status).and_return(success: true, status: status)
  end

  def record_ineffective!(instance, count)
    count.times do |i|
      System::Fleet::RemediationOutcome.create!(
        account: account, signal_kind: "system.instance_silent",
        fingerprint: "instance_silent:#{instance.id}",
        action_category: "system.instance_reprovision", status: "ineffective",
        acted_at: (count - i + 1).hours.ago, settle_until: (count - i).hours.ago,
        validated_at: (count - i).hours.ago
      )
    end
  end

  describe "#sense — silence alone is never unrecoverable" do
    it "emits nothing for a silent instance whose VM the provider still reports running" do
      silent_instance
      stub_provider_status("running")

      expect(sensor.sense).to be_empty
    end

    # `stopped` is deliberately NOT in TERMINAL_PROVIDER_STATES: `start` is the
    # legal, correct remediation for a stopped VM, and instance_state_drifted
    # already converges the model. Escalating it to a replace would throw away
    # a machine a start would have recovered.
    it "emits nothing when the provider reports the VM merely stopped" do
      silent_instance
      stub_provider_status("stopped")

      expect(sensor.sense).to be_empty
    end

    it "emits nothing for an instance with a fresh heartbeat" do
      inst = silent_instance
      inst.update!(last_heartbeat_at: 10.seconds.ago)
      stub_provider_status("terminated")

      expect(sensor.sense).to be_empty
    end
  end

  describe "#sense — absence of provider state is NOT unrecoverable" do
    it "emits nothing when the instance carries no provider identity" do
      silent_instance(cloud_instance_id: nil)
      allow(System::Providers::Registry).to receive(:for_instance).and_return(adapter)
      allow(adapter).to receive(:sync_status).and_return(success: true, status: "terminated")

      expect(sensor.sense).to be_empty
    end

    it "emits nothing when the provider read fails" do
      silent_instance
      allow(System::Providers::Registry).to receive(:for_instance).and_return(adapter)
      allow(adapter).to receive(:sync_status).and_return(success: false, error: "timeout")

      expect(sensor.sense).to be_empty
    end

    it "emits nothing when no adapter can be resolved at all" do
      silent_instance
      allow(System::Providers::Registry).to receive(:for_instance)
        .and_raise(System::Providers::Registry::UnknownProviderError, "no connection")

      expect(sensor.sense).to be_empty
    end

    it "emits nothing when the provider is configured with NO connection rows (a config gap, not a down host)" do
      silent_instance
      allow(System::Providers::Registry).to receive(:for_instance).and_return(adapter)
      allow(adapter).to receive(:sync_status).and_return(success: false, error: "unconfigured")

      expect(System::ProviderConnection.count).to eq(0)
      expect(sensor.sense).to be_empty
    end
  end

  describe "#sense — the dead VM" do
    %w[terminated error].each do |provider_status|
      it "emits system.instance_unrecoverable when the provider reports #{provider_status}" do
        instance = silent_instance
        stub_provider_status(provider_status)

        sig = sensor.sense.find { |s| s.kind == "system.instance_unrecoverable" }

        expect(sig).not_to be_nil
        expect(sig.severity).to eq(:critical)
        expect(sig.payload["instance_id"]).to eq(instance.id)
        expect(sig.payload["reason"]).to eq("provider_terminal")
        expect(sig.payload["provider_status"]).to eq(provider_status)
        expect(sig.fingerprint).to eq("instance_unrecoverable:#{instance.id}:provider_terminal")
      end
    end
  end

  # "The host is down" is only ever a POSITIVELY OBSERVED failure: a connection
  # test actually failed (status "error") and no usable path is left. Every
  # other shape — untested connections, no connections, a provider that
  # answered — is absence, and absence stays on the reboot lane.
  describe "#sense — the dead host" do
    def unreadable_provider!
      allow(System::Providers::Registry).to receive(:for_instance).and_return(adapter)
      allow(adapter).to receive(:sync_status).and_return(success: false, error: "connection refused")
    end

    it "emits when a connection to that provider failed its test and none is left usable" do
      instance = silent_instance
      create(:system_provider_connection, account: account,
                                          provider: instance.provider_region.provider, status: "error")
      unreadable_provider!

      sig = sensor.sense.find { |s| s.kind == "system.instance_unrecoverable" }

      expect(sig).not_to be_nil
      expect(sig.payload["reason"]).to eq("host_unreachable")
    end

    it "emits nothing while at least one connection to that provider is connected" do
      instance = silent_instance
      create(:system_provider_connection, account: account,
                                          provider: instance.provider_region.provider, status: "error")
      create(:system_provider_connection, account: account,
                                          provider: instance.provider_region.provider, status: "connected")
      unreadable_provider!

      expect(sensor.sense).to be_empty
    end

    # A connection an operator switched OFF is not a usable path out of the
    # error state — Registry#find_connection_for_region filters on status
    # alone, so it still reads "connected" there while nothing can be
    # dispatched through it. Drop `enabled: true` from the predicate and this
    # example goes green wrongly.
    it "does not count a connected-but-DISABLED connection as a usable path" do
      instance = silent_instance
      create(:system_provider_connection, account: account,
                                          provider: instance.provider_region.provider, status: "error")
      create(:system_provider_connection, account: account,
                                          provider: instance.provider_region.provider,
                                          status: "connected", enabled: false)
      unreadable_provider!

      sig = sensor.sense.find { |s| s.kind == "system.instance_unrecoverable" }

      expect(sig).not_to be_nil
      expect(sig.payload["reason"]).to eq("host_unreachable")
    end

    # `pending` is the SCHEMA DEFAULT — a connection nobody has tested yet.
    # Reading "never tested" as "the host is down" would turn a fresh install
    # into a fleet-wide replace proposal.
    it "emits nothing when the only connection is untested (status pending)" do
      instance = silent_instance
      create(:system_provider_connection, account: account,
                                          provider: instance.provider_region.provider, status: "pending")
      unreadable_provider!

      expect(sensor.sense).to be_empty
    end

    # host_unreachable is an INFERENCE about the control path, and a successful
    # provider read disproves it: the adapter answered, so the path is up. A
    # non-terminal answer must not fall through to "the host is down".
    it "emits nothing when the provider ANSWERED with a non-terminal state, whatever the connection rows say" do
      instance = silent_instance
      create(:system_provider_connection, account: account,
                                          provider: instance.provider_region.provider, status: "error")
      stub_provider_status("running")

      expect(sensor.sense).to be_empty
    end
  end

  describe "#sense — the exhausted reboot" do
    it "emits once the validate arc has scored REBOOT_ATTEMPT_THRESHOLD reboots ineffective" do
      instance = silent_instance
      record_ineffective!(instance, described_class::REBOOT_ATTEMPT_THRESHOLD)
      stub_provider_status("running")

      sig = sensor.sense.find { |s| s.kind == "system.instance_unrecoverable" }

      expect(sig).not_to be_nil
      expect(sig.payload["reason"]).to eq("reboot_exhausted")
      expect(sig.payload["ineffective_streak"]).to eq(described_class::REBOOT_ATTEMPT_THRESHOLD)
    end

    it "emits nothing below the threshold" do
      instance = silent_instance
      record_ineffective!(instance, described_class::REBOOT_ATTEMPT_THRESHOLD - 1)
      stub_provider_status("running")

      expect(sensor.sense).to be_empty
    end
  end

  # THE EMIT-ONCE-PER-WINDOW ORACLE. An unrecoverable instance stays
  # unrecoverable — nothing this platform does clears the condition, a person
  # replaces the instance — so a per-tick re-emit would mint one FleetEvent
  # (and one operator-facing decision) every 60s forever. The suppression
  # reads the DURABLE record of the last emission (the FleetEvent the
  # DecisionEngine mints for the signal), so it survives process restarts and
  # needs no sensor-side state.
  describe "emit-once-per-window" do
    def emit_event!(instance, at:)
      System::FleetEvent.create!(
        account: account, kind: "system.instance_unrecoverable", severity: "critical",
        node_instance_id: instance.id, emitted_at: at,
        payload: { "instance_id" => instance.id }
      )
    end

    it "suppresses a second emission inside the window" do
      instance = silent_instance
      stub_provider_status("terminated")
      emit_event!(instance, at: (described_class::EMIT_WINDOW_SECONDS / 2).seconds.ago)

      expect(sensor.sense).to be_empty
    end

    it "emits again once the window has elapsed" do
      instance = silent_instance
      stub_provider_status("terminated")
      emit_event!(instance, at: (described_class::EMIT_WINDOW_SECONDS + 60).seconds.ago)

      expect(sensor.sense.map(&:kind)).to include("system.instance_unrecoverable")
    end

    # The window is per-INSTANCE. A different instance's recent emission must
    # not silence this one — a host failure takes down many instances at once,
    # and that is exactly when each one needs its own replace decision.
    it "does not let one instance's emission suppress another's" do
      other = silent_instance
      instance = silent_instance
      stub_provider_status("terminated")
      emit_event!(other, at: 1.minute.ago)

      ids = sensor.sense.map { |s| s.payload["instance_id"] }
      expect(ids).to include(instance.id)
      expect(ids).not_to include(other.id)
    end
  end

  # THE PRESUMED-DEAD OVERLAP. DecisionEngine#reap_presumed_dead! flips a
  # silent `running` instance to status "error" at 30 minutes — HALF the
  # default emit window. Selecting only running/starting would therefore make
  # the canonical DR case (a VM the provider only settles to `terminated`
  # after the reaper already retired the row) permanently invisible, and would
  # leave the re-emit branch below unreachable in production.
  describe "#sense — instances the presumed-dead reaper already retired" do
    def reap!(instance)
      instance.update!(status: "error")
      System::FleetEvent.create!(
        account: account, kind: "system.instance_presumed_dead", severity: "critical",
        node_instance_id: instance.id, emitted_at: 20.minutes.ago,
        payload: { "instance_id" => instance.id }
      )
    end

    it "still classifies a reaped instance whose provider now reports it terminated" do
      instance = silent_instance
      reap!(instance)
      stub_provider_status("terminated")

      sig = sensor.sense.find { |s| s.kind == "system.instance_unrecoverable" }

      expect(sig).not_to be_nil
      expect(sig.payload["instance_id"]).to eq(instance.id)
      expect(sig.payload["reason"]).to eq("provider_terminal")
    end

    # Only the reaper's OWN rows are re-admitted. A failed provision also sits
    # in status "error" and is a different problem with a different owner —
    # admitting it would widen this lane into "replace anything broken".
    it "ignores an error-status instance the reaper never marked" do
      instance = silent_instance
      instance.update!(status: "error")
      stub_provider_status("terminated")

      expect(sensor.sense).to be_empty
    end
  end

  # THE PER-TICK WINDOW. MAX_PER_TICK bounds the provider reads, so it must
  # bound only work still to be DONE: if the emit-window suppression ran after
  # the limit, the same already-proposed instances would fill the window every
  # tick and the rest of a mass failure would never be classified at all —
  # exactly the starvation IMP-bcadb1ecd52d fixed in InstanceStateDriftSensor.
  describe "MAX_PER_TICK does not starve unclassified instances" do
    it "reaches an instance that shares the tick with MAX_PER_TICK already-proposed ones" do
      stub_const("#{described_class}::MAX_PER_TICK", 1)
      proposed = silent_instance
      fresh    = silent_instance
      stub_provider_status("terminated")

      System::FleetEvent.create!(
        account: account, kind: "system.instance_unrecoverable", severity: "critical",
        node_instance_id: proposed.id, emitted_at: 1.minute.ago,
        payload: { "instance_id" => proposed.id }
      )

      ids = sensor.sense.map { |s| s.payload["instance_id"] }

      expect(ids).to eq([ fresh.id ])
    end

    # The behavioural example above is only as sharp as the tick's random draw,
    # so the structural property is pinned directly too: the emit-window
    # exclusion must live in the RELATION, which is what makes it run before
    # `.limit`. Move it back into the per-row loop and this fails outright.
    it "excludes already-proposed instances from the relation MAX_PER_TICK is applied to" do
      proposed = silent_instance
      fresh    = silent_instance

      System::FleetEvent.create!(
        account: account, kind: "system.instance_unrecoverable", severity: "critical",
        node_instance_id: proposed.id, emitted_at: 1.minute.ago,
        payload: { "instance_id" => proposed.id }
      )

      expect(sensor.send(:candidates).pluck(:id)).to eq([ fresh.id ])
    end
  end

  describe "the lane it feeds" do
    it "is registered in the sensor suite that gates as Fleet Autonomy" do
      expect(System::Fleet::FleetAutonomyService::SENSORS).to include(described_class)
    end

    it "routes to an action_category DISTINCT from the silent-instance reboot lane" do
      binding = System::Fleet::DecisionEngine::SIGNAL_BINDINGS["system.instance_unrecoverable"]
      silent  = System::Fleet::DecisionEngine::SIGNAL_BINDINGS["system.instance_silent"]

      expect(binding).to be_present
      expect(binding[:action_category]).to eq("system.instance_replace")
      expect(binding[:action_category]).not_to eq(silent[:action_category])
    end

    it "is seeded require_approval — a replace is never autonomous" do
      expect(System::Governance::PolicyDeclarations::FLEET_AUTONOMY_POLICIES["system.instance_replace"])
        .to eq("require_approval")
    end

    # The reconciler is what lands the row on an install whose first boot
    # predates this lane: db:seed is first-boot-only, so a declared-but-
    # unreconciled category blocks every signal at the policy_missing gate.
    it "is reconciled onto a RUNNING install by the absence-only reconciler" do
      create(:user, account: account)
      agent = Ai::Agent.resolve_for(account.id, name: "Fleet Autonomy", agent_type: "monitor") ||
              create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy",
                                source_key: "fleet-autonomy")
      expect(agent).to be_present

      System::Governance::PolicyReconciler.new(account: account).reconcile!

      expect(
        Ai::InterventionPolicy.where(account: account, ai_agent_id: agent.id, scope: "agent")
                              .pluck(:action_category)
      ).to include("system.instance_replace")
    end

    # There is no replace ACTUATOR yet, so the lane must be DECLARED
    # non-remediating or the equality oracle in proceed_lane_actuation_spec
    # fails — and, more importantly, a pending RemediationOutcome would score
    # ineffective every settle window and manufacture a false
    # fleet.remediation_stuck for work no code attempted.
    it "is declared non-remediating while no replace applier exists" do
      expect(System::Fleet::DecisionEngine::REMEDIATION_APPLIERS)
        .not_to have_key("system.instance_unrecoverable")
      expect(System::Fleet::RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES)
        .to include("system.instance_replace")
    end
  end
end
