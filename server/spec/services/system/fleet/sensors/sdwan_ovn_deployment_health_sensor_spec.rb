# frozen_string_literal: true

require "rails_helper"

# IMP-57e9a90598ee — operator surfacing for the OVN activation lane.
#
# The DeploymentReconciler owns the transitions; this sensor owns making the
# resulting states VISIBLE. It is read-side only: it never transitions the
# deployment, because a fleet-tick sensor acting on staleness would be exactly
# the "timer elapsed" pseudo-oracle the reconciler exists to forbid.
RSpec.describe System::Fleet::Sensors::SdwanOvnDeploymentHealthSensor do
  let(:account) { create(:account) }

  subject(:signals) { described_class.new(account: account).sense }

  def kinds = signals.map { |s| s[:kind] }

  context "with no deployment" do
    it "emits nothing" do
      expect(signals).to eq([])
    end
  end

  context "degraded deployment" do
    let!(:deployment) do
      create(:sdwan_ovn_deployment, account: account, status: "degraded",
             degraded_at: 10.minutes.ago,
             nb_observed: {
               "failing" => {
                 "nb_probe" => { "error" => "Connection refused", "source" => "nb_probe",
                                 "observed_at" => 5.minutes.ago.utc.iso8601 }
               }
             })
    end

    it "emits a high-severity degraded signal carrying the failing map" do
      expect(kinds).to eq([ "system.sdwan_ovn_deployment_degraded" ])
      sig = signals.first
      expect(sig[:severity]).to eq(:high)
      expect(sig[:fingerprint]).to eq("sdwan_ovn_deployment_degraded:#{deployment.id}")
      expect(sig[:payload]["failing"].keys).to eq([ "nb_probe" ])
      expect(sig[:payload]["remediation_action"]).to be_nil
    end
  end

  context "bootstrapping deployment inside the grace window" do
    let!(:deployment) do
      create(:sdwan_ovn_deployment, account: account, status: "bootstrapping",
             bootstrapped_at: 2.minutes.ago)
    end

    it "stays quiet — bootstrap takes time and silence is not failure" do
      expect(signals).to eq([])
    end
  end

  context "bootstrapping deployment stalled past the window" do
    let!(:deployment) do
      create(:sdwan_ovn_deployment, account: account, status: "bootstrapping",
             bootstrapped_at: 2.hours.ago)
    end

    it "emits an activation-stalled signal saying nothing has been observed" do
      expect(kinds).to eq([ "system.sdwan_ovn_activation_stalled" ])
      sig = signals.first
      expect(sig[:severity]).to eq(:medium)
      expect(sig[:fingerprint]).to eq("sdwan_ovn_activation_stalled:#{deployment.id}")
      expect(sig[:payload]["reason"]).to eq("no_heavyweight_chassis")
    end

    it "names the failing replays when chassis have been observed failing" do
      deployment.update_columns(nb_observed: {
        "failing" => { "abc" => { "error" => "boom", "source" => "chassis_replay" } }
      })

      expect(signals.first[:payload]["reason"]).to eq("replay_failing")
    end

    it "distinguishes 'no heavyweight chassis' from 'chassis exist but nothing observed'" do
      node_template = create(:system_node_template, account: account)
      node = create(:system_node, account: account, node_template: node_template)
      create(:system_node_instance, node: node, status: "running",
                                    network_profile: "heavyweight")

      expect(signals.first[:payload]["reason"]).to eq("not_observed")
    end
  end

  context "pending deployment with blank endpoints, stalled" do
    let!(:deployment) do
      create(:sdwan_ovn_deployment, account: account, status: "pending",
             nb_db_endpoint: nil, sb_db_endpoint: nil, created_at: 2.hours.ago)
    end

    it "surfaces the missing endpoints — the one stall only an operator can clear" do
      expect(kinds).to eq([ "system.sdwan_ovn_activation_stalled" ])
      expect(signals.first[:payload]["reason"]).to eq("endpoints_missing")
    end
  end

  context "active deployment" do
    let!(:deployment) do
      create(:sdwan_ovn_deployment, account: account, status: "active", activated_at: 1.hour.ago)
    end

    it "emits nothing" do
      expect(signals).to eq([])
    end
  end

  describe "wiring" do
    it "is registered in the fleet tick" do
      expect(System::Fleet::FleetAutonomyService::SENSORS).to include(described_class)
    end

    it "binds to a notify-only category exempt from the remediation-validate arc" do
      binding = System::Fleet::DecisionEngine::SIGNAL_BINDINGS.fetch("system.sdwan_ovn_deployment_degraded")
      expect(binding[:skill]).to be_nil
      expect(binding[:action_category]).to eq("system.sdwan_ovn_deployment_investigate")

      stalled = System::Fleet::DecisionEngine::SIGNAL_BINDINGS.fetch("system.sdwan_ovn_activation_stalled")
      expect(stalled[:action_category]).to eq("system.sdwan_ovn_deployment_investigate")

      expect(System::Fleet::RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES)
        .to include("system.sdwan_ovn_deployment_investigate")
    end
  end
end
