# frozen_string_literal: true

require "rails_helper"

# Self-improvement Phase 0 — the validate step: record PROCEEDED remediations,
# then score them against a later sense pass (fingerprint cleared => effective).
RSpec.describe System::Fleet::RemediationValidator, type: :service do
  let(:account) { create(:account) }
  let(:validator) { described_class.new(account: account) }

  def sig(fingerprint, kind: "system.cert_expiring", payload: { "instance_id" => "i-1" })
    System::Fleet::Signal.new(kind: kind, severity: :high, payload: payload, fingerprint: fingerprint)
  end

  def proceeded(fingerprint, kind: "system.cert_expiring")
    { decision: :proceed, gate: "notify_and_proceed", signal_kind: kind,
      fingerprint: fingerprint, action_category: "system.cert_rotate" }
  end

  describe "#record_proceeded!" do
    it "records one pending outcome per PROCEEDED decision (not pending/blocked), keyed by fingerprint" do
      signals = [ sig("fp-1"), sig("fp-2") ]
      decisions = [ proceeded("fp-1"), { decision: :pending, signal_kind: "x", fingerprint: "fp-2" } ]

      expect { validator.record_proceeded!(decisions: decisions, signals: signals) }
        .to change { System::Fleet::RemediationOutcome.pending.count }.by(1)

      o = System::Fleet::RemediationOutcome.pending.last
      expect(o.fingerprint).to eq("fp-1")
      expect(o.signal_kind).to eq("system.cert_expiring")
      expect(o.action_category).to eq("system.cert_rotate")
      expect(o.resource_ref).to eq("i-1")
      expect(o.settle_until).to be > o.acted_at
    end

    it "does not duplicate a pending outcome for the same fingerprint (same unresolved problem)" do
      validator.record_proceeded!(decisions: [ proceeded("fp-1") ], signals: [ sig("fp-1") ])
      expect { validator.record_proceeded!(decisions: [ proceeded("fp-1") ], signals: [ sig("fp-1") ]) }
        .not_to change { System::Fleet::RemediationOutcome.pending.count }
    end
  end

  describe "#validate_due!" do
    let!(:outcome) do
      System::Fleet::RemediationOutcome.create!(
        account: account, signal_kind: "system.cert_expiring", fingerprint: "fp-1",
        status: "pending", acted_at: 5.minutes.ago, settle_until: 4.minutes.ago
      )
    end

    it "marks EFFECTIVE when the fingerprint cleared from the live signals" do
      result = validator.validate_due!(current_signals: [ sig("fp-OTHER") ])
      expect(result[:effective]).to eq(1)
      expect(outcome.reload.status).to eq("effective")
      expect(outcome.effectiveness_score).to eq(1.0)
      expect(outcome.validated_at).to be_present
    end

    it "marks INEFFECTIVE when the fingerprint still fires (remediation didn't stick)" do
      result = validator.validate_due!(current_signals: [ sig("fp-1") ])
      expect(result[:ineffective]).to eq(1)
      expect(outcome.reload.status).to eq("ineffective")
      expect(outcome.effectiveness_score).to eq(0.0)
    end

    it "ignores outcomes whose settle window has not elapsed" do
      outcome.update!(settle_until: 5.minutes.from_now)
      validator.validate_due!(current_signals: [])
      expect(outcome.reload.status).to eq("pending")
    end

    # Audit F3-11(a) — absence-as-effective was fooled by sensor crashes:
    # collect_signals rescues per-sensor failures, so a sensor that crashed on
    # the validation tick removed all its signals from the pass and every one
    # of its pending outcomes was falsely scored "effective". Scoring absence
    # as evidence now requires the OWNING sensor to have run this tick.
    context "sensor-failure guard (F3-11)" do
      before { outcome.update!(metadata: { "sensor" => "CertExpirySensor" }) }

      it "leaves an outcome pending when its owning sensor failed this tick" do
        result = validator.validate_due!(current_signals: [],
                                         failed_sensors: %w[CertExpirySensor])
        expect(result[:effective]).to eq(0)
        expect(outcome.reload.status).to eq("pending")
      end

      it "scores effective when other sensors failed but the owning sensor ran" do
        result = validator.validate_due!(current_signals: [],
                                         failed_sensors: %w[ModuleDriftSensor])
        expect(result[:effective]).to eq(1)
        expect(outcome.reload.status).to eq("effective")
      end

      it "is conservative for legacy outcomes with no sensor tag when any sensor failed" do
        outcome.update!(metadata: {})
        validator.validate_due!(current_signals: [], failed_sensors: %w[ModuleDriftSensor])
        expect(outcome.reload.status).to eq("pending")
      end

      it "still scores ineffective from a live fingerprint regardless of failures" do
        result = validator.validate_due!(current_signals: [ sig("fp-1") ],
                                         failed_sensors: %w[ModuleDriftSensor])
        expect(result[:ineffective]).to eq(1)
        expect(outcome.reload.status).to eq("ineffective")
      end
    end
  end

  # F3-11(a) — the sensor-failure guard needs to know which sensor owns each
  # outcome. BaseSensor#signal tags every signal payload with its producing
  # sensor; record_proceeded! persists that tag onto the outcome.
  describe "sensor provenance" do
    it "BaseSensor#signal tags the payload with the producing sensor" do
      sensor = System::Fleet::Sensors::InstanceStatusSensor.new(account: account)
      s = sensor.send(:signal, kind: "system.instance_silent", severity: :high,
                      payload: { "instance_id" => "i-1" }, fingerprint: "x:1")
      expect(s.payload["_sensor"]).to eq("InstanceStatusSensor")
    end

    it "record_proceeded! persists the sensor tag onto the outcome" do
      tagged = sig("fp-9", payload: { "instance_id" => "i-1", "_sensor" => "CertExpirySensor" })
      validator.record_proceeded!(decisions: [ proceeded("fp-9") ], signals: [ tagged ])

      o = System::Fleet::RemediationOutcome.pending.find_by(fingerprint: "fp-9")
      expect(o.metadata["sensor"]).to eq("CertExpirySensor")
    end
  end

  # Campaign 019f505f — boot-image drift detection (increment 1 observation-only).
  # Observation signals (action_category: "system.observation") carry no remediation
  # to validate — they exist to surface state to dashboards/serializers/MCP only.
  # Recording a pending outcome for a persistent observation would score "ineffective"
  # forever and manufacture false fleet.remediation_stuck escalations. Skip them.
  describe "observation-only signal skipping (F3-11 prevention)" do
    it "skips PROCEEDED decisions with action_category 'system.observation'" do
      observation_decision = {
        decision: :proceed, gate: "notify_only", signal_kind: "system.boot_image_drift",
        fingerprint: "boot_image_drift:i-1", action_category: "system.observation"
      }
      signals = [ sig("boot_image_drift:i-1", kind: "system.boot_image_drift") ]

      expect { validator.record_proceeded!(decisions: [ observation_decision ], signals: signals) }
        .not_to change { System::Fleet::RemediationOutcome.count }
    end

    it "still records PROCEEDED decisions with other action_categories" do
      normal_decision = {
        decision: :proceed, gate: "approve_and_proceed", signal_kind: "system.cert_expiring",
        fingerprint: "cert-1", action_category: "system.cert_rotate"
      }
      signals = [ sig("cert-1", kind: "system.cert_expiring") ]

      expect { validator.record_proceeded!(decisions: [ normal_decision ], signals: signals) }
        .to change { System::Fleet::RemediationOutcome.pending.count }.by(1)
    end

    # IMP-c7d663f24a0b — same exemption class, second member. The
    # SdwanServiceHealthSensor lane proceeds at notify level with no skill and
    # no REMEDIATION_APPLIERS entry: nothing is actuated, and the triggering
    # condition (a service that stopped serving) clears only when a person
    # fixes the workload — never inside the 90s SETTLE_WINDOW. Scoring it
    # would mark it ineffective every window until STUCK_STREAK_THRESHOLD
    # manufactured a false fleet.remediation_stuck HIGH escalation, ~30 min
    # after any service went quiet, for a lane that never acted.
    it "skips PROCEEDED decisions with a declared non-remediating action_category" do
      investigate_decision = {
        decision: :proceed, gate: "notify_and_proceed", signal_kind: "system.sdwan_service_silent",
        fingerprint: "sdwan_service_silent:svc-1",
        action_category: "system.sdwan_service_health_investigate"
      }
      signals = [ sig("sdwan_service_silent:svc-1", kind: "system.sdwan_service_silent") ]

      expect { validator.record_proceeded!(decisions: [ investigate_decision ], signals: signals) }
        .not_to change { System::Fleet::RemediationOutcome.count }
    end

    # The list is DECLARED, not derived — a category that merely looks
    # notify-shaped must still be scored, or a real remediation silently
    # stops being validated.
    it "still records a notify_and_proceed decision whose category is not declared" do
      undeclared = {
        decision: :proceed, gate: "notify_and_proceed", signal_kind: "system.sdwan_peer_drift",
        fingerprint: "peer-1", action_category: "system.sdwan_peer_remediate"
      }
      signals = [ sig("peer-1", kind: "system.sdwan_peer_drift") ]

      expect { validator.record_proceeded!(decisions: [ undeclared ], signals: signals) }
        .to change { System::Fleet::RemediationOutcome.pending.count }.by(1)
    end

    it "mixes observation and normal decisions correctly" do
      observation = {
        decision: :proceed, fingerprint: "boot:i-1", signal_kind: "system.boot_image_drift",
        action_category: "system.observation"
      }
      normal = {
        decision: :proceed, fingerprint: "config:i-1", signal_kind: "system.config_drift",
        action_category: "system.config_update"
      }
      signals = [
        sig("boot:i-1", kind: "system.boot_image_drift"),
        sig("config:i-1", kind: "system.config_drift")
      ]

      expect { validator.record_proceeded!(decisions: [ observation, normal ], signals: signals) }
        .to change { System::Fleet::RemediationOutcome.pending.count }.by(1)

      # Only the normal decision should create an outcome
      expect(System::Fleet::RemediationOutcome.pending.pluck(:fingerprint)).to eq([ "config:i-1" ])
    end
  end
end
