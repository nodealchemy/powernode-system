# frozen_string_literal: true

require "rails_helper"
require "rake"

# IMP-99988ef54942 — the boot-time governance reconcile lands core's
# `release.build_dispatch` FLOOR.
#
# HIER-P2B-ENG gate-routed system_dispatch_module_build_batch on
# release.build_dispatch and shipped an absence-only, per-account floor row
# through Ai::Engineering::ReleaseDispatchFloorSeeder. `db:seed` is FIRST BOOT
# ONLY on a deployed hub, and governance-reconcile.rb ran only
# System::Governance::PolicyReconciler, so on an established install the
# floor never appeared and every agent-less MCP build dispatch parked. The
# runner is LOADED here against the real seam rather than grepped, so the
# assertion is on the row the boot leaves behind and the line the journal
# would carry.
#
# `type: :lib` is explicit and load-bearing — see
# role_grant_reversal_wiring_spec.rb.
RSpec.describe "hub-backend governance reconcile release-floor wiring (IMP-99988ef54942)", type: :lib do
  let(:runner) do
    File.expand_path("../../../modules/powernode-hub-backend/rootfs/usr/local/bin/governance-reconcile.rb", __dir__)
  end

  let(:seeder) { Ai::Engineering::ReleaseDispatchFloorSeeder }
  let!(:account) { create(:account) }

  def floor_rows(acct)
    Ai::InterventionPolicy.where(account: acct, action_category: seeder::CATEGORY, **seeder::SHAPE)
  end

  def load_runner
    silence_warnings { load runner }
  end

  it "writes the floor for EVERY account on an established install and prints its summary line" do
    other = create(:account)
    expect(floor_rows(account)).not_to exist
    expect(floor_rows(other)).not_to exist

    expect { load runner }
      .to output(a_string_including("[governance-reconcile] release-floor written=2"))
      .to_stderr

    [ account, other ].each do |acct|
      row = floor_rows(acct).sole
      expect(row.policy).to eq("auto_approve")
      expect(row.is_active).to be(true)
    end
  end

  it "prints written=0 in the steady state — the positive per-boot artifact, never silence" do
    load_runner
    expect(floor_rows(account).count).to eq(1)

    expect { load runner }
      .to output(a_string_including("[governance-reconcile] release-floor written=0"))
      .to_stderr
    expect(floor_rows(account).count).to eq(1)
  end

  it "NEVER rewrites a floor an operator retuned (absence-only survives the wiring)" do
    load_runner
    floor_rows(account).sole.update!(policy: "require_approval", is_active: false)

    load_runner

    row = floor_rows(account).sole
    expect(row.policy).to eq("require_approval")
    expect(row.is_active).to be(false)
  end

  it "turns an agent-less caller's verdict into auto_approve once the boot has run" do
    resolver = Ai::InterventionPolicyService.new(account: account)
    expect(resolver.resolve(action_category: seeder::CATEGORY)[:policy]).to eq("require_approval")

    load_runner

    expect(Ai::InterventionPolicyService.new(account: account)
             .resolve(action_category: seeder::CATEGORY)[:policy]).to eq("auto_approve")
  end

  it "is non-fatal when the seam raises: the boot continues, the failure is named and evented" do
    allow(Ai::Engineering::ReleaseDispatchFloorSeeder).to receive(:ensure_all!).and_raise(RuntimeError, "floor boom")

    expect { load runner }
      .to output(a_string_including("release-floor ensure failed (non-fatal): RuntimeError: floor boom")
                 .and(a_string_including("RECONCILE FAILED"))
                 .and(satisfy { |s| !s.include?("unexpected error") }))
      .to_stderr

    event = System::FleetEvent.find_by(kind: "governance_reconcile_failed")
    expect(event).to be_present
    expect(event.payload["failed"].map { |f| f["account_id"] }).to include("(release-floor)")
  end

  it "tolerates a core tree that predates the seam (module skew) — named skip, never an error" do
    hide_const("Ai::Engineering::ReleaseDispatchFloorSeeder")

    expect { load runner }
      .to output(a_string_including("release-floor: core seam not present")
                 .and(satisfy { |s| !s.include?("unexpected error") }))
      .to_stderr
    expect(Ai::InterventionPolicy.where(account: account, action_category: "release.build_dispatch")).not_to exist
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

    it "lands the floor for EVERY account, the same as the boot script" do
      other = create(:account)
      expect(floor_rows(account)).not_to exist

      quietly { Rake::Task["system:governance:reconcile"].execute }

      [ account, other ].each do |acct|
        row = floor_rows(acct).sole
        expect(row.policy).to eq("auto_approve")
        expect(row.is_active).to be(true)
      end
    end

    it "NEVER rewrites a floor an operator retuned" do
      quietly { Rake::Task["system:governance:reconcile"].execute }
      floor_rows(account).sole.update!(policy: "require_approval", is_active: false)

      quietly { Rake::Task["system:governance:reconcile"].execute }

      row = floor_rows(account).sole
      expect(row.policy).to eq("require_approval")
      expect(row.is_active).to be(false)
    end
  end
end
