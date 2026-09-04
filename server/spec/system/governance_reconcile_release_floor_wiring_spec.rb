# frozen_string_literal: true

require "rails_helper"
require "rake"

# IMP-99988ef54942 — the boot-time governance reconcile lands core's
# account-wide engineering FLOORS.
#
# HIER-P2B-ENG gate-routed system_dispatch_module_build_batch on
# release.build_dispatch and shipped an absence-only, per-account floor row
# through Ai::Engineering::ReleaseDispatchFloorSeeder; IMP-a51963f8717f grew
# that seam to a category list (dev.prompt_refine and dev.skill_refine join
# it), which this spec reads rather than naming, so a category added there is
# covered here without an edit. `db:seed` is FIRST BOOT ONLY on a deployed
# hub, and governance-reconcile.rb ran only System::Governance::PolicyReconciler,
# so on an established install the floor never appeared and every agent-less
# MCP build dispatch parked. The runner is LOADED here against the real seam
# rather than grepped, so the assertion is on the rows the boot leaves behind
# and the line the journal would carry.
#
# `type: :lib` is explicit and load-bearing — see
# role_grant_reversal_wiring_spec.rb.
RSpec.describe "hub-backend governance reconcile engineering-floors wiring (IMP-99988ef54942)", type: :lib do
  let(:runner) do
    File.expand_path("../../../modules/powernode-hub-backend/rootfs/usr/local/bin/governance-reconcile.rb", __dir__)
  end

  let(:seeder) { Ai::Engineering::ReleaseDispatchFloorSeeder }
  let(:categories) { seeder::CATEGORIES }
  let!(:account) { create(:account) }

  def floor_rows(acct, category = "release.build_dispatch")
    Ai::InterventionPolicy.where(account: acct, action_category: category, **seeder::SHAPE)
  end

  def all_floor_rows(acct)
    Ai::InterventionPolicy.where(account: acct, action_category: categories, **seeder::SHAPE)
  end

  def load_runner
    silence_warnings { load runner }
  end

  it "writes every floor for EVERY account on an established install and prints its summary line" do
    other = create(:account)
    expect(all_floor_rows(account)).not_to exist
    expect(all_floor_rows(other)).not_to exist

    expect { load runner }
      .to output(a_string_including("[governance-reconcile] engineering-floors written=#{2 * categories.size}"))
      .to_stderr

    [ account, other ].product(categories).each do |acct, category|
      row = floor_rows(acct, category).sole
      expect(row.policy).to eq("auto_approve"), category
      expect(row.is_active).to be(true)
    end
  end

  it "prints written=0 in the steady state — the positive per-boot artifact, never silence" do
    load_runner
    expect(all_floor_rows(account).count).to eq(categories.size)

    expect { load runner }
      .to output(a_string_including("[governance-reconcile] engineering-floors written=0"))
      .to_stderr
    expect(all_floor_rows(account).count).to eq(categories.size)
  end

  it "fills only the rows an install carrying the older single floor lacks" do
    seeder.send(:ensure_category_for!, account, "release.build_dispatch")

    expect { load runner }
      .to output(a_string_including("[governance-reconcile] engineering-floors written=#{categories.size - 1}"))
      .to_stderr
    expect(all_floor_rows(account).count).to eq(categories.size)
  end

  it "NEVER rewrites a floor an operator retuned (absence-only survives the wiring)" do
    load_runner
    floor_rows(account, "dev.skill_refine").sole.update!(policy: "require_approval", is_active: false)

    load_runner

    row = floor_rows(account, "dev.skill_refine").sole
    expect(row.policy).to eq("require_approval")
    expect(row.is_active).to be(false)
    expect(floor_rows(account).sole.policy).to eq("auto_approve")
  end

  it "turns an agent-less caller's verdict into auto_approve for every floored category once the boot has run" do
    resolver = Ai::InterventionPolicyService.new(account: account)
    categories.each do |category|
      expect(resolver.resolve(action_category: category)[:policy]).to eq("require_approval"), category
    end

    load_runner

    after = Ai::InterventionPolicyService.new(account: account)
    categories.each do |category|
      expect(after.resolve(action_category: category)[:policy]).to eq("auto_approve"), category
    end
  end

  it "is non-fatal when the seam raises: the boot continues, the failure is named and evented" do
    allow(Ai::Engineering::ReleaseDispatchFloorSeeder).to receive(:ensure_all!).and_raise(RuntimeError, "floor boom")

    expect { load runner }
      .to output(a_string_including("engineering-floors ensure failed (non-fatal): RuntimeError: floor boom")
                 .and(a_string_including("RECONCILE FAILED"))
                 .and(satisfy { |s| !s.include?("unexpected error") }))
      .to_stderr

    event = System::FleetEvent.find_by(kind: "governance_reconcile_failed")
    expect(event).to be_present
    expect(event.payload["failed"].map { |f| f["account_id"] }).to include("(engineering-floors)")
  end

  it "tolerates a core tree that predates the seam (module skew) — named skip, never an error" do
    floored = categories # read BEFORE the constant is hidden
    hide_const("Ai::Engineering::ReleaseDispatchFloorSeeder")

    expect { load runner }
      .to output(a_string_including("engineering-floors: core seam not present")
                 .and(satisfy { |s| !s.include?("unexpected error") }))
      .to_stderr
    expect(Ai::InterventionPolicy.where(account: account, action_category: floored)).not_to exist
  end

  # The operator-invoked twin. `rails system:governance:reconcile` is the door
  # an install with no hub image reaches governance through, and the extension
  # docs point remediation at it — so it carries the same floor step, or the
  # two doors documented as equivalent would converge different rows.
  describe "rails system:governance:reconcile (the operator-invoked twin)" do
    before(:all) do
      Rails.application.load_tasks unless Rake::Task.task_defined?("system:governance:reconcile")
    end

    # The rake task prints its own report; keep it out of the spec output.
    def quietly
      original_out, original_err = $stdout, $stderr
      $stdout = StringIO.new
      $stderr = StringIO.new
      yield
    ensure
      $stdout, $stderr = original_out, original_err
    end

    it "lands every floor for EVERY account, the same as the boot script" do
      other = create(:account)
      expect(all_floor_rows(account)).not_to exist

      quietly { Rake::Task["system:governance:reconcile"].execute }

      [ account, other ].product(categories).each do |acct, category|
        row = floor_rows(acct, category).sole
        expect(row.policy).to eq("auto_approve"), category
        expect(row.is_active).to be(true)
      end
    end

    it "NEVER rewrites a floor an operator retuned" do
      quietly { Rake::Task["system:governance:reconcile"].execute }
      floor_rows(account, "dev.prompt_refine").sole.update!(policy: "require_approval", is_active: false)

      quietly { Rake::Task["system:governance:reconcile"].execute }

      row = floor_rows(account, "dev.prompt_refine").sole
      expect(row.policy).to eq("require_approval")
      expect(row.is_active).to be(false)
    end
  end
end
