# frozen_string_literal: true

require "rails_helper"

# HIER-P2A — the reconciler MOVES a row whose declared owner changed; it does
# not duplicate it.
#
# When a declared key moves from agent A's set to agent B's (the 14 sdwan
# remediation rows to SDWAN Manager, system.gitops_drift_remediate to GitOps
# Reconciler, system.disk_image_publication_investigate to Disk Image Manager),
# an established install still carries the row on A — possibly with an
# operator-tuned verb, possibly deactivated. Absence-only reconciling would
# create a fresh default row on B and leave the tuned one stale on A: the
# operator's intent lost on the agent that now decides, and a decoy left on
# the agent that no longer does. So the row is RE-HOMED: ai_agent_id updated
# in place, everything else preserved, an audit row written.
#
# On ops-hub the live Fleet Autonomy set is the migration path for this
# reconciler run at deploy, so every example here is also an idempotency
# claim.
RSpec.describe System::Governance::PolicyReconciler, "owner re-homing" do
  let(:account) { create(:account) }
  subject(:reconciler) { described_class.new(account: account, logger: Logger.new(IO::NULL)) }

  let!(:fleet) do
    create(:ai_agent, account: account, name: "Fleet Autonomy", agent_type: "monitor",
                      source_key: "fleet-autonomy")
  end
  let!(:sdwan) do
    create(:ai_agent, account: account, name: "SDWAN Manager", agent_type: "monitor",
                      source_key: "sdwan-manager")
  end

  # A key that MOVED: declared on Fleet Autonomy until HIER-P2A, on SDWAN
  # Manager since.
  let(:moved) { "system.sdwan_peer_remediate" }

  def row(agent, category)
    Ai::InterventionPolicy.find_by(account: account, scope: "agent", ai_agent_id: agent.id,
                                   action_category: category)
  end

  def legacy_row!(category, policy: "notify_and_proceed", is_active: true, priority: 10,
                  conditions: { "trust_tier_minimum" => "monitored" })
    Ai::InterventionPolicy.create!(
      account: account, scope: "agent", ai_agent_id: fleet.id, user_id: nil,
      action_category: category, policy: policy, priority: priority, is_active: is_active,
      conditions: conditions, preferred_channels: %w[notification]
    )
  end

  it "pins the moved key as declared on SDWAN Manager and not on Fleet Autonomy" do
    expect(System::Governance::PolicyDeclarations.owner_of(moved)).to eq("sdwan-manager")
    expect(System::Governance::PolicyDeclarations::FLEET_AUTONOMY_POLICIES).not_to have_key(moved)
  end

  context "on first boot (no rows)" do
    it "creates the moved key on its new owner and nothing on the old one" do
      result = reconciler.reconcile!

      expect(row(sdwan, moved)).to be_present
      expect(row(sdwan, moved).policy).to eq("notify_and_proceed")
      expect(row(fleet, moved)).to be_nil
      expect(result.rehomed).to be_empty
      expect(result.created_categories).to include("sdwan-manager/#{moved}")
    end
  end

  context "on an already-booted install with an operator-tuned row on the old owner" do
    let!(:tuned) { legacy_row!(moved, policy: "require_approval", priority: 42, conditions: { "trust_tier_minimum" => "trusted" }) }

    it "re-homes the row in place — same id, verb, priority and conditions; nothing left on the old owner" do
      result = reconciler.reconcile!

      expect(tuned.reload.ai_agent_id).to eq(sdwan.id)
      expect(tuned.policy).to eq("require_approval")
      expect(tuned.priority).to eq(42)
      expect(tuned.conditions).to eq("trust_tier_minimum" => "trusted")
      expect(tuned.is_active).to be(true)
      expect(row(fleet, moved)).to be_nil
      expect(Ai::InterventionPolicy.where(account: account, action_category: moved).count).to eq(1)

      # The operator-facing line must name the agent the row moved FROM. It is
      # the only record of the migration in the deploy log, and the name has to
      # be captured BEFORE the update — reading it off the row afterwards
      # resolves the NEW foreign key and reports the destination as the source.
      expect(result.rehomed).to include(
        a_string_matching(%r{sdwan-manager/#{Regexp.escape(moved)} \(from Fleet Autonomy\)})
      )
      expect(result.created_categories).not_to include("sdwan-manager/#{moved}")
      expect(result).to be_changed
    end

    it "writes an audit row naming the old and new owner" do
      expect { reconciler.reconcile! }.to change(AuditLog, :count).by_at_least(1)

      audit = AuditLog.where(account: account, resource_type: "Ai::InterventionPolicy",
                             resource_id: tuned.id).last
      expect(audit).to be_present
      expect(audit.action).to eq(described_class::REHOME_AUDIT_ACTION)
      expect(audit.old_values).to include("ai_agent_id" => fleet.id, "agent_key" => "fleet-autonomy")
      expect(audit.new_values).to include("ai_agent_id" => sdwan.id, "agent_key" => "sdwan-manager")
      expect(audit.metadata).to include("action_category" => moved, "set_key" => "sdwan-manager")
    end

    it "is idempotent — a second run re-homes and creates nothing" do
      reconciler.reconcile!
      again = described_class.new(account: account, logger: Logger.new(IO::NULL)).reconcile!

      expect(again.rehomed).to be_empty
      expect(again.created_categories).not_to include(a_string_matching(/#{Regexp.escape(moved)}/))
      expect(tuned.reload.ai_agent_id).to eq(sdwan.id)
    end

    it "names the re-homable row in the drift report before the run, and not after" do
      before = reconciler.drift
      pending = before.rehomable
      expect(pending.map(&:to_s)).to include(a_string_matching(%r{sdwan-manager/#{Regexp.escape(moved)}.*re-home from Fleet Autonomy}))
      expect(before).to be_drifted

      reconciler.reconcile!
      after = described_class.new(account: account, logger: Logger.new(IO::NULL)).drift
      expect(after.rehomable).to be_empty
      expect(after.missing.map(&:to_s)).not_to include(a_string_matching(/#{Regexp.escape(moved)}/))
    end
  end

  context "with a row an operator DEACTIVATED on the old owner" do
    let!(:off) { legacy_row!(moved, is_active: false) }

    it "re-homes it and leaves it inactive on the new owner" do
      reconciler.reconcile!

      expect(off.reload.ai_agent_id).to eq(sdwan.id)
      expect(off.is_active).to be(false)
      expect(Ai::InterventionPolicy.where(account: account, action_category: moved).count).to eq(1)
    end
  end

  context "boundaries" do
    it "does NOT touch a row on the old owner for a key that owner STILL declares" do
      keeps = legacy_row!("system.cert_rotate", policy: "block")

      reconciler.reconcile!

      expect(keeps.reload.ai_agent_id).to eq(fleet.id)
      expect(keeps.policy).to eq("block")
    end

    it "does NOT re-home a row that sits on an agent the declarations do not know" do
      foreign = create(:ai_agent, account: account, name: "Operator's Own Agent", agent_type: "monitor")
      theirs = Ai::InterventionPolicy.create!(
        account: account, scope: "agent", ai_agent_id: foreign.id, user_id: nil,
        action_category: moved, policy: "block", priority: 10, is_active: true,
        conditions: {}, preferred_channels: %w[notification]
      )

      reconciler.reconcile!

      expect(theirs.reload.ai_agent_id).to eq(foreign.id)
      expect(row(sdwan, moved)).to be_present # created fresh, the foreign row is not a former owner's
    end

    it "does not re-home when the new owner already has its own row (the old one is left for the operator)" do
      legacy = legacy_row!(moved, policy: "block")
      own = Ai::InterventionPolicy.create!(
        account: account, scope: "agent", ai_agent_id: sdwan.id, user_id: nil,
        action_category: moved, policy: "auto_approve", priority: 10, is_active: true,
        conditions: {}, preferred_channels: %w[notification]
      )

      result = reconciler.reconcile!

      expect(own.reload.policy).to eq("auto_approve")
      expect(legacy.reload.ai_agent_id).to eq(fleet.id)
      expect(result.rehomed).to be_empty
    end
  end
end

# HIER-P2DECL — the explicit FORMER_OWNERS map P2A's review asked for.
#
# P2A recognised a former owner STRUCTURALLY: any declared agent whose sets no
# longer declare the category. That also matches an operator's own agent-shape
# row parked on a declared agent (System::AutonomyActions#update takes any
# agent_id). The map records each move as it happens; the reconciler prefers
# it, and falls back to the structural rule with a WARN so an unrecorded move
# is visible in the deploy log rather than silently honoured.
RSpec.describe System::Governance::PolicyReconciler, "FORMER_OWNERS (HIER-P2DECL)" do
  let(:account) { create(:account) }
  let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil) }
  subject(:reconciler) { described_class.new(account: account, logger: logger) }

  let!(:fleet) do
    create(:ai_agent, account: account, name: "Fleet Autonomy", agent_type: "monitor",
                      source_key: "fleet-autonomy")
  end

  def identity!(key)
    identity = System::Governance::PolicyDeclarations::AGENT_IDENTITIES.fetch(key)
    create(:ai_agent, account: account, name: identity[:name], agent_type: identity[:agent_type],
                      source_key: key)
  end

  def row(agent, category)
    Ai::InterventionPolicy.find_by(account: account, scope: "agent", ai_agent_id: agent.id,
                                   action_category: category)
  end

  def agent_row!(agent, category, policy: "require_approval", priority: 10,
                 conditions: { "trust_tier_minimum" => "monitored" })
    Ai::InterventionPolicy.create!(
      account: account, scope: "agent", ai_agent_id: agent.id, user_id: nil,
      action_category: category, policy: policy, priority: priority, is_active: true,
      conditions: conditions, preferred_channels: %w[notification]
    )
  end

  describe "the map" do
    let(:d) { System::Governance::PolicyDeclarations }
    let(:map) { described_class::FORMER_OWNERS }

    # Keys ADDED to a wave-1 group AFTER wave 1. They were never on Fleet
    # Autonomy — they were born on the manager that declares them — so they
    # belong in neither the derived roster below nor the map, and subtracting
    # them here is what keeps the 35 a pin on WHAT WAVE 1 MOVED rather than a
    # number that drifts with every later addition.
    #   system.volume_snapshot_create — IMP-c22215ae9546, the scheduled-
    #     snapshot lane, new on the Storage Manager.
    let(:added_after_wave1) { %w[system.volume_snapshot_create] }

    it "records every key wave 1 lifted off Fleet Autonomy — 35 — and P2A's 16 before them" do
      wave1 = d::CAPACITY_POLICY_KEYS.keys + d::INSTANCE_POOL_POLICIES.keys + d::PROVISIONING_POLICIES.keys +
              d::STORAGE_POLICY_KEYS.keys + d::INGRESS_MANAGER_POLICIES.keys + d::SUPPLY_CHAIN_MANAGER_POLICIES.keys +
              %w[system.multi_tenant_isolation system.service_discovery_compose]
      wave1 -= added_after_wave1
      expect(wave1.size).to eq(35)
      p2a = d::SDWAN_REMEDIATION_POLICIES.keys + %w[system.gitops_drift_remediate system.disk_image_publication_investigate]
      expect(p2a.size).to eq(16)

      (wave1 + p2a).each do |category|
        expect(map[category]).to eq([ "fleet-autonomy" ]), "#{category} is not recorded as moved off fleet-autonomy"
      end
      expect(map.keys).to match_array(wave1 + p2a)
    end

    # Keys that were operator-only until wave 1 gained an agent TWIN, not a
    # move: nothing ever held them at the agent shape, so there is nothing to
    # re-home and a map entry would name a former owner that never existed.
    it "does not claim a former owner for the twin-only keys or the never-declared compose key" do
      expect(map.keys & %w[system.platform.scale_out system.platform.scale_in system.instance_cordon
                           system.volume_snapshot_delete system.sdwan_federation_compose]).to eq([])
      # Same rule for a key that is not a twin but simply POST-DATES the move.
      expect(map.keys & added_after_wave1).to eq([])
    end

    it "is consistent with the declarations: every entry names a declared former agent that no longer declares the key" do
      map.each do |category, formers|
        owner = d.owner_of(category)
        expect(owner).to be_present, "#{category} is in FORMER_OWNERS but no agent set declares it"
        formers.each do |former|
          expect(d::AGENT_IDENTITIES).to have_key(former)
          expect(former).not_to eq(owner), "#{category}: #{former} is listed as former owner but is the current owner"
        end
      end
    end
  end

  describe "a capacity key moved off Fleet Autonomy, with the Capacity Manager present" do
    let!(:capacity) { identity!("capacity-manager") }
    let(:moved) { "system.instance_pool_create" }
    let!(:tuned) { agent_row!(fleet, moved, policy: "block", priority: 33) }

    it "re-homes it onto the Capacity Manager through the map — verb, priority preserved, audit written, no warn" do
      expect(logger).not_to receive(:warn)

      result = reconciler.reconcile!

      expect(tuned.reload.ai_agent_id).to eq(capacity.id)
      expect(tuned.policy).to eq("block")
      expect(tuned.priority).to eq(33)
      expect(row(fleet, moved)).to be_nil
      expect(result.rehomed).to include(a_string_matching(%r{capacity-manager/#{Regexp.escape(moved)} \(from Fleet Autonomy\)}))

      audit = AuditLog.where(account: account, resource_type: "Ai::InterventionPolicy", resource_id: tuned.id).last
      expect(audit.old_values).to include("agent_key" => "fleet-autonomy")
      expect(audit.new_values).to include("agent_key" => "capacity-manager")
    end

    it "names the move in the drift report before the run" do
      pending = reconciler.drift.rehomable.map(&:to_s)
      expect(pending).to include(a_string_matching(%r{capacity-manager/#{Regexp.escape(moved)} \(re-home from Fleet Autonomy\)}))
    end

    it "re-homes the project.* provisioning rows and the capacity-shaped DR rows the same way" do
      adapt = agent_row!(fleet, "project.adapt", policy: "require_approval")
      replace = agent_row!(fleet, "system.instance_replace", policy: "notify_and_proceed")

      reconciler.reconcile!

      expect(adapt.reload.ai_agent_id).to eq(capacity.id)
      expect(replace.reload.ai_agent_id).to eq(capacity.id)
      expect(replace.policy).to eq("notify_and_proceed")
    end
  end

  describe "with the Capacity Manager ABSENT (wave 1 deployed alone)" do
    let(:moved) { "system.instance_replace" }
    let!(:tuned) { agent_row!(fleet, moved, policy: "block") }

    it "leaves the row on Fleet Autonomy, where the tick's fallback gate reads it, and skips the set" do
      result = reconciler.reconcile!

      expect(tuned.reload.ai_agent_id).to eq(fleet.id)
      expect(result.rehomed).to be_empty
      expect(result.skipped_sets).to include("capacity-manager(agent absent)")
      expect(Ai::InterventionPolicy.where(account: account, action_category: moved).count).to eq(1)
    end
  end

  describe "the structural fallback" do
    let!(:cve) { identity!("cve-responder") }

    # An operator parked a CVE Responder key on Fleet Autonomy by hand. It is
    # not a recorded move, so the map has nothing — the structural rule still
    # re-homes it (the P2A behaviour), now with a warn line naming the gap.
    it "still re-homes an unrecorded move, and warns that FORMER_OWNERS does not record it" do
      parked = agent_row!(fleet, "system.cve_remediate", policy: "block")
      expect(logger).to receive(:warn).with(
        a_string_matching(/cve-responder\/system\.cve_remediate.*Fleet Autonomy.*not recorded in PolicyReconciler::FORMER_OWNERS/)
      ).at_least(:once)

      reconciler.reconcile!

      expect(parked.reload.ai_agent_id).to eq(cve.id)
    end

    it "does not warn for a recorded move" do
      sdwan = identity!("sdwan-manager")
      agent_row!(fleet, "system.sdwan_peer_remediate", policy: "block")
      expect(logger).not_to receive(:warn)

      reconciler.reconcile!

      expect(row(sdwan, "system.sdwan_peer_remediate")).to be_present
    end

    # The map is PREFERRED: when it names the former owner, a row on some other
    # declared agent is not a candidate even though the structural rule would
    # have taken it.
    it "ignores a structural candidate on an agent the map does not name" do
      capacity = identity!("capacity-manager")
      stray = agent_row!(cve, "system.instance_pool_create", policy: "block")

      reconciler.reconcile!

      expect(stray.reload.ai_agent_id).to eq(cve.id)
      expect(row(capacity, "system.instance_pool_create")).to be_present
      expect(row(capacity, "system.instance_pool_create").policy).to eq("require_approval")
    end
  end
end

# HIER-P2DECL — THE TOPOLOGY DESIGNER SET LANDS ON WAVE 1, BY ITSELF.
#
# The wave-1 note above the declarations reads "the agents are seeded in wave
# 2, so PolicyReconciler skips each new set". That is true of the four
# MANAGERS and false of the System Topology Designer: it is the EXISTING
# assistant (db/seeds/system_topology_designer_agent.rb), so AgentResolver
# resolves it, its set is not skipped, and the first reconcile after these
# declarations deploy moves two rows off Fleet Autonomy and creates a third.
#
# Pinned because the claim and the code are in different files: the review of
# this increment caught the header asserting an established install was
# unchanged while the implementer's own coherence spec already proved the set
# reconciled. Two of FORMER_OWNERS's 35 wave-1 keys move NOW; 33 wait.
RSpec.describe System::Governance::PolicyReconciler, "the Topology Designer set on wave 1 alone" do
  let(:account) { create(:account) }
  let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil) }
  subject(:reconciler) { described_class.new(account: account, logger: logger) }

  let(:identity_key) { "topology-designer" }
  let(:identity) { System::Governance::PolicyDeclarations::AGENT_IDENTITIES.fetch(identity_key) }

  let!(:fleet) do
    create(:ai_agent, account: account, name: "Fleet Autonomy", agent_type: "monitor",
                      source_key: "fleet-autonomy")
  end

  # Built from the SEED's literals, not from AGENT_IDENTITIES: if the two ever
  # diverge, this agent stops resolving and the examples below fail as a
  # skipped set — which is the real-world symptom, not a tautology.
  let!(:topology) do
    create(:ai_agent, account: account, name: "System Topology Designer", agent_type: "assistant",
                      source_key: "system-topology-designer")
  end

  def row(agent, category)
    Ai::InterventionPolicy.find_by(account: account, scope: "agent", ai_agent_id: agent.id,
                                   action_category: category)
  end

  def fleet_row!(category, policy:)
    Ai::InterventionPolicy.create!(
      account: account, scope: "agent", ai_agent_id: fleet.id, user_id: nil,
      action_category: category, policy: policy, priority: 10, is_active: true,
      conditions: { "trust_tier_minimum" => "monitored" }, preferred_channels: %w[notification]
    )
  end

  it "the seed writes exactly the identity AGENT_IDENTITIES declares — which is WHY this set is not skipped" do
    seed = File.read(File.expand_path("../../../../db/seeds/system_topology_designer_agent.rb", __dir__))

    expect(seed).to include(%(name: "#{identity[:name]}"))
    expect(seed).to include(%(agent_type: "#{identity[:agent_type]}"))
  end

  # Only Fleet Autonomy and the Topology Designer exist in this context — the
  # state of an ESTABLISHED install whose first boot predates the wave-2 seeds
  # and has not re-run them. There, and only there, the four manager sets
  # still skip; the example after this one is the seeded install.
  it "does not skip the topology set; the four manager sets skip only while their agents are absent" do
    result = reconciler.reconcile!

    expect(result.skipped_sets).not_to include(a_string_matching(/topology-designer/))
    expect(result.skipped_sets).to include(
      "capacity-manager(agent absent)", "storage-manager(agent absent)",
      "ingress-manager(agent absent)", "supply-chain-manager(agent absent)"
    )
  end

  # HIER-P2SWEEP: wave 2 (HIER-P2B/P2C/P2D/P2E) seeded the four managers, so a
  # fully seeded install skips NO set. Every identity the declarations know is
  # created here from AGENT_IDENTITIES (each seed's literals are pinned against
  # that constant by its own seed spec), and each manager set reconciles onto
  # its agent — the reconciler is the writer of those rows by convention (the
  # Supply Chain Manager seed writes none itself).
  it "skips nothing on a fully seeded install — the four manager sets reconcile onto their agents" do
    d = System::Governance::PolicyDeclarations
    managers = d::AGENT_IDENTITIES.reject { |key, _| %w[fleet-autonomy topology-designer].include?(key) }
    agents = managers.to_h do |key, identity|
      [ key, create(:ai_agent, account: account, name: identity[:name], agent_type: identity[:agent_type],
                                source_key: key) ]
    end

    result = reconciler.reconcile!

    expect(result.skipped_sets).to be_empty
    {
      "capacity-manager"     => "system.instance_replace",
      "storage-manager"      => "system.storage_assignment_reconcile",
      "ingress-manager"      => "system.expose_service_local",
      "supply-chain-manager" => "system.package_repository.sync"
    }.each do |key, category|
      expect(result.created_categories).to include("#{key}/#{category}")
      expect(row(agents.fetch(key), category)).to be_present
      expect(row(fleet, category)).to be_nil
    end
  end

  it "re-homes the two composer rows off Fleet Autonomy and creates the third — on this wave alone, without a warn" do
    expect(logger).not_to receive(:warn)
    isolation = fleet_row!("system.multi_tenant_isolation", policy: "auto_approve")
    compose   = fleet_row!("system.service_discovery_compose", policy: "require_approval")

    result = reconciler.reconcile!

    expect(isolation.reload.ai_agent_id).to eq(topology.id)
    expect(compose.reload.ai_agent_id).to eq(topology.id)
    expect(row(fleet, "system.multi_tenant_isolation")).to be_nil
    expect(row(fleet, "system.service_discovery_compose")).to be_nil

    created = row(topology, "system.sdwan_federation_compose")
    expect(created).to be_present
    expect(created.policy).to eq("require_approval")

    expect(result.rehomed).to contain_exactly(
      a_string_matching(%r{topology-designer/system\.multi_tenant_isolation \(from Fleet Autonomy\)}),
      a_string_matching(%r{topology-designer/system\.service_discovery_compose \(from Fleet Autonomy\)})
    )
    expect(result.created_categories).to include("topology-designer/system.sdwan_federation_compose")
  end

  it "carries an operator-TUNED verb onto the agent the composer executors run as — the loosening the header states" do
    tuned = fleet_row!("system.multi_tenant_isolation", policy: "auto_approve")

    reconciler.reconcile!

    expect(tuned.reload.ai_agent_id).to eq(topology.id)
    expect(tuned.policy).to eq("auto_approve")

    # Why that matters: BaseSkillExecutor resolves the policy against the
    # EXECUTING agent, and all three composer executors execute as this one.
    # Before the move the tuned row sat on an agent they never run as.
    # Naming each class autoloads it, which is what runs its `binds_to` —
    # the registry is populated by definition, not by a scan.
    [ System::Ai::Skills::MultiTenantIsolationExecutor,
      System::Ai::Skills::ServiceDiscoveryComposerExecutor,
      System::Ai::Skills::SdwanFederationComposeExecutor ].each do |klass|
      registration = System::Ai::Skills::SkillBindings.all.find { |r| r[:executor].name == klass.name }
      expect(registration).to be_present, "#{klass.name} is not registered with SkillBindings"
      # The registry stores SOURCE KEYS, not display names: an agent's name is
      # not its identity, and resolving bindings through one silently orphaned
      # them on a rename. AGENT_IDENTITIES is keyed on exactly that source key.
      expect(registration[:agents]).to include(identity_key),
                                       "#{klass.name} no longer binds to #{identity_key}"
    end
  end

  it "is idempotent — a second run moves and creates nothing" do
    fleet_row!("system.multi_tenant_isolation", policy: "auto_approve")
    reconciler.reconcile!

    again = described_class.new(account: account, logger: Logger.new(IO::NULL)).reconcile!

    expect(again.rehomed).to be_empty
    expect(again.created_categories).not_to include(a_string_matching(/topology-designer/))
  end
end
