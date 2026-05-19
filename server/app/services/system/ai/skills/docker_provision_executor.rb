# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Phase 1 Docker — skill executor that wraps
      # System::DockerDaemonProvisionerService for the AI catalog. Mirrors
      # ProvisionClusterExecutor's shape so the Runtime Manager agent can
      # discover both via `platform.discover_skills` and orchestrate them
      # uniformly.
      #
      # Composition shape (single-instance):
      #   verify SDWAN peer attached → DockerDaemonProvisionerService.provision!
      #   → managed Devops::DockerHost row + client mTLS cert in Vault
      #
      # Reference: spicy-bear plan Phase 1 + skill awareness slice 2.
      class DockerProvisionExecutor < BaseSkillExecutor
        skill_descriptor(
          name: "docker_provision",
          description: "Provision a managed Docker daemon on a NodeInstance — auto-registers as a Devops::DockerHost bound to the SDWAN overlay /128",
          category: "devops",
          inputs: {
            node_instance_id: { type: "string", required: true,
                                description: "NodeInstance to provision (must already have an Sdwan::Peer with assigned overlay)" },
            dry_run: { type: "boolean", required: false, default: false,
                       description: "Plan-only — return projected actions without creating the DockerHost row" }
          },
          outputs: {
            dry_run: :boolean,
            host_id: :string,
            host_status: :string,
            api_endpoint: :string,
            already_provisioned: :boolean,
            plan: :object
          }
        )

        binds_to "Runtime Manager", "System Concierge"

        protected

        def perform(node_instance_id:, dry_run: false)
          instance = ::System::NodeInstance
                       .joins(:node)
                       .where(system_nodes: { account_id: @account.id })
                       .find_by(id: node_instance_id)
          return failure("NodeInstance #{node_instance_id} not found in account") unless instance

          if dry_run
            return success(
              dry_run: true,
              host_id: nil,
              host_status: nil,
              api_endpoint: nil,
              already_provisioned: false,
              plan: build_plan(instance)
            )
          end

          existing = ::Devops::DockerHost.managed.find_by(node_instance_id: instance.id)
          if existing
            return success(
              dry_run: false,
              host_id: existing.id,
              host_status: existing.status,
              api_endpoint: existing.api_endpoint,
              already_provisioned: true
            )
          end

          host = ::System::DockerDaemonProvisionerService.provision!(
            node_instance: instance, account: @account
          )
          success(
            dry_run: false,
            host_id: host.id,
            host_status: host.status,
            api_endpoint: host.api_endpoint,
            already_provisioned: false
          )
        rescue ::System::DockerDaemonProvisionerService::MissingSdwanPeerError => e
          failure(e.message)
        end

        private

        def build_plan(instance)
          peer = ::Sdwan::Peer.where(node_instance_id: instance.id)
                              .where.not(assigned_address: nil)
                              .order(:created_at)
                              .first
          {
            instance_id: instance.id,
            instance_name: instance.name,
            sdwan_peer_id: peer&.id,
            sdwan_overlay: peer&.assigned_address,
            steps: %w[
              issue_client_tls_pair
              create_managed_docker_host
              persist_credentials_to_vault
            ]
          }
        end
      end
    end
  end
end
