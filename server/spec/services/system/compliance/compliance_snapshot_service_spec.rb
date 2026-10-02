# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M-D2-1 — ComplianceSnapshotService.
RSpec.describe System::Compliance::ComplianceSnapshotService do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let!(:instance) { create(:system_node_instance, :running, node: node) }

  describe ".snapshot!" do
    it "returns a complete structured snapshot with metadata" do
      result = described_class.snapshot!(account: account)
      expect(result.ok?).to be true
      snap = result.snapshot

      expect(snap[:metadata][:schema_version]).to eq(1)
      expect(snap[:metadata][:account_id]).to eq(account.id)
      expect(snap[:metadata][:generated_at]).to be_present

      expect(snap[:nodes].size).to eq(1)
      expect(snap[:instances].size).to eq(1)
      expect(snap[:counts][:nodes]).to eq(1)
      expect(snap[:counts][:running_instances]).to eq(1)
      expect(snap[:drift_summary]).to include(:drifted_count, :reconciled_count, :drift_ratio_pct)
    end

    # IMP-29b38f6f48b2 — the discriminating case: the instance reports the SAME
    # module ids it is assigned, but at a STALE digest. Key-set-only drift
    # arithmetic (missing/extra) sees nothing wrong and files it as
    # `reconciled`, which is the shape a failed rolling upgrade actually has.
    context "when a running instance reports a stale digest for every assigned module" do
      let(:category) { create(:system_node_module_category, account: account) }
      let(:mod) do
        create(:system_node_module, account: account, node_platform: platform,
               category: category, name: "stale-mod")
      end

      before do
        version = create(:system_node_module_version, node_module: mod, version_number: 1,
                         oci_digest: "sha256:#{'a' * 64}")
        mod.update!(current_version_id: version.id)
        create(:system_node_module_assignment, node: node, node_module: mod)
        instance.update!(running_module_digests: { mod.id => "sha256:#{'b' * 64}" })
      end

      it "counts the instance as drifted, not reconciled" do
        result = described_class.snapshot!(account: account)
        # Assert the pipeline succeeded BEFORE destructuring: snapshot! wraps
        # everything in a rescue and returns a nil snapshot on failure, which
        # would otherwise surface here as an opaque NoMethodError on nil.
        expect(result.ok?).to be true
        summary = result.snapshot[:drift_summary]

        expect(summary[:reconciled_count]).to eq(0)
        expect(summary[:drifted_count]).to eq(1)
        expect(summary[:drift_ratio_pct]).to eq(100.0)
      end
    end

    it "carries the INV-1 fence status next to the violations (IMP-a2b9f3df64c0)" do
      result = described_class.snapshot!(account: account)

      expect(result.snapshot[:rcp_invariants][:inv1_fence]).to include(state: "unset", severity: :medium)
    end

    it "fails on missing account" do
      result = described_class.snapshot!(account: nil)
      expect(result.ok?).to be false
      expect(result.error).to match(/account required/)
    end

    it "isolates per-account state (different account → different snapshot)" do
      other = create(:account)
      result = described_class.snapshot!(account: other)
      expect(result.snapshot[:nodes]).to be_empty
      expect(result.snapshot[:counts][:nodes]).to eq(0)
    end

    # IMP-7e549d7506cf (Route 2 remediation) — #snapshot!'s outer rescue used
    # to put e.message straight into Result#error, and #collect_rcp_
    # invariants' own inner rescue used to put e.message into a hash that
    # ai/tools/system_fleet_tool.rb#compliance_snapshot forwards VERBATIM ON
    # THE SUCCESS PATH (result.snapshot, ok?: true) — confirmed live while
    # re-verifying this producer, not left as the derivation doc's own
    # "flagged UNVERIFIED".
    describe "sanitizes exceptions before they reach the caller (IMP-7e549d7506cf)" do
      it "does not forward raw StandardError text or the exception class name (top-level collection)" do
        sentinel = "SENTINEL_COMPLIANCE_TOP_#{SecureRandom.hex(8)}"
        allow(System::Node).to receive(:where).and_raise(StandardError, sentinel)
        expect(Rails.logger).to receive(:error).with(a_string_including(sentinel))

        result = described_class.snapshot!(account: account)

        expect(result.ok?).to be false
        expect(result.error).not_to include(sentinel)
        expect(result.error).not_to include("StandardError")
      end

      it "does not forward raw RCP-invariant-scan exception text -- reachable on the SUCCESS path" do
        sentinel = "SENTINEL_COMPLIANCE_RCP_#{SecureRandom.hex(8)}"
        allow(System::Compliance::RcpInvariantScanner).to receive(:scan).and_raise(StandardError, sentinel)
        expect(Rails.logger).to receive(:error).with(a_string_including(sentinel))

        result = described_class.snapshot!(account: account)

        # The OUTER result is still ok?: true -- only the nested
        # rcp_invariants collector failed. This is exactly what makes the
        # leak reachable on the success path: the tool forwards
        # result.snapshot unconditionally when ok?.
        expect(result.ok?).to be true
        rcp_error = result.snapshot[:rcp_invariants][:error]
        expect(rcp_error).not_to be_nil
        expect(rcp_error).not_to include(sentinel)
        expect(rcp_error).not_to include("StandardError")
      end
    end
  end
end
