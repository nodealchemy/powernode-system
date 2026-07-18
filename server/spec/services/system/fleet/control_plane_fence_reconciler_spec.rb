# frozen_string_literal: true

require "rails_helper"

# Autonomy safety rail (increment #28 / imp 019f6d6b-63e5): the control-plane
# fence applied to the fleet reconciler's reap driver (InstanceStatusSensor)
# and its reap/actuate path (DecisionEngine). Prevents the dev -> ops-hub
# double-reap: a plane must never reap a fleet member owned by another plane.
RSpec.describe "Control-plane fence — fleet reconciler", type: :model do
  let(:account) { create(:account) }
  let(:agent)   { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy") }
  let(:service) { System::Fleet::FleetAutonomyService.new(account: account, agent: agent) }
  let(:engine)  { System::Fleet::DecisionEngine.new(autonomy_service: service) }
  let(:node)    { create(:system_node, account: account) }

  # A running instance long-silent enough to be presumed dead (default reap
  # threshold is 30 min) — the exact condition that triggers a reap.
  def silent_instance(owner:)
    config = owner ? { "control_plane_id" => owner } : {}
    create(:system_node_instance, :running, node: node, config: config, last_heartbeat_at: 1.hour.ago)
  end

  def reap(instance)
    signal = System::Fleet::Signal.from_hash(
      "kind" => "system.instance_silent", "severity" => "critical",
      "payload" => { "instance_id" => instance.id },
      "fingerprint" => "instance_silent:#{instance.id}"
    )
    engine.send(:reap_presumed_dead!, signal)
  end

  describe "DecisionEngine reap path" do
    context "single-plane (no self-id) — fence inert, behavior unchanged" do
      it "reaps even an instance stamped for another plane" do
        instance = silent_instance(owner: "plane-B")
        result = reap(instance)
        expect(result).to be_present
        expect(result[:decision]).to eq(:presumed_dead)
        expect(instance.reload.status).to eq("error")
      end
    end

    context "with self-id = plane-A" do
      before { SiteSetting.set("control_plane_id", "plane-A") }

      it "reaps an unclaimed instance (owner nil)" do
        instance = silent_instance(owner: nil)
        expect(reap(instance)).to be_present
        expect(instance.reload.status).to eq("error")
      end

      it "reaps its own instance (owner == self)" do
        instance = silent_instance(owner: "plane-A")
        expect(reap(instance)).to be_present
        expect(instance.reload.status).to eq("error")
      end

      it "does NOT reap an instance owned by another plane (owner != self)" do
        instance = silent_instance(owner: "plane-B")
        expect(reap(instance)).to be_nil
        expect(instance.reload.status).to eq("running")
      end
    end
  end

  describe "InstanceStatusSensor reconcile query" do
    let(:sensor) { System::Fleet::Sensors::InstanceStatusSensor.new(account: account) }

    def silent_ids
      sensor.sense.map { |s| s.payload["instance_id"] || s.payload[:instance_id] }
    end

    it "emits silent signals for all owners when single-plane (self-id nil)" do
      foreign = silent_instance(owner: "plane-B")
      expect(silent_ids).to include(foreign.id)
    end

    context "with self-id = plane-A" do
      before { SiteSetting.set("control_plane_id", "plane-A") }

      it "emits for unclaimed + own instances but NOT another plane's" do
        unclaimed = silent_instance(owner: nil)
        ours      = silent_instance(owner: "plane-A")
        theirs    = silent_instance(owner: "plane-B")

        ids = silent_ids
        expect(ids).to include(unclaimed.id, ours.id)
        expect(ids).not_to include(theirs.id)
      end
    end
  end
end
