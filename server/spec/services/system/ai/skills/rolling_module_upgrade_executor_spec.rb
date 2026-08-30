# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M6.C — RollingModuleUpgradeExecutor skill.
RSpec.describe System::Ai::Skills::RollingModuleUpgradeExecutor do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }

  let(:mod) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "rolling-mod")
  end
  let!(:target_version) do
    System::NodeModuleVersion.create!(
      node_module: mod, version_number: 2,
      mask: [], file_spec: [], package_spec: [], config: {},
      oci_digest: "sha256:#{'a' * 64}"
    )
  end

  let(:exec) { described_class.new(account: account) }

  describe ".descriptor" do
    it "advertises required inputs" do
      d = described_class.descriptor
      expect(d[:name]).to eq("rolling_module_upgrade")
      expect(d.dig(:inputs, :template_id, :required)).to be true
      expect(d.dig(:inputs, :module_id, :required)).to be true
      expect(d.dig(:inputs, :target_version_id, :required)).to be true
    end

    # IMP-b948ea7fa382 — batch_pct is gone from the CONTRACT, not merely
    # ignored inside it. The operator decision (2026-08-30) was to accept
    # module upgrades as fleet-atomic: the version an instance receives
    # resolves from NodeModule#current_version_id, a per-MODULE pointer read
    # at download, and system_node_module_assignments carries no version
    # column of any kind (server/db/schema.rb:9533-9551 — auto_resolved,
    # config, node_id, node_module_id, priority, source_template_module_id,
    # enabled and timestamps, and nothing else). So there is no per-instance
    # version selection to batch OVER, and a percentage cannot bound blast
    # radius even if an advancer were built on top of this plan.
    #
    # EQUALITY, not absence-of-one-key: the whole input set is pinned, so
    # re-adding batch_pct under any spelling reddens this. The two remaining
    # optional inputs are deliberately kept — they describe a health gate
    # that a future actuator COULD implement, whereas batch_pct describes one
    # it could not.
    it "no longer advertises batch_pct as an input" do
      expect(described_class.descriptor[:inputs].keys)
        .to contain_exactly(:template_id, :module_id, :target_version_id,
                            :max_consecutive_failures, :health_timeout_sec)
    end

    it "declares a fleet-atomic output shape, with no batch structure to size" do
      expect(described_class.descriptor[:outputs].keys)
        .to contain_exactly(:total_instances, :affected_instance_ids,
                            :estimated_total_seconds, :circuit_breaker)
    end

    it "states in its description that the upgrade is fleet-atomic" do
      expect(described_class.descriptor[:description]).to match(/FLEET-ATOMIC/i)
    end
  end

  describe "#execute" do
    context "with no eligible instances" do
      it "returns an empty plan with note" do
        r = exec.execute(template_id: template.id, module_id: mod.id, target_version_id: target_version.id)
        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:total_instances]).to eq(0)
        expect(d[:affected_instance_ids]).to be_empty
        expect(d[:note]).to match(/nothing to do/)
      end
    end

    context "with running instances" do
      let!(:instance_ids) do
        5.times.map do |i|
          node = create(:system_node, account: account, node_template: template, name: "n-#{i}")
          create(:system_node_instance, :running, node: node).id
        end
      end

      # IMP-b948ea7fa382 — the fleet-atomic oracle. Not "there are no batch
      # keys" (an absence any deletion satisfies) but the positive claim that
      # replaced them: EVERY eligible instance is in the single affected set.
      # That set is what an operator moving current_version_id actually
      # touches, so equality here is the honest blast radius.
      it "reports one atomic set covering every eligible instance" do
        r = exec.execute(template_id: template.id, module_id: mod.id, target_version_id: target_version.id)
        d = r[:data]
        expect(d[:total_instances]).to eq(5)
        expect(d[:affected_instance_ids]).to match_array(instance_ids)
        expect(d[:requires_approval]).to be true
        expect(d[:executed]).to be false
        expect(d[:target][:target_version_id]).to eq(target_version.id)
      end

      it "no longer returns a batch structure of any kind" do
        d = exec.execute(template_id: template.id, module_id: mod.id,
                         target_version_id: target_version.id)[:data]

        expect(d.keys).not_to include(:batches, :batch_size, :batch_count)
      end

      it "estimates the whole fleet as one move" do
        d = exec.execute(template_id: template.id, module_id: mod.id,
                         target_version_id: target_version.id)[:data]

        expect(d[:estimated_total_seconds]).to eq(5 * 120)
      end

      # The mutation-resistant half of the removal. BaseSkillExecutor#execute
      # SLICES inputs to the keywords #perform declares (acceptable_inputs),
      # so a stale caller passing batch_pct gets no ArgumentError — the value
      # is silently dropped. That is exactly the failure this task exists to
      # make impossible to mistake for pacing, so pin it as a STATE oracle:
      # the plan produced with batch_pct is byte-identical to the one without.
      # A mutant restoring the parameter and slicing on it reddens here.
      it "produces an identical plan whether or not a stale caller passes batch_pct" do
        without = exec.execute(template_id: template.id, module_id: mod.id,
                               target_version_id: target_version.id)
        with = exec.execute(template_id: template.id, module_id: mod.id,
                            target_version_id: target_version.id, batch_pct: 50)

        expect(with[:success]).to be true
        expect(with[:data]).to eq(without[:data])
      end

      it "no longer rejects a stale caller's out-of-range batch_pct — it has no opinion on it" do
        r = exec.execute(template_id: template.id, module_id: mod.id,
                         target_version_id: target_version.id, batch_pct: 150)

        expect(r[:success]).to be true
        expect(r[:error]).to be_nil
      end
    end

    context "when target_version_id does not belong to module" do
      let!(:other_mod) { create(:system_node_module, account: account, node_platform: platform, category: category, variety: "subscription", name: "other-mod") }
      let!(:other_version) { System::NodeModuleVersion.create!(node_module: other_mod, version_number: 1, mask: [], file_spec: [], package_spec: [], config: {}, oci_digest: "sha256:#{'b' * 64}") }

      it "returns a clear failure" do
        r = exec.execute(template_id: template.id, module_id: mod.id, target_version_id: other_version.id)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/target_version_id not found/)
      end
    end
  end
end
