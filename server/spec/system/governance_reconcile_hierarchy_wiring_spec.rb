# frozen_string_literal: true

require "rails_helper"
require "rake"

# IMP-01a089d3 — both governance doors carry the AGENT HIERARCHY pass.
#
# System::Governance::HierarchyReconciler owns the lineage forest (every
# declared system agent's edge under System Concierge) and the delegation rows
# that go with it, and it has had `reconcile!` and `drift` since HIER-P1. Its
# only WRITER was db/seeds/system_agent_hierarchy.rb, and `db:seed` is
# first-boot only on a deployed hub. So an established install that gained a
# declared identity after its first boot (a new operations manager, a core
# canonical's edge) never got the edge or the delegation row. The exception was
# a GovernanceGapSensor offer someone materialised. Every other governance
# plane (policy rows, skill bindings, engineering floors, canonical teams) is
# converged by BOTH doors: the hub's per-boot governance-reconcile.rb and
# `rails system:governance:reconcile` / `:drift`. This one had neither.
#
# WRITE SET. Lineage edges are effectively GLOBAL (a unique index on
# parent/child, and #attached? is not account-scoped); the per-account half is
# the delegation rows. The pass therefore runs over the same accounts the
# canonical-teams pass writes, Ai::Teams::CanonicalTeamReconciler
# .reconcilable_accounts: the primary account the seeds materialise in, plus
# any account already holding a canonical team. That set is where a team's
# manager needs its delegation row. An Account.all walk would write delegation
# rows into every tenant on every boot, and `drift` over every account would
# report rows no reconcile clears. The tenant examples below are that half.
#
# The runner is LOADED against the real seam, as its sibling wiring specs do.
# `type: :lib` is explicit and load-bearing — see
# governance_reconcile_release_floor_wiring_spec.rb.
RSpec.describe "governance reconcile hierarchy wiring (IMP-01a089d3)", type: :lib do
  let(:runner) do
    File.expand_path("../../../modules/powernode-hub-backend/rootfs/usr/local/bin/governance-reconcile.rb", __dir__)
  end
  let(:reconciler_class) { System::Governance::HierarchyReconciler }
  let(:child_key) { reconciler_class::CHILD_IDENTITIES.keys.first }

  # Named "Powernode Admin" so it is CanonicalTeamReconciler.primary_account.
  let!(:account) { create(:account, name: "Powernode Admin") }
  let!(:user)    { create(:user, account: account, email: "admin@powernode.org") }
  let!(:tenant)  { create(:account, name: "Some Tenant") }

  let!(:root) do
    create(:ai_agent, :global, owner_account: account, name: "Hier Root", slug: "hier-root",
                               source_key: reconciler_class::ROOT_KEY, is_system: true,
                               agent_type: reconciler_class::ROOT_IDENTITY[:agent_type])
  end
  let!(:child) do
    create(:ai_agent, :global, owner_account: account, name: "Hier Child", slug: "hier-child",
                               source_key: child_key, is_system: true,
                               agent_type: reconciler_class::CHILD_IDENTITIES.fetch(child_key)[:agent_type])
  end

  def edge? = Ai::AgentLineage.for_child(child.id).active.exists?(parent_agent_id: root.id)
  def policy?(acct, agent) = Ai::DelegationPolicy.where(account_id: acct.id, agent_id: agent.id).exists?

  def quietly
    original_out, original_err = $stdout, $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new
    yield
    [ $stdout.string, $stderr.string ]
  ensure
    $stdout, $stderr = original_out, original_err
  end

  describe "the hub's per-boot governance-reconcile.rb" do
    it "attaches a missing edge, writes the primary account's delegation rows, and prints its line" do
      expect(edge?).to be(false)

      # A bare `load`, not silence_warnings: that sets $VERBOSE = nil, which
      # makes Kernel#warn print nothing, and the runner reports through warn.
      expect { load runner }
        .to output(a_string_including("[governance-reconcile] hierarchy")).to_stderr

      expect(edge?).to be(true)
      expect(policy?(account, root)).to be(true)
      expect(policy?(account, child)).to be(true)
    end

    it "writes no delegation row into a tenant that holds no canonical team" do
      quietly { silence_warnings { load runner } }

      expect(edge?).to be(true)
      expect(Ai::DelegationPolicy.where(account_id: tenant.id)).to be_empty
    end
  end

  describe "rails system:governance:reconcile / :drift (the operator-invoked twins)" do
    before(:all) do
      Rails.application.load_tasks unless Rake::Task.task_defined?("system:governance:reconcile")
    end

    it "reconcile attaches the edge and writes the primary account's delegation rows" do
      quietly { Rake::Task["system:governance:reconcile"].execute }

      expect(edge?).to be(true)
      expect(policy?(account, child)).to be(true)
      expect(Ai::DelegationPolicy.where(account_id: tenant.id)).to be_empty
    end

    # SystemExit is caught here, never allowed to escape: an uncaught exit in
    # one example ends the whole run and truncates the suite.
    it "drift names the missing edge and exits 1, and stops naming it once reconciled" do
      missing = "#{reconciler_class::ROOT_KEY}/#{child_key}"

      _out, err = quietly do
        expect { Rake::Task["system:governance:drift"].execute }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end
      expect(err).to include("hierarchy", missing)

      quietly { Rake::Task["system:governance:reconcile"].execute }
      _out, err_after = quietly do
        Rake::Task["system:governance:drift"].execute
      rescue SystemExit
        nil # other declared identities are absent in this DB, so drift may still exit 1
      end
      expect(err_after).not_to include(missing)
    end
  end
end
