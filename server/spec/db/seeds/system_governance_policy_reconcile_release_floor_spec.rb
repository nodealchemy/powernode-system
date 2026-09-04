# frozen_string_literal: true

require "rails_helper"

# IMP-99988ef54942 — the orchestrator's final reconcile pass calls core's
# `release.build_dispatch` FLOOR seam as a BACKSTOP on the `db:seed` path.
#
# Read the step's own comment before this one: on a default `rails db:seed`
# core's engineering seed already lands the floor for every account from
# db/seeds.rb's baseline block, long before any extension orchestrator loads,
# so this step normally writes ZERO. It is the door for the runs where that
# never happened — `POWERNODE_SEED_BASELINE=false`, which skips the baseline
# block while extension seeds still load, and a core engineering seed that
# raised into db/seeds.rb's `safe_load`. On a module-composed hub the per-boot
# governance-reconcile.rb is what lands it on an established install
# (governance_reconcile_release_floor_wiring_spec.rb).
#
# The examples below therefore run this file ALONE, which is exactly the
# backstop's world: no core seed has run, the floor is absent, and the step
# must land it. Being the same absence-only seam, it can neither reset a
# retuned verb nor duplicate a row.
RSpec.describe "system_governance_policy_reconcile.rb — release-floor step (IMP-99988ef54942)" do
  let(:seed) do
    Rails.root.join("..", "extensions", "system", "server", "db", "seeds", "system_governance_policy_reconcile.rb")
  end
  let(:seeder) { Ai::Engineering::ReleaseDispatchFloorSeeder }
  let!(:account) { create(:account) }

  def floor_rows(acct)
    Ai::InterventionPolicy.where(account: acct, action_category: seeder::CATEGORY, **seeder::SHAPE)
  end

  def load_seed!
    silence_warnings { load seed }
  end

  it "writes the floor for EVERY account and reports the count" do
    other = create(:account)
    expect(floor_rows(account)).not_to exist

    expect { load seed }
      .to output(a_string_including("release.build_dispatch floor: 2 row(s) written")).to_stdout

    [ account, other ].each do |acct|
      row = floor_rows(acct).sole
      expect(row.policy).to eq("auto_approve")
      expect(row.is_active).to be(true)
    end
  end

  it "is idempotent — a second run writes nothing" do
    load_seed!
    before = Ai::InterventionPolicy.order(:id).pluck(:id, :policy, :is_active)

    expect { load seed }
      .to output(a_string_including("release.build_dispatch floor: 0 row(s) written")).to_stdout
    expect(Ai::InterventionPolicy.order(:id).pluck(:id, :policy, :is_active)).to eq(before)
  end

  it "NEVER rewrites a floor an operator retuned" do
    load_seed!
    floor_rows(account).sole.update!(policy: "require_approval", is_active: false)

    load_seed!

    row = floor_rows(account).sole
    expect(row.policy).to eq("require_approval")
    expect(row.is_active).to be(false)
  end

  it "is non-fatal when the seam raises — counted as a failure, the pass still completes" do
    allow(Ai::Engineering::ReleaseDispatchFloorSeeder).to receive(:ensure_all!).and_raise(RuntimeError, "floor boom")

    expect { load seed }
      .to output(a_string_including("release.build_dispatch floor failed: RuntimeError: floor boom")
                 .and(a_string_including("1 failed")))
      .to_stdout
  end

  it "tolerates a core tree that predates the seam (module skew) — named skip, never an error" do
    hide_const("Ai::Engineering::ReleaseDispatchFloorSeeder")

    expect { load seed }
      .to output(a_string_including("release.build_dispatch floor: core seam not present")).to_stdout
    expect(Ai::InterventionPolicy.where(account: account, action_category: "release.build_dispatch")).not_to exist
  end
end
