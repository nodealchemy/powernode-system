# frozen_string_literal: true

require "rails_helper"

# APO-1d — a :proceed lane that actuates NOTHING and is not DECLARED
# non-remediating is a silent no-op that RemediationValidator then scores.
#
# Four lanes were in that state: system.cert_expiring (whose binding cited a
# NodeCertificate#rotate that does not exist), system.gitops.drift_detected,
# system.package_drift_pressure and system.slo_violation. Each proceeded,
# apply_remediation! returned {applied: false, reason: "no applier"},
# record_proceeded! minted a pending outcome anyway, and three ineffective
# settle windows fired a HIGH fleet.remediation_stuck for work no code
# attempted.
#
# The guard is an EQUALITY oracle, not a containment one: the set of routed
# kinds that actuate nothing must EQUAL the set declared non-remediating, so
# neither a new silent lane nor a stale exemption on an actuating lane can
# pass.
RSpec.describe "fleet proceed-lane actuation", type: :service do
  let(:engine_class)    { System::Fleet::DecisionEngine }
  let(:validator_class) { System::Fleet::RemediationValidator }

  describe "equality oracle over SIGNAL_BINDINGS" do
    # A lane ACTUATES when the proceed/approved arm has something to run:
    # a REMEDIATION_APPLIERS entry, or a bound skill whose execution IS the
    # action (system.boot_image_drift is the live example of the latter).
    def actuating?(kind, binding)
      engine_class::REMEDIATION_APPLIERS.key?(kind) || binding[:skill].present?
    end

    # DECLARED, never inferred — by action_category for a whole notify-only
    # category, or by KIND for a lane whose category is shared with actuating
    # kinds (system.module_assign carries module_drift and config_drift, both
    # of which DO actuate, so slo_violation cannot be exempted by category).
    def declared_non_remediating?(kind, binding)
      validator_class::NON_REMEDIATING_SIGNAL_KINDS.include?(kind) ||
        validator_class::NON_REMEDIATING_ACTION_CATEGORIES.include?(binding[:action_category].to_s)
    end

    it "the kinds that actuate nothing are EXACTLY the kinds declared non-remediating" do
      silent   = engine_class::SIGNAL_BINDINGS.reject { |k, b| actuating?(k, b) }.keys.sort
      declared = engine_class::SIGNAL_BINDINGS.select { |k, b| declared_non_remediating?(k, b) }.keys.sort

      # VACUITY FLOOR. `eq` between two empty sets passes, and both go empty
      # together if the binding shape changes under it (a rename of :skill /
      # :action_category makes every lookup nil) or if someone empties the
      # exemption lists while adding appliers. Pin that the oracle is looking
      # at a populated table and that the exempt set is non-empty, so a shape
      # change fails here instead of quietly blessing everything.
      expect(engine_class::SIGNAL_BINDINGS.size).to be >= 40
      expect(silent).not_to be_empty
      expect(silent).to eq(declared)
    end

    # The other half of the actuation picture, PINNED because the applied:false
    # refusal in RemediationValidator#record_proceeded! costs these lanes their
    # outcome rows. They actuate through their SKILL and have no applier, so
    # apply_remediation! answers "no applier" and nothing mints. The validator's
    # comment states the gap; this fixes its membership so a seventh lane has to
    # be a decision rather than an accident.
    it "PINS the skill-actuated, applier-less lanes that reach the proceed arm" do
      # Across ALL the seeded policy hashes, not just FLEET_AUTONOMY_POLICIES:
      # system.module_critical_upgrade_ready is seeded by the CVE responder,
      # and reading one hash would silently score it as "no policy" and drop
      # it from the pin.
      decls    = System::Governance::PolicyDeclarations
      policies = decls.constants.grep(/_POLICIES\z/)
                      .map { |c| decls.const_get(c) }
                      .select { |h| h.is_a?(Hash) }
                      .reduce({}) { |acc, h| acc.merge(h) }
      proceeding = engine_class::SIGNAL_BINDINGS.select do |kind, binding|
        binding[:skill].present? &&
          !engine_class::REMEDIATION_APPLIERS.key?(kind) &&
          %w[auto_approve notify_and_proceed].include?(policies[binding[:action_category].to_s])
      end.keys.sort

      expect(proceeding).to eq(%w[
        system.acme_cert_expiring
        system.federation_peer_liveness
        system.module_critical_upgrade_ready
        system.sdwan_bgp_session_unhealthy
        system.sdwan_credential_expiring
        system.sdwan_peer_drift
      ])
    end

    it "wires the three lanes the operator ruled IMPLEMENT" do
      expect(engine_class::REMEDIATION_APPLIERS).to have_key("system.cert_expiring")
      expect(engine_class::REMEDIATION_APPLIERS).to have_key("system.gitops.drift_detected")
      expect(engine_class::REMEDIATION_APPLIERS).to have_key("system.package_drift_pressure")
    end

    it "declares the two dormant lanes by KIND (their categories are shared)" do
      expect(validator_class::NON_REMEDIATING_SIGNAL_KINDS).to include("system.slo_violation")
      expect(validator_class::NON_REMEDIATING_SIGNAL_KINDS).to include("system.capability_gap")
      # system.module_assign must NOT be blanket-exempted: module_drift and
      # config_drift route there and really do remediate.
      expect(validator_class::NON_REMEDIATING_ACTION_CATEGORIES).not_to include("system.module_assign")
    end
  end

  describe "RemediationValidator#record_proceeded! refuses applied:false" do
    let(:account)   { create(:account) }
    let(:validator) { validator_class.new(account: account) }

    def sig(fp, kind: "system.cert_expiring")
      System::Fleet::Signal.new(kind: kind, severity: :high,
                                payload: { "instance_id" => "i-1" }, fingerprint: fp)
    end

    def decision(fp, remediation:, kind: "system.cert_expiring")
      { decision: :proceed, gate: "notify_and_proceed", signal_kind: kind,
        fingerprint: fp, action_category: "system.cert_rotate",
        remediation: remediation }
    end

    it "mints NOTHING when the applier reported applied:false" do
      d = decision("fp-noop", remediation: { applied: false, reason: "no applier for system.cert_expiring" })

      expect { validator.record_proceeded!(decisions: [ d ], signals: [ sig("fp-noop") ]) }
        .not_to change { System::Fleet::RemediationOutcome.count }
    end

    # The KNOWN CONSERVATIVE GAP, asserted rather than left to be discovered:
    # a skill-actuated lane with no applier looks identical to "no applier at
    # all" from here, so it stops being scored. Same semantics the approved
    # arm's FleetAutonomyService#executed_remediation? has had since
    # IMP-31f1e5f9b365 — the two arms agreeing is the point.
    it "mints NOTHING for a skill-actuated lane whose applier is missing" do
      d = decision("fp-skill", kind: "system.sdwan_peer_drift",
                               remediation: { applied: false, reason: "no applier for system.sdwan_peer_drift" })
      d[:action_category] = "system.sdwan_peer_remediate"
      d[:skill_result]    = { "ok" => true, "peer_id" => "p-1" }

      expect { validator.record_proceeded!(decisions: [ d ], signals: [ sig("fp-skill", kind: "system.sdwan_peer_drift") ]) }
        .not_to change { System::Fleet::RemediationOutcome.count }
    end

    it "still mints for applied:true" do
      d = decision("fp-real", remediation: { applied: true, task_id: "t-1" })

      expect { validator.record_proceeded!(decisions: [ d ], signals: [ sig("fp-real") ]) }
        .to change { System::Fleet::RemediationOutcome.pending.count }.by(1)
    end

    # applied:false + a DECLARED convergence_deferred is still an execution —
    # #validate_due! settles that row `inconclusive` and an operator reads it.
    # Dropping it here would silently diverge from the approved lane's
    # FleetAutonomyService#executed_remediation?, which keeps it.
    it "still mints for a DECLARED convergence_deferred (applied:false)" do
      d = decision("fp-deferred", remediation: { applied: false, convergence_deferred: true,
                                                 reason: "module needs a reboot" })

      expect { validator.record_proceeded!(decisions: [ d ], signals: [ sig("fp-deferred") ]) }
        .to change { System::Fleet::RemediationOutcome.pending.count }.by(1)
      expect(System::Fleet::RemediationOutcome.last.metadata["convergence_deferred"]).to be true
    end

    it "still mints when the decision carries no remediation hash at all" do
      d = { decision: :proceed, gate: "notify_and_proceed", signal_kind: "system.cert_expiring",
            fingerprint: "fp-bare", action_category: "system.cert_rotate" }

      expect { validator.record_proceeded!(decisions: [ d ], signals: [ sig("fp-bare") ]) }
        .to change { System::Fleet::RemediationOutcome.pending.count }.by(1)
    end
  end

  describe "no false 'still actuate' prose survives" do
    root = File.expand_path("../../../..", __dir__)

    {
      "app/services/system/fleet/remediation_validator.rb" => /still actuate/i,
      "app/services/system/governance/policy_declarations.rb" => /still actuate/i,
      "app/services/system/fleet/decision_engine.rb" => /act through services outside this engine/i
    }.each do |rel, pattern|
      it "#{rel} no longer claims the skill-less lanes actuate elsewhere" do
        expect(File.read(File.join(root, rel))).not_to match(pattern)
      end
    end

    it "the runbook generator no longer promises FleetAutonomyService auto-rotation" do
      body = File.read(File.join(root, "app/services/system/ai/skills/runbook_generate_executor.rb"))
      expect(body).not_to match(/auto-rotates at 75% lifetime/i)
    end

    # Swept over the WHOLE tree, not just the binding: the claim had FOUR
    # copies (decision_engine's binding comment and its capability_gap note,
    # remediation_validator, and CertExpirySensor's routing table — the last
    # of which was in none of the files the finding named). A per-file guard
    # would have let the sensor's copy survive the correction.
    it "no source file cites a NodeCertificate rotate method, because none exists" do
      offenders = Dir.glob(File.join(root, "app/**/*.rb")).select do |path|
        File.read(path).include?("NodeCertificate#rotate")
      end

      expect(offenders).to be_empty
      expect(System::NodeCertificate.instance_methods).not_to include(:rotate)
      expect(System::NodeCertificate.instance_methods).not_to include(:rotate!)
    end
  end

  describe "the cert_expiring applier" do
    let(:account)  { create(:account) }
    let(:agent)    { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy") }
    let(:service)  { System::Fleet::FleetAutonomyService.new(account: account, agent: agent) }
    let(:engine)   { engine_class.new(autonomy_service: service) }
    let(:platform) { create(:system_node_platform, account: account) }
    let(:template) { create(:system_node_template, account: account, node_platform: platform) }
    let(:node)     { create(:system_node, account: account, node_template: template) }
    let(:instance) { create(:system_node_instance, :running, node: node) }

    def cert_signal(cert)
      System::Fleet::Signal.new(
        kind: "system.cert_expiring", severity: :high,
        payload: { "certificate_id" => cert.id, "instance_id" => instance.id },
        fingerprint: "cert_expiring:#{cert.id}"
      )
    end

    it "revokes an expiring cert the agent's rotator has already superseded" do
      old = create(:system_node_certificate, account: account, node_instance: instance,
                                             not_before: 89.days.ago, not_after: 1.day.from_now)
      create(:system_node_certificate, account: account, node_instance: instance,
                                       not_before: 1.hour.ago, not_after: 90.days.from_now)

      result = engine.send(:apply_remediation!, cert_signal(old), nil)

      expect(result[:applied]).to be true
      expect(old.reload).to be_revoked
    end

    it "does NOT revoke the instance's only live cert (the node still holds its key)" do
      only = create(:system_node_certificate, account: account, node_instance: instance,
                                              not_before: 89.days.ago, not_after: 1.day.from_now)

      result = engine.send(:apply_remediation!, cert_signal(only), nil)

      expect(result[:applied]).to be false
      expect(result[:reason]).to match(/csr|agent|cannot/i)
      expect(only.reload).not_to be_revoked
    end
  end

  describe "the gitops drift applier" do
    let(:account) { create(:account) }
    let(:agent)   { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy") }
    let(:service) { System::Fleet::FleetAutonomyService.new(account: account, agent: agent) }
    let(:engine)  { engine_class.new(autonomy_service: service) }
    let(:repo)    { create(:system_gitops_repository, account: account) }

    def drift_signal
      System::Fleet::Signal.new(
        kind: "system.gitops.drift_detected", severity: :medium,
        payload: { "repository_id" => repo.id, "synced_revision" => "abc123" },
        fingerprint: "gitops_drift:#{repo.id}:abc123"
      )
    end

    let(:operator) { create(:user, account: account) }

    def proposal(status:, reviewed_by: nil)
      Ai::AgentProposal.create!(
        account: account, ai_agent_id: agent.id,
        title: "GitOps: create template web", description: "d",
        proposal_type: "configuration", status: status, priority: "medium",
        reviewed_by: reviewed_by, reviewed_at: (Time.current if reviewed_by),
        proposed_changes: { "diff" => { "kind" => "template", "change" => "create", "name" => "web" },
                            "source" => "gitops", "repository_id" => repo.id }
      )
    end

    it "applies operator-APPROVED gitops proposals through Gitops::ApplyService" do
      approved = proposal(status: "approved", reviewed_by: operator)
      allow(System::Gitops::ApplyService).to receive(:apply!).and_return(
        System::Gitops::ApplyService::Result.new(ok?: true, applied_action: "create", resource_id: "r-1")
      )

      result = engine.send(:apply_remediation!, drift_signal, nil)

      expect(System::Gitops::ApplyService).to have_received(:apply!).with(proposal: approved)
      expect(result[:applied]).to be true
      expect(result[:applied_proposal_ids]).to eq([ approved.id ])
    end

    # Reconciler#auto_apply_proposal MACHINE-approves (status "approved",
    # reviewed_by nil) and reverts to pending_review on failure INSIDE a
    # rescue — so a failed revert leaves an approved-looking row. Filtering on
    # status alone would let this lane re-apply it unattended, outside the
    # repository's auto_apply opt-in and the destroy guard. reviewed_by_id is
    # the discriminator.
    it "ignores a MACHINE-approved proposal (gitops auto-apply, no human reviewer)" do
      machine = proposal(status: "approved")
      machine.update!(reviewed_by_id: nil, reviewed_at: Time.current,
                      impact_assessment: { "approved_by" => "gitops_auto_apply", "auto_applied" => true })
      allow(System::Gitops::ApplyService).to receive(:apply!)

      result = engine.send(:apply_remediation!, drift_signal, nil)

      expect(System::Gitops::ApplyService).not_to have_received(:apply!)
      expect(result[:applied]).to be false
      expect(result[:reason]).to match(/human-reviewed/i)
    end

    it "never auto-approves a proposal still pending operator review" do
      pending_p = proposal(status: "pending_review")
      allow(System::Gitops::ApplyService).to receive(:apply!)

      result = engine.send(:apply_remediation!, drift_signal, nil)

      expect(System::Gitops::ApplyService).not_to have_received(:apply!)
      expect(result[:applied]).to be false
      expect(pending_p.reload.status).to eq("pending_review")
    end
  end

  describe "the package drift applier" do
    let(:account) { create(:account) }
    let(:agent)   { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy") }
    let(:service) { System::Fleet::FleetAutonomyService.new(account: account, agent: agent) }
    let(:engine)  { engine_class.new(autonomy_service: service) }
    let(:repo)    { create(:system_package_repository, account: account) }

    def pkg_signal
      System::Fleet::Signal.new(
        kind: "system.package_drift_pressure", severity: :medium,
        payload: { "package_repository_id" => repo.id, "package_name" => "curl" },
        fingerprint: "pkg_drift:l-1:8.5.0"
      )
    end

    it "enqueues an async repository sync (never the inline .call)" do
      allow(System::PackageRepositorySyncService).to receive(:enqueue!).and_return(true)
      allow(System::PackageRepositorySyncService).to receive(:call)

      result = engine.send(:apply_remediation!, pkg_signal, nil)

      expect(System::PackageRepositorySyncService).to have_received(:enqueue!).with(repository: repo)
      expect(System::PackageRepositorySyncService).not_to have_received(:call)
      expect(result[:applied]).to be true
    end

    it "reports applied:false when the repository is disabled" do
      repo.update!(enabled: false)
      allow(System::PackageRepositorySyncService).to receive(:enqueue!)

      result = engine.send(:apply_remediation!, pkg_signal, nil)

      expect(System::PackageRepositorySyncService).not_to have_received(:enqueue!)
      expect(result[:applied]).to be false
    end
  end
end
