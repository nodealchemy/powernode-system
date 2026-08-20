# frozen_string_literal: true

require "rails_helper"

# IMP-57e9a90598ee — the OVN serving gate is widened from active-only to
# servable (bootstrapping | active | degraded).
#
# The active-only gate structurally prevented its own opener: a deployment
# could only become active on evidence from a chassis, but no chassis ever
# received ovn_control / ovn_nb_plan until the deployment was active. The
# model's own lifecycle comment defines bootstrapping as "agents are bringing
# daemons up" — which requires serving them the config. Degraded must stay
# served for the same reason: recovery (readopt) needs fresh observations,
# and the only source of observations is a served chassis.
#
# Pending stays UNSERVED: it is the one state whose endpoints may be blank,
# so there is nothing an agent could act on.
RSpec.describe "Sdwan::TopologyCompiler OVN serving gate" do
  let(:account)       { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }
  let(:node)          { create(:system_node, account: account, node_template: node_template) }
  let(:heavy) do
    create(:system_node_instance, node: node, status: "running", network_profile: "heavyweight")
  end

  def deployment_in(status)
    d = create(:sdwan_ovn_deployment, account: account)
    case status
    when "bootstrapping" then d.start_bootstrap!
    when "active"        then d.start_bootstrap! && d.mark_active!
    when "degraded"      then d.start_bootstrap! && d.mark_active! && d.mark_degraded!
    end
    d
  end

  %w[bootstrapping active degraded].each do |status|
    it "serves ovn_control for a #{status} deployment" do
      deployment_in(status)
      control = Sdwan::TopologyCompiler.ovn_control_for(heavy)
      expect(control).not_to be_nil
      expect(control[:sb_db_endpoint]).to be_present
    end

    it "serves ovn_nb_plan for a #{status} deployment" do
      deployment_in(status)
      expect(Sdwan::TopologyCompiler.ovn_nb_plan_for(heavy)).not_to be_nil
    end
  end

  it "serves nothing for a pending deployment" do
    deployment_in("pending")
    expect(Sdwan::TopologyCompiler.ovn_control_for(heavy)).to be_nil
    expect(Sdwan::TopologyCompiler.ovn_nb_plan_for(heavy)).to be_nil
  end

  it "the model scope and the gates agree on what is servable" do
    expect(Sdwan::OvnDeployment::SERVABLE_STATUSES).to match_array(%w[bootstrapping active degraded])
  end
end
