# frozen_string_literal: true

require "rails_helper"

# IMP-8880bc817ea3 — OVN container-fabric increment 2 (extension side).
# The allocator is the handler the engine registers under core's
# Devops::ContainerLifecycleRegistry: on :created it fabrics a labeled
# container onto its requested OVN logical switch (switch-port granularity
# only — the Sdwan::Endpoint data-model question stays deferred); on
# :removed it marks the port removed so the compiler stops emitting it.
RSpec.describe Sdwan::ContainerSwitchPortAllocator, type: :service do
  # This spec drives the allocator DIRECTLY — silence the boot-registered
  # hook so factory-created container records don't also allocate through
  # the registry (the wired path is covered by the cross-seam spec).
  around do |example|
    snapshot = Devops::ContainerLifecycleRegistry.handlers.dup
    Devops::ContainerLifecycleRegistry.reset!
    example.run
  ensure
    Devops::ContainerLifecycleRegistry.reset!
    snapshot.each { |name, handler| Devops::ContainerLifecycleRegistry.register(name, handler) }
  end

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
  let(:switch) do
    s = Sdwan::OvnLogicalSwitch.create!(
      account: account,
      sdwan_ovn_deployment_id: deployment.id,
      name: "ls-fabric"
    )
    s.mark_active!
    s
  end

  def make_container(labels: { described_class::SWITCH_LABEL => "ls-fabric" }, **attrs)
    create(:devops_docker_container, { docker_host: host, labels: labels }.merge(attrs))
  end

  def port_for(container)
    switch.ports.find_by(name: "cnt-#{container.docker_container_id.first(12)}")
  end

  describe ".call(:created, container)" do
    before { switch } # materialize the active switch

    it "allocates an active container-kind port on the requested switch" do
      container = make_container
      described_class.call(:created, container)

      port = port_for(container)
      expect(port).to be_present
      expect(port.kind).to eq("container")
      expect(port.state).to eq("active")
      expect(port.host_node_instance_id).to eq(instance.id)
      expect(port.mac).to match(Sdwan::OvnLogicalSwitchPort::MAC_FORMAT)
      expect(port.settings).to include(
        "docker_container_id" => container.docker_container_id,
        "docker_host_id" => host.id,
        "allocated_by" => described_class::ALLOCATED_BY
      )
    end

    it "is idempotent — a second :created reuses the existing port" do
      container = make_container
      described_class.call(:created, container)

      expect { described_class.call(:created, container) }
        .not_to change(Sdwan::OvnLogicalSwitchPort, :count)
      expect(port_for(container).state).to eq("active")
    end

    it "readopts a removed port when the same container comes back" do
      container = make_container
      described_class.call(:created, container)
      port_for(container).mark_removed!

      described_class.call(:created, container)
      expect(port_for(container).state).to eq("active")
    end

    it "does nothing for a container without the switch label" do
      container = make_container(labels: { "unrelated" => "x" })
      expect { described_class.call(:created, container) }
        .not_to change(Sdwan::OvnLogicalSwitchPort, :count)
    end

    it "does nothing for a container with nil labels" do
      container = make_container(labels: nil)
      expect { described_class.call(:created, container) }
        .not_to change(Sdwan::OvnLogicalSwitchPort, :count)
    end

    context "when the labeled container cannot be fabric'd" do
      before { allow(Rails.logger).to receive(:warn) }

      it "no-ops with a warning on an external host (no NodeInstance)" do
        external = create(:devops_docker_host, :connected, account: account)
        container = create(:devops_docker_container,
                           docker_host: external,
                           labels: { described_class::SWITCH_LABEL => "ls-fabric" })

        expect { described_class.call(:created, container) }
          .not_to change(Sdwan::OvnLogicalSwitchPort, :count)
        expect(Rails.logger).to have_received(:warn).with(/heavyweight/)
      end

      it "no-ops with a warning on a lightweight host" do
        instance.update!(network_profile: "lightweight")

        container = make_container
        expect { described_class.call(:created, container) }
          .not_to change(Sdwan::OvnLogicalSwitchPort, :count)
        expect(Rails.logger).to have_received(:warn).with(/heavyweight/)
      end

      it "no-ops with a warning when the account has no active OvnDeployment" do
        deployment.update!(status: "degraded")

        container = make_container
        expect { described_class.call(:created, container) }
          .not_to change(Sdwan::OvnLogicalSwitchPort, :count)
        expect(Rails.logger).to have_received(:warn).with(/OvnDeployment/)
      end

      it "no-ops with a warning when no active switch carries the requested name" do
        container = make_container(labels: { described_class::SWITCH_LABEL => "ls-missing" })

        expect { described_class.call(:created, container) }
          .not_to change(Sdwan::OvnLogicalSwitchPort, :count)
        expect(Rails.logger).to have_received(:warn).with(/ls-missing/)
      end
    end

    it "refuses to clobber a same-named port correlated to a different container" do
      container = make_container
      switch.ports.create!(
        account: account,
        name: "cnt-#{container.docker_container_id.first(12)}",
        kind: "container",
        settings: { "docker_container_id" => "somebody-else", "docker_host_id" => host.id }
      )

      allow(Rails.logger).to receive(:error)
      expect { described_class.call(:created, container) }
        .not_to change(Sdwan::OvnLogicalSwitchPort, :count)
      expect(Rails.logger).to have_received(:error).with(/collision/i)
    end
  end

  describe ".call(:removed, container)" do
    before { switch }

    it "marks the container's port removed, leaving other ports alone" do
      container = make_container
      other = make_container(docker_container_id: SecureRandom.hex(32))
      described_class.call(:created, container)
      described_class.call(:created, other)

      described_class.call(:removed, container)

      expect(port_for(container).state).to eq("removed")
      expect(port_for(other).state).to eq("active")
    end

    it "works from the destroyed record's attributes alone (host-cascade safe)" do
      container = make_container
      described_class.call(:created, container)

      container.destroy!
      described_class.call(:removed, container)
      expect(port_for(container).state).to eq("removed")
    end

    it "is a no-op when the container never had a port" do
      container = make_container(labels: {})
      expect { described_class.call(:removed, container) }.not_to raise_error
    end
  end

  describe ".call with an unhandled event" do
    it "ignores events outside created/removed" do
      container = make_container
      expect { described_class.call(:started, container) }
        .not_to change(Sdwan::OvnLogicalSwitchPort, :count)
    end
  end
end
