# frozen_string_literal: true

require "rails_helper"

# Campaign 019f6084 inc-M — System::FulfillmentRequest AASM state machine,
# .create_composed! (plan FROZEN), the recording/park helpers, and the gate/lease
# helpers. Mirrors spec/models/system/module_build_batch_spec.rb (the AASM +
# counters precedent this model follows).
RSpec.describe System::FulfillmentRequest, type: :model do
  let(:account) { create(:account) }

  def composed(**attrs)
    described_class.create_composed!(
      account: account,
      request: "give me a running memcached instance",
      plan: { "execution" => { "count" => 1, "base_os_module_name" => "base-os" } },
      cost_estimate: { "hourly_total" => 0.5 },
      reused_modules: %w[nginx],
      lease_ttl_seconds: 3600,
      **attrs
    )
  end

  describe ".create_composed!" do
    it "starts in :composed with the plan frozen and counters seeded" do
      fr = composed
      expect(fr).to be_composed
      expect(fr.plan.dig("execution", "count")).to eq(1)
      expect(fr.reused_modules).to eq(%w[nginx])
      expect(fr.reused_count).to eq(1)
      expect(fr.materialized_count).to eq(0)
      expect(fr.instance_count).to eq(0)
      expect(fr.cost_estimate["hourly_total"]).to eq(0.5)
    end
  end

  describe "validations" do
    it "rejects an unknown state" do
      fr = described_class.new(account: account, request: "x", state: "bogus")
      expect(fr).not_to be_valid
      expect(fr.errors[:state]).to be_present
    end

    it "requires a request" do
      fr = described_class.new(account: account, request: nil, state: "composed")
      expect(fr).not_to be_valid
      expect(fr.errors[:request]).to be_present
    end
  end

  describe "AASM lifecycle" do
    it "walks the full happy path, stamping each transition timestamp" do
      fr = composed

      fr.approve!;             expect(fr).to be_approved;     expect(fr.approved_at).to be_present
      fr.start_materializing!; expect(fr).to be_materializing; expect(fr.materializing_at).to be_present
      fr.start_building!;      expect(fr).to be_building;      expect(fr.building_at).to be_present
      fr.mark_templated!;      expect(fr).to be_templated;     expect(fr.templated_at).to be_present
      fr.start_provisioning!;  expect(fr).to be_provisioning;  expect(fr.provisioning_at).to be_present
      fr.start_smoking!;       expect(fr).to be_smoking;       expect(fr.smoking_at).to be_present
      fr.mark_ready!;          expect(fr).to be_ready;         expect(fr.ready_at).to be_present
      expect(fr.terminal?).to be true
    end

    it "allows the all-reused fast path: materializing → templated (skip build)" do
      fr = composed
      fr.approve!
      fr.start_materializing!
      expect(fr.may_mark_templated?).to be true
      fr.mark_templated!
      expect(fr).to be_templated
    end

    it "fails from any in-flight state, stamping the error" do
      fr = composed
      fr.approve!
      fr.start_materializing!
      fr.fail!("build exploded")
      expect(fr).to be_failed
      expect(fr.error).to eq("build exploded")
      expect(fr.failed_at).to be_present
    end

    it "expires from ready (the lease-elapsed path)" do
      fr = composed
      %i[approve! start_materializing! start_building! mark_templated!
         start_provisioning! start_smoking! mark_ready!].each { |e| fr.public_send(e) }
      fr.expire!
      expect(fr).to be_expired
      expect(fr.expired_at).to be_present
    end

    it "does not permit skipping a required transition" do
      fr = composed
      expect { fr.start_materializing! }.to raise_error(AASM::InvalidTransition)
    end
  end

  describe "scopes" do
    it "advanceable = approved..smoking, excluding composed + terminal" do
      c = composed
      a = composed.tap(&:approve!)
      r = composed.tap { |x| %i[approve! start_materializing! start_building! mark_templated!
                                start_provisioning! start_smoking! mark_ready!].each { |e| x.public_send(e) } }
      ids = described_class.advanceable.pluck(:id)
      expect(ids).to include(a.id)
      expect(ids).not_to include(c.id, r.id)
    end
  end

  describe "recording helpers" do
    it "record_materialization! sets modules, ids, count and the build batch id" do
      fr = composed
      batch = ::System::ModuleBuildBatch.create_for(
        account: account, plan: [ { module: "memcached", oci_ref: "abc" } ],
        trigger: "package", base_sha: "s", head_sha: "s"
      )
      fr.record_materialization!(module_ids: %w[m1 m2], module_names: %w[memcached libevent], build_batch: batch)
      expect(fr.materialized_modules).to eq(%w[memcached libevent])
      expect(fr.materialized_module_ids).to eq(%w[m1 m2])
      expect(fr.materialized_count).to eq(2)
      expect(fr.build_batch_id).to eq(batch.id)
      expect(fr.build_batch).to eq(batch)
    end

    it "record_instances! sets ids + count; record_smoke! stores the report" do
      fr = composed
      fr.record_instances!(%w[i1 i2 i3])
      expect(fr.node_instance_ids).to eq(%w[i1 i2 i3])
      expect(fr.instance_count).to eq(3)
      fr.record_smoke!({ "ok" => true })
      expect(fr.smoke).to eq({ "ok" => true })
    end
  end

  describe "park + gate helpers" do
    it "add_park! appends and dedupes identical (step, reason) notes" do
      fr = composed
      fr.add_park!(step: "provision", reason: "no region")
      fr.add_park!(step: "provision", reason: "no region")
      fr.add_park!(step: "smoke_probe", reason: "parked")
      expect(fr.parked.size).to eq(2)
      expect(fr.parked.map { |p| p["step"] }).to contain_exactly("provision", "smoke_probe")
    end

    it "park_gate! records the reason but does NOT transition; gate_blocked? reflects it" do
      fr = composed
      fr.approve!
      fr.park_gate!(step: "budget_gate", reason: "too expensive")
      expect(fr).to be_approved # stayed approved — resumable
      expect(fr.error).to eq("too expensive")
      expect(fr.gate_blocked?).to be true
    end
  end

  describe "#lease_summaries" do
    it "reconstructs per-instance lease detail from the leased instances" do
      platform = create(:system_node_platform, account: account)
      template = create(:system_node_template, account: account, node_platform: platform)
      node = create(:system_node, account: account, node_template: template)
      inst = create(:system_node_instance, :running, node: node)
      inst.update!(config: { "fulfillment_lease" => { "task_scoped" => true, "ttl_seconds" => 3600 } },
                   lease_class: "task_scoped", lease_expires_at: 1.hour.from_now)

      fr = composed
      fr.record_instances!([ inst.id ])
      summary = fr.lease_summaries.first
      expect(summary["instance_id"]).to eq(inst.id)
      expect(summary["task_scoped"]).to be true
      expect(summary["lease_class"]).to eq("task_scoped")
    end
  end
end
