# frozen_string_literal: true

module Sdwan
  # IMP-8880bc817ea3 — OVN container-fabric increment 2 (extension side of the
  # ruled seam). Core's Devops::ContainerLifecycleRegistry fires :created /
  # :removed from Devops::DockerContainer commit callbacks; the engine
  # initializer "powernode_system.container_lifecycle_hooks" registers this
  # allocator as the handler.
  #
  # A container declares fabric intent with the Docker label
  # `powernode.ovn.switch=<logical-switch-name>`. On :created, when the
  # container's host is an OVN-capable (heavyweight-profile) NodeInstance and
  # the account has an active OvnDeployment carrying an active switch of that
  # name, an active `container`-kind OvnLogicalSwitchPort is allocated — so the
  # very next node_api poll serves a plan containing the port (fabric identity
  # at creation, not at a reconciler tick). On :removed the port is marked
  # removed, which drops it from the compiled plan.
  #
  # Labeled containers that CANNOT be fabric'd (external host, lightweight
  # profile, no active deployment, unknown switch) log a warning: the operator
  # stated intent the platform could not honor. Unlabeled containers no-op
  # silently — fabric is opt-in.
  #
  # Scope note: switch-port granularity only. The port row + NB plan is the
  # increment; on-host veth binding (external_ids:iface-id) and the
  # Sdwan::Endpoint data-model question are deferred. The extension-side
  # reconciler remains the future backstop sensor (hook provisions, sensor
  # repairs) — e.g. for containers discovered by sync after being created
  # outside the platform, which also funnel through this hook via the model's
  # create callback.
  class ContainerSwitchPortAllocator
    SWITCH_LABEL = "powernode.ovn.switch"
    PORT_NAME_PREFIX = "cnt-"
    ALLOCATED_BY = "container_lifecycle_hook"

    def self.call(event, container)
      case event
      when :created then new(container).allocate
      when :removed then new(container).release
      end
    end

    def initialize(container)
      @container = container
    end

    def allocate
      switch_name = requested_switch_name
      return if switch_name.blank?
      return if container.docker_container_id.blank?

      host = container.docker_host
      instance = host&.node_instance
      unless instance && instance.network_profile == "heavyweight"
        return warn_unfabricable(switch_name, "its host is not an OVN-capable (heavyweight) NodeInstance")
      end

      deployment = Sdwan::OvnDeployment.active.for_account(host.account).first
      unless deployment
        return warn_unfabricable(switch_name, "the account has no active OvnDeployment")
      end

      switch = deployment.logical_switches.active.find_by(name: switch_name)
      unless switch
        return warn_unfabricable(switch_name, "no active logical switch carries that name")
      end

      adopt_or_create_port(switch, instance)
    end

    # :removed fires post-commit on a destroyed record — possibly a
    # host-cascade destroy where the parent rows are gone too — so this path
    # reads only the record's own attributes, never live associations.
    # Correlation is the (docker_container_id, docker_host_id) pair stamped
    # into settings at allocation.
    def release
      return if container.docker_container_id.blank?

      Sdwan::OvnLogicalSwitchPort
        .where(kind: "container")
        .where("settings->>'docker_container_id' = ?", container.docker_container_id)
        .where("settings->>'docker_host_id' = ?", container.docker_host_id.to_s)
        .find_each(&:mark_removed!)
    end

    private

    attr_reader :container

    def requested_switch_name
      labels = container.labels
      return nil unless labels.is_a?(Hash)

      labels[SWITCH_LABEL].presence
    end

    # OVN port names are unique per switch; the 12-hex container short id is
    # the Docker-native stable handle. A same-named port correlated to a
    # DIFFERENT container is a short-id collision — refuse loudly rather than
    # rebinding a stranger's port.
    def adopt_or_create_port(switch, instance)
      name = "#{PORT_NAME_PREFIX}#{container.docker_container_id.first(12)}"
      port = switch.ports.find_by(name: name)

      if port
        unless port.settings["docker_container_id"] == container.docker_container_id
          Rails.logger.error(
            "[ContainerSwitchPortAllocator] port name collision on #{switch.name}/#{name}: " \
            "existing port is correlated to a different container — refusing to rebind"
          )
          return nil
        end

        port.readopt! if port.removed?
        port.mark_active! if port.pending?
        return port
      end

      port = switch.ports.create!(
        account_id: switch.account_id,
        name: name,
        kind: "container",
        host_node_instance_id: instance.id,
        settings: {
          "docker_container_id" => container.docker_container_id,
          "docker_host_id" => container.docker_host_id,
          "allocated_by" => ALLOCATED_BY
        }
      )
      port.mark_active!
      port
    end

    def warn_unfabricable(switch_name, reason)
      Rails.logger.warn(
        "[ContainerSwitchPortAllocator] container #{container.docker_container_id} " \
        "requested OVN switch #{switch_name.inspect} but #{reason} — leaving it unfabric'd"
      )
      nil
    end
  end
end
