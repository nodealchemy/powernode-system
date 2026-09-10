# frozen_string_literal: true

require "rails_helper"

# IMP-01a06aee — the reconciler owns EVERY edge under its root, core canonicals
# included.
#
# HIER-P3 declared the Platform Architect in AGENT_IDENTITIES so the
# governance-gap lane could gate under it, and excluded it from
# CHILD_IDENTITIES (`.except(*CORE_CANONICAL_KEYS)`) for a good reason: core
# seeds that agent AND writes its delegation policy, so writing a leaf policy
# here would flap it on every boot. But the exclusion took the EDGE with the
# policy. The result, measured before this change:
#
#   * `reconcile!` did not attach the Platform Architect's edge,
#   * `drift.missing_edges` was EMPTY with the edge absent,
#   * so the edge's only writers were db/seeds/system_agent_hierarchy.rb's own
#     inline block — and `db:seed` is FIRST-BOOT ONLY — and the
#     governance-gap materialization lane.
#
# GovernanceGapSensor had to re-implement the check in a private
# `core_canonical_edge_gaps` precisely because the reconciler's own drift could
# not answer it: one rule, two implementations, and the sensor's copy is
# subject to the per-tick budget (in a fixture with 25 other gaps the architect
# signal was dropped by it). The rule now lives once, here, and the sensor
# reads it through `missing_edges` like every other edge.
#
# THE FLAP GUARD IS HALF THE CONTRACT. Attaching the edge must NOT bring the
# delegation policy with it — that is why the exclusion existed. Every example
# that asserts the edge also asserts no policy was written, so a fix that
# simply moved the Platform Architect into CHILD_IDENTITIES would pass the
# first half and fail the second.
RSpec.describe System::Governance::HierarchyReconciler, "core-canonical edges (IMP-01a06aee)" do
  let!(:account)  { create(:account, name: "Powernode Admin") }
  let!(:user)     { create(:user, account: account, email: "admin@powernode.org") }
  let!(:provider) { create(:ai_provider, account: account, provider_type: "anthropic", is_active: true) }

  def canonical(name:, slug:, agent_type:, source_key: nil)
    create(:ai_agent, :global, owner_account: account, name: name, slug: slug,
                               source_key: source_key || slug, agent_type: agent_type, is_system: true)
  end

  let!(:root) do
    canonical(name: described_class::ROOT_IDENTITY[:name], slug: "infrastructure-generalist",
              source_key: described_class::ROOT_KEY,
              agent_type: described_class::ROOT_IDENTITY[:agent_type])
  end

  let(:core_keys) { System::Governance::PolicyDeclarations::CORE_CANONICAL_KEYS }

  def reconciler = described_class.new(account: account, logger: Logger.new(IO::NULL))

  def attached?(agent) = Ai::AgentLineage.for_child(agent.id).active.exists?(parent_agent_id: root.id)
  def policy_for(agent) = Ai::DelegationPolicy.resolve_for(agent_id: agent.id, account_id: account.id)

  # Seed every declared core canonical, whatever the list holds — the set is
  # read, never restated, so a canonical added to CORE_CANONICAL_KEYS is
  # covered here without an edit.
  def seed_core_canonicals!
    core_keys.to_h do |key|
      identity = System::Governance::PolicyDeclarations::AGENT_IDENTITIES.fetch(key)
      [ key, canonical(name: identity[:name], slug: key, source_key: key, agent_type: identity[:agent_type]) ]
    end
  end

  it "has a non-empty core-canonical set — an empty one would pass every example vacuously" do
    expect(core_keys).not_to be_empty
    expect(core_keys).to include("platform-architect")
  end

  describe "#reconcile!" do
    it "attaches every declared core canonical under the root" do
      agents = seed_core_canonicals!

      reconciler.reconcile!

      agents.each { |key, agent| expect(attached?(agent)).to be(true), "#{key} not attached" }
    end

    # THE FLAP GUARD. Core owns these agents' delegation policies; writing one
    # here would rewrite it on every boot. The edge is ours, the policy is not.
    it "writes NO delegation policy for a core canonical" do
      agents = seed_core_canonicals!

      reconciler.reconcile!

      agents.each { |key, agent| expect(policy_for(agent)).to be_nil, "#{key} got a delegation policy" }
    end

    it "skips an absent core canonical rather than inventing it" do
      result = reconciler.reconcile!

      core_keys.each { |key| expect(result.skipped).to include("#{key}(agent absent)") }
      expect(Ai::Agent.global.where(source_key: core_keys)).not_to exist
    end

    it "is idempotent — a second pass attaches nothing new" do
      seed_core_canonicals!
      reconciler.reconcile!

      expect { reconciler.reconcile! }
        .not_to change { Ai::AgentLineage.active.count }
    end
  end

  describe "#drift" do
    it "reports the missing edge for every declared core canonical" do
      seed_core_canonicals!

      report = reconciler.drift

      core_keys.each do |key|
        expect(report.missing_edges).to include("#{described_class::ROOT_KEY}/#{key}")
      end
    end

    it "reports it as PRESENT once reconciled, and no longer as missing" do
      seed_core_canonicals!
      reconciler.reconcile!

      report = reconciler.drift

      core_keys.each do |key|
        edge = "#{described_class::ROOT_KEY}/#{key}"
        expect(report.present).to include(edge)
        expect(report.missing_edges).not_to include(edge)
      end
    end

    # A core canonical's delegation policy is core's to write, so its absence
    # is not drift THIS reconciler reports — otherwise `drift` would demand a
    # row it must never create, and `drifted?` would never clear.
    it "never reports a missing delegation policy for a core canonical" do
      seed_core_canonicals!
      reconciler.reconcile!

      expect(reconciler.drift.missing_policies).not_to include(*core_keys)
    end

    it "skips an absent core canonical" do
      report = reconciler.drift

      core_keys.each { |key| expect(report.skipped).to include("#{key}(agent absent)") }
    end
  end

  # THE REASON THE DUPLICATE COULD GO. GovernanceGapSensor carried its own
  # `core_canonical_edge_gaps`; it now reads these edges off
  # DriftReport#missing_edges like every other one. Asserted here rather than
  # taken on faith: deleting a second implementation is only safe if the first
  # actually covers the case, and the sensor's own spec stayed green with the
  # method gone — which proves nothing on its own.
  describe "GovernanceGapSensor, reading this drift" do
    let(:sensor) { System::Fleet::Sensors::GovernanceGapSensor.new(account: account) }

    it "emits a lineage_edge_missing gap for a core canonical with no edge" do
      seed_core_canonicals!

      subjects = sensor.send(:hierarchy_gaps).map { |signal| signal.payload["subject"] }

      core_keys.each do |key|
        expect(subjects).to include("#{described_class::ROOT_KEY}/#{key}")
      end
    end

    it "stops emitting it once the reconciler has attached the edge" do
      seed_core_canonicals!
      reconciler.reconcile!

      subjects = sensor.send(:hierarchy_gaps).map { |signal| signal.payload["subject"] }

      core_keys.each do |key|
        expect(subjects).not_to include("#{described_class::ROOT_KEY}/#{key}")
      end
    end

    # One rule, ONE implementation: a duplicate here would emit the same
    # fingerprint twice and mask a regression in the drift path.
    it "emits it exactly once per core canonical" do
      seed_core_canonicals!

      fingerprints = sensor.send(:hierarchy_gaps).map(&:fingerprint)

      core_keys.each do |key|
        expect(fingerprints.count("governance_gap:lineage_edge_missing:#{described_class::ROOT_KEY}/#{key}")).to eq(1)
      end
    end
  end
end
