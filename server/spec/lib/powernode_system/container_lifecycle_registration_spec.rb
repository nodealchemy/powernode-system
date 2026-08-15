# frozen_string_literal: true

require "rails_helper"

# Confirms the system extension's engine initializer
# ("powernode_system.container_lifecycle_hooks", lib/powernode_system/engine.rb)
# actually ran at boot and registered the SDWAN switch-port allocator on core's
# Devops::ContainerLifecycleRegistry seam (IMP-8880bc817ea3). A disabled or
# unloaded extension would leave the registry without this handler — core mode
# then no-ops every notify, which is the designed degradation.
RSpec.describe "PowernodeSystem container lifecycle hook registration", type: :lib do
  it "registers :sdwan_switch_port on the core registry" do
    expect(Devops::ContainerLifecycleRegistry.registered?(:sdwan_switch_port)).to be(true)
  end

  it "dispatches the registered handler to Sdwan::ContainerSwitchPortAllocator" do
    handler = Devops::ContainerLifecycleRegistry.handlers[:sdwan_switch_port]
    container = build_stubbed(:devops_docker_container)

    expect(Sdwan::ContainerSwitchPortAllocator)
      .to receive(:call).with(:created, container)

    handler.call(:created, container)
  end
end
