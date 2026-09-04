# frozen_string_literal: true

require "rails_helper"

# IMP-99988ef54942 — the orchestrator's final reconcile pass calls core's
# engineering FLOOR seam as a BACKSTOP on the `db:seed` path. The seam writes
# one row per category in its CATEGORIES (release.build_dispatch and, since
# IMP-a51963f8717f, dev.prompt_refine and dev.skill_refine); this spec reads
# that list rather than naming the categories, so growing it there is enough.
#
# Read the step's own comment before this one: on a default `rails db:seed`
# core's engineering seed already lands the floors for every account from
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
RSpec.describe "system_governance_policy_reconcile.rb — engineering-floors step (IMP-99988ef54942)" do
  let(:seed) do
    Rails.root.join("..", "extensions", "system", "server", "db", "seeds", "system_governance_policy_reconcile.rb")
  end
  let(:seeder) { Ai::Engineering::ReleaseDispatchFloorSeeder }
  let!(:account) { create(:account) }

  let(:categories) { seeder::CATEGORIES }

  def floor_rows(acct, category)
    Ai::InterventionPolicy.where(account: acct, action_category: category, **seeder::SHAPE)
  end

  def load_seed!
    silence_warnings { load seed }
  end

  it "writes every floor for EVERY account and reports the count" do
    other = create(:account)
    categories.each { |category| expect(floor_rows(account, category)).not_to exist }

    expect { load seed }
      .to output(a_string_including("engineering floors: #{2 * categories.size} row(s) written")).to_stdout

    [ account, other ].product(categories).each do |acct, category|
      row = floor_rows(acct, category).sole
      expect(row.policy).to eq("auto_approve"), category
      expect(row.is_active).to be(true)
    end
  end

  it "is idempotent — a second run writes nothing" do
    load_seed!
    before = Ai::InterventionPolicy.order(:id).pluck(:id, :policy, :is_active)

    expect { load seed }
      .to output(a_string_including("engineering floors: 0 row(s) written")).to_stdout
    expect(Ai::InterventionPolicy.order(:id).pluck(:id, :policy, :is_active)).to eq(before)
  end

  it "NEVER rewrites a floor an operator retuned" do
    load_seed!
    floor_rows(account, "dev.prompt_refine").sole.update!(policy: "require_approval", is_active: false)

    load_seed!

    row = floor_rows(account, "dev.prompt_refine").sole
    expect(row.policy).to eq("require_approval")
    expect(row.is_active).to be(false)
    expect(floor_rows(account, "release.build_dispatch").sole.policy).to eq("auto_approve")
  end

  it "is non-fatal when the seam raises — counted as a failure, the pass still completes" do
    allow(Ai::Engineering::ReleaseDispatchFloorSeeder).to receive(:ensure_all!).and_raise(RuntimeError, "floor boom")

    expect { load seed }
      .to output(a_string_including("engineering floors failed: RuntimeError: floor boom")
                 .and(a_string_including("1 failed")))
      .to_stdout
  end

  it "tolerates a core tree that predates the seam (module skew) — named skip, never an error" do
    floored = categories # read BEFORE the constant is hidden
    hide_const("Ai::Engineering::ReleaseDispatchFloorSeeder")

    expect { load seed }
      .to output(a_string_including("engineering floors: core seam not present")).to_stdout
    expect(Ai::InterventionPolicy.where(account: account, action_category: floored)).not_to exist
  end
end
