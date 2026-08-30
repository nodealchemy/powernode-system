# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M6.A — DriftRemediateExecutor skill.
RSpec.describe System::Ai::Skills::DriftRemediateExecutor do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }
  let(:exec)     { described_class.new(account: account) }

  let(:mod) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "drift-mod")
  end
  let!(:version) do
    v = System::NodeModuleVersion.create!(
      node_module: mod, version_number: 1,
      mask: [], file_spec: [], package_spec: [], config: {},
      oci_digest: "sha256:#{'a' * 64}"
    )
    mod.update!(current_version_id: v.id)
    v
  end

  describe ".descriptor" do
    it "returns a complete skill descriptor" do
      d = described_class.descriptor
      expect(d[:name]).to eq("drift_remediate")
      expect(d[:category]).to eq("devops")
      expect(d.dig(:inputs, :instance_id, :required)).to be true
      expect(d.dig(:outputs)).to include(:resolved, :requires_approval, :disruption_pct, :planned_actions)
    end
  end

  describe "#execute" do
    context "with no drift" do
      before do
        System::NodeModuleAssignment.create!(node: node, node_module: mod, enabled: true, priority: 0)
        instance.update!(running_module_digests: { mod.id => "sha256:#{'a' * 64}" })
      end

      # IMP-b948ea7fa382 — the CONTRAST that stops the fix from collapsing both
      # arms to false. Here `resolved: true` is correct and must stay: there
      # was no drift, so the instance genuinely matches its assignments. The
      # discriminator is "was there drift", not "did we apply anything".
      it "returns resolved=true with empty planned_actions" do
        r = exec.execute(instance_id: instance.id)
        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:resolved]).to be true
        expect(d[:requires_approval]).to be false
        expect(d[:disruption_pct]).to eq(0)
        expect(d[:planned_actions]).to eq(attach: [], detach: [], update: [])
        expect(d[:reason]).to eq("no drift")
      end
    end

    context "with one missing module" do
      before do
        System::NodeModuleAssignment.create!(node: node, node_module: mod, enabled: true, priority: 0)
        instance.update!(running_module_digests: {}) # nothing running
      end

      it "plans an attach + reports modest disruption" do
        r = exec.execute(instance_id: instance.id)
        expect(r[:data][:requires_approval]).to be false
        expect(r[:data][:disruption_pct]).to eq(20)
        expect(r[:data][:planned_actions][:attach]).to eq([ mod.id ])
      end

      # IMP-b948ea7fa382 — THE false-success oracle. This is the arm that
      # reported `resolved: true`: disruption 20 is NOT > max_disruption_pct
      # 20, so requires_approval was false and `resolved: !requires_approval`
      # claimed the drift was gone. The executor attaches nothing. It calls
      # system_drift_report and formats the result; there is no write on any
      # path through #perform.
      it "reports resolved=false when drift was found, because it applies nothing" do
        r = exec.execute(instance_id: instance.id)
        expect(r[:data][:resolved]).to be false
        expect(r[:data][:planned_actions][:attach]).to eq([ mod.id ])
      end

      # The PREMISE pin behind the label (it does not itself fail if the fix is
      # reverted — :81 does that). After a run the drift is still there, byte
      # for byte, and no task was dispatched to converge it either. Both halves
      # are needed: writing digests is how this executor would converge
      # directly, and creating a System::Task is how the DOWNSTREAM lane does
      # it — an executor that had quietly grown the second would pass a
      # digests-only check while making "applies nothing" false.
      it "leaves the drift in place and dispatches nothing to fix it" do
        expect { exec.execute(instance_id: instance.id) }
          .not_to change(System::Task, :count)

        instance.reload
        expect(instance.running_module_digests).to eq({})
        expect(System::NodeModuleAssignment.where(node: node).count).to eq(1)

        again = exec.execute(instance_id: instance.id)
        expect(again[:data][:planned_actions][:attach]).to eq([ mod.id ])
        expect(again[:data][:disruption_pct]).to eq(20)
      end

      # Matched pair, per rolling_upgrade_docs_accuracy_spec.rb: deleting the
      # false deferral is not enough — the replacement has to tell the caller
      # what actually happened. The old note deferred to an "M7 reconciler"
      # that was never built.
      it "does not defer to an unbuilt reconciler, and says what it did instead" do
        note = exec.execute(instance_id: instance.id)[:data][:note].to_s
        expect(note).not_to match(/M7/)
        expect(note).to match(/plan only|nothing applied|applies nothing/i)
      end
    end

    context "with many drifted modules" do
      let(:mods) do
        Array.new(3) do |i|
          create(:system_node_module, account: account, node_platform: platform,
                 category: category, variety: "subscription", name: "many-mod-#{i}")
        end
      end

      before do
        mods.each_with_index do |m, i|
          v = System::NodeModuleVersion.create!(
            node_module: m, version_number: 1,
            mask: [], file_spec: [], package_spec: [], config: {},
            oci_digest: "sha256:#{'b' * 60}#{i.to_s.rjust(4, '0')}"
          )
          m.update!(current_version_id: v.id)
          System::NodeModuleAssignment.create!(node: node, node_module: m, enabled: true, priority: 0)
        end
        instance.update!(running_module_digests: {})
      end

      it "exceeds default threshold and flags requires_approval=true" do
        r = exec.execute(instance_id: instance.id)
        expect(r[:data][:disruption_pct]).to be >= 60
        expect(r[:data][:requires_approval]).to be true
        # NOTE: resolved was already false on THIS arm before the fix
        # (`!requires_approval` = !true), so it is a tripwire here, not an
        # oracle. The oracle for the fix is the under-threshold arm at :81.
        expect(r[:data][:resolved]).to be false
        expect(r[:data][:planned_actions][:attach].size).to eq(3)
      end

      # The approval arm's note was the OTHER M7 deferral on that line
      # ("gated until M7 ApprovalRequest wiring"). Same matched pair.
      it "does not defer the gated arm to unbuilt approval wiring either" do
        note = exec.execute(instance_id: instance.id)[:data][:note].to_s
        expect(note).not_to match(/M7/)
        expect(note).to match(/plan only|nothing applied|applies nothing/i)
        expect(note).to match(/approve/i)
      end

      # IMP-b948ea7fa382 — raising the threshold changes whether an operator
      # is asked, not whether anything converged. This example is the second
      # false-success oracle: `resolved: !requires_approval` made
      # max_disruption_pct a switch that could DECLARE 60% drift resolved.
      it "honors custom max_disruption_pct without claiming the drift is gone" do
        r = exec.execute(instance_id: instance.id, max_disruption_pct: 80)
        expect(r[:data][:requires_approval]).to be false
        expect(r[:data][:resolved]).to be false
        expect(r[:data][:disruption_pct]).to be >= 60
      end
    end

    context "when drift_report fails (instance not found)" do
      it "returns failure result" do
        r = exec.execute(instance_id: SecureRandom.uuid)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/drift_report failed/)
      end
    end

    context "with extra running modules + mismatched digest" do
      let(:other_mod) do
        create(:system_node_module, account: account, node_platform: platform,
               category: category, variety: "subscription", name: "extra-mod")
      end

      before do
        System::NodeModuleAssignment.create!(node: node, node_module: mod, enabled: true, priority: 0)
        instance.update!(running_module_digests: {
          mod.id => "sha256:#{'c' * 64}",       # mismatch
          other_mod.id => "sha256:#{'d' * 64}"  # extra
        })
      end

      it "produces a plan with update + detach entries" do
        r = exec.execute(instance_id: instance.id)
        actions = r[:data][:planned_actions]
        expect(actions[:update]).to include(mod.id)
        expect(actions[:detach]).to include(other_mod.id)
      end
    end
  end
end
