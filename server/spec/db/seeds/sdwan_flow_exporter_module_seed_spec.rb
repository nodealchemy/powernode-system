# frozen_string_literal: true

require "rails_helper"

# IMP-5a018031cc29 — the producer's DEFINITION.
#
# The architecture (Sdwan::IpfixIngestService's own header, and the vector
# config in FlowSamplesController's comment block) has always said each host
# runs a sidecar that decodes OVS's IPFIX export and POSTs JSON batches to the
# platform. That sidecar was deployed by nothing: no module seed, no agent
# component, no provisioner. `create_ipfix_collector` registered a target that
# no producer existed to reach.
#
# The delivery route is a NodeModule, matching `sdwan-overlay` (the binary
# install for the WireGuard data plane) rather than folding an IPFIX parser
# into the Go agent: module delivery already carries canary / promote /
# rollback, and the exporter is an ordinary userland daemon with a package and
# a unit, which is exactly what that lane ships.
#
# A manifest is data and cannot carry a behavioural spec on its own. What this
# spec pins is the contract the deployer and the coverage oracle DEPEND on —
# the module's name, that it declares a runnable service (a module with
# `services: []` never restarts anything and would be an inert deploy story),
# and that it claims its config directory so no other module's blob can ship
# into it. Those are the properties whose silent loss would make the rest of
# this change actuate nothing.
RSpec.describe "sdwan-flow-exporter module seed" do
  let!(:account) { create(:account, name: "Powernode Admin") }

  before do
    silence_warnings do
      load Rails.root.join("..", "extensions", "system", "server", "db", "seeds",
                           "sdwan_flow_exporter_module.rb")
    end
  end

  let(:mod) { System::NodeModule.find_by(account: account, name: "sdwan-flow-exporter") }

  it "creates the module the deployer looks for, by the name the coverage oracle uses" do
    expect(mod).to be_present
    expect(mod.name).to eq(Sdwan::FlowExportCoverage::MODULE_NAME)
    expect(mod.variety).to eq("subscription")
    expect(mod).to be_enabled
  end

  it "files it in the same Network Overlay category as sdwan-overlay" do
    expect(mod.category&.name).to eq("Network Overlay")
  end

  it "ships the collector package" do
    packages = mod.package_spec.map { |b| Base64.decode64(b) }
    expect(packages).to include("vector")
  end

  it "declares a service, so the module has a real deploy story" do
    service = mod.module_services.find_by(name: "sdwan-flow-exporter")

    expect(service).to be_present
    expect(service.restart_policy).to eq("always")
    expect(service.start_command).to be_present
  end

  it "carries a manifest whose services list matches the structured row" do
    manifest = YAML.safe_load(mod.manifest_yaml.to_s)
    expect(manifest["services"].map { |s| s["name"] }).to eq([ "sdwan-flow-exporter" ])
  end

  it "claims its own config directory as protected" do
    protected_lines = mod.protected_spec.map { |b| Base64.decode64(b) }
    expect(protected_lines).to include("+ /etc/vector/")
  end

  it "is idempotent — re-running creates no second module" do
    silence_warnings do
      load Rails.root.join("..", "extensions", "system", "server", "db", "seeds",
                           "sdwan_flow_exporter_module.rb")
    end

    expect(System::NodeModule.where(account: account, name: "sdwan-flow-exporter").count).to eq(1)
    expect(mod.reload.module_services.count).to eq(1)
  end
end
