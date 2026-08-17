# frozen_string_literal: true

require "rails_helper"

# IMP-8880bc817ea3 — the cross-seam proof for the OVN container-fabric lane.
# Drives the REAL core call site (Devops::Docker::ContainerManager, the
# terminal actuator behind the containers controller and the
# docker_create_container MCP arm) through the REAL boot-registered hook
# (engine initializer "powernode_system.container_lifecycle_hooks") into the
# REAL allocator, then asserts the OvnCompiler emits the port. Only the Docker
# daemon HTTP client is stubbed — nothing on either side of the seam is.
# A stubbed-both-sides suite stays green over seam breaks; this one cannot.
RSpec.describe "OVN container-fabric cross-seam", type: :integration do
  let(:account) { create(:account) }
  let(:instance) do
    create(:system_node_instance, account: account, network_profile: "heavyweight")
  end
  let(:host) do
    create(:devops_docker_host, :connected,
           account: account,
           provisioning_state: "managed",
           node_instance: instance)
  end
  let(:deployment) { create(:sdwan_ovn_deployment, account: account, status: "active") }
  let!(:switch) do
    s = Sdwan::OvnLogicalSwitch.create!(
      account: account,
      sdwan_ovn_deployment_id: deployment.id,
      name: "ls-fabric"
    )
    s.mark_active!
    s
  end
  let(:manager) { Devops::Docker::ContainerManager.new(host: host) }

  let(:container_id) { SecureRandom.hex(32) }
  let(:inspect_data) do
    {
      "Id" => container_id,
      "Name" => "/fabric-app",
      "Image" => "sha256:abc123",
      "State" => { "Status" => "running" },
      "Config" => {
        "Image" => "nginx:latest",
        "Cmd" => [ "nginx" ],
        "Labels" => { Sdwan::ContainerSwitchPortAllocator::SWITCH_LABEL => "ls-fabric" }
      },
      "RestartCount" => 0
    }
  end

  before do
    allow_any_instance_of(Devops::Docker::ApiClient).to receive(:container_create)
      .and_return({ "Id" => container_id, "Warnings" => [] })
    allow_any_instance_of(Devops::Docker::ApiClient).to receive(:container_inspect)
      .and_return(inspect_data)
    allow_any_instance_of(Devops::Docker::ApiClient).to receive(:container_remove)
      .and_return(nil)
  end

  it "boot-registers the switch-port allocator on core's registry" do
    expect(Devops::ContainerLifecycleRegistry.registered?(:sdwan_switch_port)).to be(true)
  end

  it "container create at the real call site materializes in the compiled OVN plan" do
    manager.create_container(name: "fabric-app", image: "nginx:latest")

    port = switch.ports.find_by(name: "cnt-#{container_id.first(12)}")
    expect(port).to be_present
    expect(port.kind).to eq("container")
    expect(port.state).to eq("active")
    expect(port.host_node_instance_id).to eq(instance.id)
    expect(port.settings["docker_container_id"]).to eq(container_id)

    plan = Sdwan::OvnCompiler.compile_for_deployment(deployment)[:plan]
    expect(plan).to include({ cmd: "lsp-add", args: [ "ls-fabric", port.name ] })
    expect(plan).to include({ cmd: "lsp-set-addresses", args: [ port.name, port.mac ] })
  end

  it "container removal at the real call site retires the port from the plan" do
    manager.create_container(name: "fabric-app", image: "nginx:latest")
    container = host.docker_containers.find_by!(docker_container_id: container_id)
    port = switch.ports.find_by!(name: "cnt-#{container_id.first(12)}")

    manager.remove_container(container)

    expect(port.reload.state).to eq("removed")
    plan = Sdwan::OvnCompiler.compile_for_deployment(deployment)[:plan]
    expect(plan.select { |e| e[:cmd] == "lsp-add" }).to be_empty
  end

  it "leaves unlabeled containers unfabric'd" do
    inspect_data["Config"]["Labels"] = {}

    expect {
      manager.create_container(name: "plain-app", image: "nginx:latest")
    }.not_to change(Sdwan::OvnLogicalSwitchPort, :count)
  end
end
