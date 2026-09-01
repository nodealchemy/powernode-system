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
  end
end
