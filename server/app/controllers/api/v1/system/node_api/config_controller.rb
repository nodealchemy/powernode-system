# frozen_string_literal: true

module Api
  module V1
    module System
      module NodeApi
        # Instance configuration endpoint
        # Provides instance with its configuration data
        class ConfigController < BaseController
          # GET /api/v1/system/node_api/config
          # Returns instance configuration
          def show
            render_success(
              instance: serialize_instance,
              node: serialize_node,
              template: serialize_template,
              architecture: serialize_architecture
            )
          end

          # GET /api/v1/system/node_api/config/authorized_keys
          # Returns aggregated SSH authorized keys for the instance plus the
          # unix user whose ~/.ssh/authorized_keys file the on-node agent
          # should manage. Aggregation logic lives on System::Node#authorized_keys
          # so it is testable and reusable from worker dispatch and operator UI.
          def authorized_keys
            keys = current_node.authorized_keys

            render_success(
              authorized_keys: keys.join("\n"),
              keys_count: keys.length,
              target_user: target_admin_user
            )
          end

          # GET /api/v1/system/node_api/config/host_keys
          # Returns SSH host PUBLIC keys for the instance.
          # Note: this returns the public host key; the private host key is never
          # served over the API (an earlier revision incorrectly returned the private
          # key under :default — fixed in Golden Eclipse M0.H).
          def host_keys
            host_keys = {}

            if current_node.ssh_host_public_key.present?
              host_keys[:default] = current_node.ssh_host_public_key
            end

            # Instance-specific host keys (e.g. additional services on the box)
            # are still merged in from the instance config.
            if current_instance.config&.dig("host_keys").present?
              host_keys.merge!(current_instance.config["host_keys"])
            end

            render_success(host_keys: host_keys)
          end

          # GET /api/v1/system/node_api/config/network
          # Returns network configuration for the instance
          def network
            render_success(
              private_ip_address: current_instance.private_ip_address,
              public_ip_address: current_instance.public_ip_address,
              allocate_public_ip: current_node.allocate_public_ip,
              provider_region: serialize_provider_region
            )
          end

          private

          def serialize_instance
            {
              id: current_instance.id,
              name: current_instance.name,
              variety: current_instance.variety,
              status: current_instance.status,
              private_ip_address: current_instance.private_ip_address,
              public_ip_address: current_instance.public_ip_address,
              cloud_instance_id: current_instance.cloud_instance_id,
              config: current_instance.config
            }
          end

          def serialize_node
            {
              id: current_node.id,
              name: current_node.name,
              allocate_public_ip: current_node.allocate_public_ip,
              config: current_node.config,
              # Phase 3 — disk_policy is consumed by the agent's
              # volume-setup CLI to drive parted + mkfs sequencing.
              # Stored on node.config as a free-form JSONB block; the
              # platform's operator UI ensures the schema is sane,
              # but the agent treats it as data.
              disk_policy: current_node.config&.dig("disk_policy") || default_disk_policy
            }
          end

          # default_disk_policy returns a conservative default profile
          # used when a node has no explicit disk_policy configured.
          # Single root partition, ext4, no LUKS — minimum viable for
          # bare-metal nodes that don't need data partitions.
          def default_disk_policy
            {
              "profiles" => {
                "default" => {
                  "layout" => [
                    { "name" => "boot", "type" => "efi", "size_mb" => 512 },
                    { "name" => "root", "type" => "linux", "size_mb" => -1 }
                  ],
                  "format" => {
                    "boot" => { "fs" => "vfat", "label" => "EFI" },
                    "root" => { "fs" => "ext4", "label" => "root" }
                  },
                  "mount" => {
                    "boot" => { "path" => "/boot/efi", "opts" => "umask=0077,nofail" }
                  }
                }
              }
            }
          end

          def serialize_template
            return nil unless current_template

            {
              id: current_template.id,
              name: current_template.name,
              platform_id: current_template.node_platform_id,
              architecture_id: current_template.node_architecture_id,
              config: current_template.config
            }
          end

          def serialize_architecture
            return nil unless current_template&.node_architecture

            arch = current_template.node_architecture
            {
              id: arch.id,
              name: arch.name,
              config: arch.respond_to?(:config) ? arch.config : nil
            }
          end

          def serialize_provider_region
            return nil unless current_instance.provider_region

            region = current_instance.provider_region
            {
              id: region.id,
              name: region.name,
              region_code: region.region_code
            }
          end

          # The unix user whose ~/.ssh/authorized_keys the on-node agent
          # should manage. Resolution order: instance-level override →
          # node-level default → "root". Matches the cloud-init convention
          # where AWS images use "ubuntu"/"ec2-user" while bare-metal
          # bootstraps run as root.
          def target_admin_user
            current_instance.config&.dig("admin_user").presence ||
              current_node.config&.dig("admin_user").presence ||
              "root"
          end
        end
      end
    end
  end
end
