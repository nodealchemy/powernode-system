# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M6.D — CveResponseExecutor skill.
RSpec.describe System::Ai::Skills::CveResponseExecutor do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }

  let!(:openssl_mod) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "openssl-base")
  end
  let!(:nginx_mod) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "nginx-mod")
  end
  let(:exec) { described_class.new(account: account) }

  describe ".descriptor" do
    it "advertises CVE inputs and risk-scored outputs" do
      d = described_class.descriptor
      expect(d[:name]).to eq("cve_response")
      expect(d[:category]).to eq("security")
      expect(d.dig(:inputs, :cve_id, :required)).to be true
      expect(d.dig(:outputs)).to include(:risk_score, :exposed_modules, :remediation_plan)
    end
  end

  describe "#execute" do
    context "with no matching modules" do
      it "returns risk_score=0 and an empty plan" do
        r = exec.execute(cve_id: "CVE-2026-99999", severity: "high",
                         affected_packages: [ { name: "obscurelib" } ])
        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:risk_score]).to eq(0)
        expect(d[:exposed_modules]).to be_empty
        expect(d[:remediation_plan][:steps]).to be_empty
      end
    end

    context "with one exposed module" do
      before do
        node = create(:system_node, account: account, node_template: template, name: "n1")
        System::NodeModuleAssignment.create!(node: node, node_module: openssl_mod, enabled: true, priority: 0)
      end

      it "scores risk and proposes a remediation plan" do
        r = exec.execute(cve_id: "CVE-2026-12345", severity: "high",
                         affected_packages: [ { name: "openssl", version: "<3.1.4" } ])
        d = r[:data]
        expect(d[:exposed_modules].size).to eq(1)
        expect(d[:exposed_modules].first[:matched_packages]).to include("openssl")
        expect(d[:exposed_instance_count]).to eq(1)
        expect(d[:risk_score]).to be > 0
        expect(d[:remediation_plan][:steps].first[:step]).to eq("rebuild_modules")
        expect(d[:requires_approval]).to be true
      end
    end

    context "with critical severity" do
      # IMP-b948ea7fa382 — this used to assert a severity-scaled batch_pct
      # (25 for critical, 10 otherwise), which pinned the belief that a
      # critical CVE moves in bigger groups. rolling_module_upgrade no longer
      # accepts a batch percentage at all: current_version_id is per-module,
      # so severity cannot change blast radius. What severity DOES still
      # change is the approval gate, which is asserted here alongside it.
      it "marks the rolling step fleet-atomic regardless of severity, and forces approval" do
        node = create(:system_node, account: account, node_template: template, name: "n1")
        System::NodeModuleAssignment.create!(node: node, node_module: openssl_mod, enabled: true, priority: 0)

        r = exec.execute(cve_id: "CVE-2026-1", severity: "critical",
                         affected_packages: [ { name: "openssl" } ])
        step = r[:data][:remediation_plan][:steps].find { |s| s[:step] == "rolling_upgrade" }

        expect(step).not_to have_key(:batch_pct)
        expect(step[:fleet_atomic]).to be true
        expect(step[:description]).to match(/FLEET-ATOMIC/)
        expect(r[:data][:requires_approval]).to be true
      end

      # The DISCRIMINATOR, and it has to compare two severities to be one.
      # An earlier draft of this example asserted only that critical =>
      # requires_approval, which for this fixture is ALSO reachable through
      # the risk_score arm of gate_for (critical scores ~130, well over the
      # 50 threshold) — so it would have stayed green with the severity
      # short-circuits deleted, measuring nothing.
      #
      # The property actually worth pinning is the SPLIT: severity still
      # changes the approval gate, and no longer changes the rolling step's
      # shape. Both halves are asserted against the same two runs.
      it "lets severity change the gate but NOT the rolling step's blast radius" do
        node = create(:system_node, account: account, node_template: template, name: "n1")
        System::NodeModuleAssignment.create!(node: node, node_module: openssl_mod, enabled: true, priority: 0)

        critical = exec.execute(cve_id: "CVE-2026-1", severity: "critical",
                                affected_packages: [ { name: "openssl" } ])
        low = exec.execute(cve_id: "CVE-2026-2", severity: "low",
                           affected_packages: [ { name: "openssl" } ])

        # The gate still differs by severity.
        expect(critical[:data][:requires_approval]).to be true
        expect(low[:data][:requires_approval]).to be false

        # The rolling step does NOT. It used to carry batch_pct 25 vs 10.
        step_of = lambda do |r|
          r[:data][:remediation_plan][:steps].find { |s| s[:step] == "rolling_upgrade" }
        end
        expect(step_of.call(critical)).to eq(step_of.call(low))
        expect(step_of.call(critical)[:fleet_atomic]).to be true
      end
    end

    # IMP-7bba0413c36a — with a persisted Cve the calculator's rows are the
    # answer. A keyword-only hit is minted `suspected` (no version evidence)
    # and must neither appear in exposed_modules nor be re-minted by the
    # executor's own keyword stub, which used to run whenever the persisted
    # set was empty.
    context "with a persisted Cve whose only match is a suspected keyword hit" do
      let!(:cve_record) do
        ::System::Cve.create!(
          cve_id: "CVE-2026-77001", severity: "critical",
          affected_packages: [ { "name" => "openssl", "version" => "*" } ],
          published_at: 1.day.ago, feed_source: "TEST"
        )
      end

      before do
        create(:system_node_module_version, node_module: openssl_mod, version_number: 1)
        node = create(:system_node, account: account, node_template: template, name: "n1")
        System::NodeModuleAssignment.create!(node: node, node_module: openssl_mod, enabled: true, priority: 0)
      end

      it "reports no exposure, counts the suspected row separately, and stays on the persisted source" do
        r = exec.execute(cve_id: "CVE-2026-77001", severity: "critical",
                         affected_packages: [ { name: "openssl", version: "*" } ])
        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:exposure_source]).to eq("persisted")
        expect(d[:exposed_modules]).to be_empty
        expect(d[:exposed_instance_count]).to eq(0)
        expect(d[:risk_score]).to eq(0)
        expect(d[:suspected_exposure_count]).to eq(1)
        expect(::System::CveExposure.suspected.where(cve: cve_record).count).to eq(1)
        expect(::System::CveExposure.unresolved.where(cve: cve_record)).to be_empty
      end

      # IMP-7bba0413c36a (review) — the stub is the SAME name-overlap the
      # calculator now mints as `suspected`. A calculator FAILURE is exactly
      # the degraded state in which re-minting those false positives into the
      # risk-scored list does the most damage, so the executor fails closed
      # and names the failure instead of falling through.
      it "does not fall back to the keyword stub when the calculator fails" do
        allow(::System::CveOps::ExposureCalculator).to receive(:calculate!).and_return(
          ::System::CveOps::ExposureCalculator::Result.new(
            ok?: false, error: "boom", exposures_created: 0, exposures_updated: 0,
            sbom_match_count: 0, keyword_fallback_count: 0, keyword_age_skipped_count: 0
          )
        )

        r = exec.execute(cve_id: "CVE-2026-77001", severity: "critical",
                         affected_packages: [ { name: "openssl", version: "*" } ])
        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:exposure_source]).to eq("exposure_calculation_failed")
        expect(d[:exposed_modules]).to be_empty
        expect(d[:exposed_instance_count]).to eq(0)
        expect(d[:risk_score]).to eq(0)
      end

      # A keyword row the migration RESOLVED still carries no version
      # evidence — it must not re-enter the risk-scored list, and the
      # operator-facing count must still mention it.
      it "leaves a resolved keyword row out of exposed_modules and still counts it as unconfirmed" do
        # Mint the suspected row, then put it in the state part 4's migration
        # leaves it in.
        exec.execute(cve_id: "CVE-2026-77001", severity: "critical",
                     affected_packages: [ { name: "openssl", version: "*" } ])
        rows = ::System::CveExposure.where(cve: cve_record)
        expect(rows.count).to eq(1)
        rows.update_all(
          state: "resolved", match_method: "keyword", package_version: nil,
          resolution_note: ::System::CveExposure::KEYWORD_FALSE_POSITIVE_NOTE
        )

        r = exec.execute(cve_id: "CVE-2026-77001", severity: "critical",
                         affected_packages: [ { name: "openssl", version: "*" } ])
        d = r[:data]
        expect(d[:exposure_source]).to eq("persisted")
        expect(d[:exposed_modules]).to be_empty
        expect(d[:suspected_exposure_count]).to eq(1)
      end
    end

    context "with low severity below the gate threshold" do
      it "may not require approval if risk_score is small" do
        node = create(:system_node, account: account, node_template: template, name: "n1")
        System::NodeModuleAssignment.create!(node: node, node_module: openssl_mod, enabled: true, priority: 0)

        r = exec.execute(cve_id: "CVE-2026-2", severity: "low",
                         affected_packages: [ { name: "openssl" } ])
        # severity weight 10 * (1 + log10(2)) ≈ 13 — below 50 gate.
        expect(r[:data][:requires_approval]).to be false
      end
    end

    context "with bad severity input" do
      it "fails fast" do
        r = exec.execute(cve_id: "CVE-2026-3", severity: "totally-fake",
                         affected_packages: [ { name: "x" } ])
        expect(r[:success]).to be false
        expect(r[:error]).to match(/severity must be/)
      end
    end

    context "with empty affected_packages" do
      it "fails fast" do
        r = exec.execute(cve_id: "CVE-2026-4", severity: "high", affected_packages: [])
        expect(r[:success]).to be false
        expect(r[:error]).to match(/at least one entry/)
      end
    end
  end
end
