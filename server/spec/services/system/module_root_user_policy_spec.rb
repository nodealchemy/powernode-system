# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::ModuleRootUserPolicy do
  let(:manifest) do
    { "name" => "powernode-hub-backend", "services" => [ { "name" => "rails", "user" => "root" } ] }
  end
  let(:future_date) { (Date.current + 60).iso8601 }
  let(:past_date) { (Date.current - 1).iso8601 }

  describe ".violations" do
    it "flags user: root with no documented exception (arm 1: fails without an exception)" do
      expect(described_class.violations(manifest, {})).to contain_exactly(
        a_string_matching(%r{powernode-hub-backend/rails: user: root with no documented exception})
      )
    end

    it "passes when a complete, evidenced, unexpired exception exists (arm 2: passes with an exception)" do
      exceptions = {
        "powernode-hub-backend" => {
          "rails" => { "reason" => "needs root to X", "task" => "IMP-0123456789ab", "review_by" => future_date }
        }
      }

      expect(described_class.violations(manifest, exceptions)).to be_empty
    end

    it "rejects an exception missing the required keys" do
      exceptions = { "powernode-hub-backend" => { "rails" => { "reason" => "needs root" } } }

      expect(described_class.violations(manifest, exceptions)).to contain_exactly(
        a_string_matching(/missing task, review_by/)
      )
    end

    it "rejects an exception whose task is not an IMP id" do
      exceptions = {
        "powernode-hub-backend" => {
          "rails" => { "reason" => "needs root", "task" => "TICKET-1", "review_by" => future_date }
        }
      }

      expect(described_class.violations(manifest, exceptions)).to contain_exactly(
        a_string_matching(/is not an IMP id/)
      )
    end

    it "rejects an exception whose review_by is not a valid date" do
      exceptions = {
        "powernode-hub-backend" => {
          "rails" => { "reason" => "needs root", "task" => "IMP-0123456789ab", "review_by" => "not-a-date" }
        }
      }

      expect(described_class.violations(manifest, exceptions)).to contain_exactly(
        a_string_matching(/review_by .* is not a valid date/)
      )
    end

    it "rejects an exception whose review_by date has passed" do
      exceptions = {
        "powernode-hub-backend" => {
          "rails" => { "reason" => "needs root", "task" => "IMP-0123456789ab", "review_by" => past_date }
        }
      }

      expect(described_class.violations(manifest, exceptions)).to contain_exactly(
        a_string_matching(/review_by #{Regexp.escape(past_date)} has passed/)
      )
    end

    it "ignores a service that does not run as root" do
      non_root_manifest = { "name" => "powernode-hub-backend", "services" => [ { "name" => "rails", "user" => "app" } ] }

      expect(described_class.violations(non_root_manifest, {})).to be_empty
    end

    it "ignores modules outside the in-scope list, even with an undocumented root service" do
      out_of_scope = { "name" => "postgres-primary", "services" => [ { "name" => "postgres", "user" => "root" } ] }

      expect(described_class.violations(out_of_scope, {})).to be_empty
    end

    # Review round 4 (fail closed, don't crash): a nil/non-Hash manifest, a
    # non-Array services, a malformed service entry, and a nil/false
    # exceptions (exactly what YAML.safe_load returns for an empty or
    # missing file) must all report as "nothing to check" rather than
    # raise — an empty/absent registry is a REAL state a git checkout can
    # be in (e.g. mid-edit), and it must never crash the gate that is
    # supposed to be enforcing safety.
    describe "malformed input, fails closed rather than raising" do
      it "returns [] for a nil manifest" do
        expect(described_class.violations(nil, {})).to eq([])
      end

      it "returns [] for a non-Hash manifest" do
        expect(described_class.violations("not a manifest", {})).to eq([])
      end

      it "returns [] when services is not an Array" do
        expect(described_class.violations({ "name" => "powernode-hub-backend", "services" => "oops" }, {})).to eq([])
      end

      it "returns [] for a malformed (non-Hash) service entry rather than raising" do
        malformed = { "name" => "powernode-hub-backend", "services" => [ "oops" ] }
        expect(described_class.violations(malformed, {})).to eq([])
      end

      it "treats a nil exceptions registry as empty (still flags root)" do
        expect(described_class.violations(manifest, nil)).to contain_exactly(
          a_string_matching(/no documented exception/)
        )
      end

      it "treats a false exceptions registry as empty (still flags root)" do
        expect(described_class.violations(manifest, false)).to contain_exactly(
          a_string_matching(/no documented exception/)
        )
      end

      it "treats a malformed (non-Hash) per-module exceptions entry as absent, not a crash" do
        exceptions = { "powernode-hub-backend" => "not a hash" }

        expect(described_class.violations(manifest, exceptions)).to contain_exactly(
          a_string_matching(/no documented exception/)
        )
      end
    end
  end
end
