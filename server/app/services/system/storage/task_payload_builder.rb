# frozen_string_literal: true

module System
  module Storage
    # Composes the JSON task payload the on-node agent receives via System::Task.
    # The agent reads `metadata` (recipe + context) and POSTs status to the
    # node_api/storage_assignments/:id/status endpoint when done.
    #
    # Recipes come from `FileManagement::Storage#node_mount_recipe(context:)`
    # — pure data, no extension types leak into the platform provider layer.
    class TaskPayloadBuilder
      MOUNT_UNIT_PREFIX = "powernode-storage-"

      def self.build_mount_payload(assignment:, credential:, encryption_key: nil)
        new(assignment: assignment).build_mount_payload(
          credential: credential, encryption_key: encryption_key
        )
      end

      def self.build_unmount_payload(assignment:)
        new(assignment: assignment).build_unmount_payload
      end

      def self.build_exports_apply_payload(assignment:, credential:)
        new(assignment: assignment).build_exports_apply_payload(credential: credential)
      end

      def self.build_gateway_provision_payload(storage:)
        new(storage: storage).build_gateway_provision_payload
      end

      def self.build_gateway_deprovision_payload(storage:)
        new(storage: storage).build_gateway_deprovision_payload
      end

      def initialize(assignment: nil, storage: nil)
        @assignment = assignment
        @storage = storage || assignment&.file_storage
      end

      def build_mount_payload(credential:, encryption_key: nil)
        recipe = recipe_for(@assignment)
        {
          assignment_id: @assignment.id,
          unit_name: systemd_unit_for(@assignment),
          mount_path: @assignment.mount_path,
          recipe: recipe,
          options: combined_options(recipe),
          credential: {
            id: credential.id,
            kind: credential.kind,
            url: "/api/v1/system/node_api/storage_assignments/#{@assignment.id}/credential"
          },
          encryption: encryption_payload(encryption_key),
          requires_wg_interface: requires_wg?(recipe),
          wg_interface_hint: wg_interface_hint
        }
      end

      def build_unmount_payload
        {
          assignment_id: @assignment.id,
          unit_name: systemd_unit_for(@assignment),
          mount_path: @assignment.mount_path
        }
      end

      def build_exports_apply_payload(credential:)
        peer_ip = credential.vault_credentials.dig("peer_ip") || credential.metadata.dig("peer_ip")
        export_path = if @storage.gateway_proxy?
          @storage.configuration["re_export_path"]
        else
          @storage.configuration["export_path"]
        end

        {
          storage_id: @storage.id,
          account_id: @storage.account_id,
          export_path: export_path,
          deployment_shape: @storage.deployment_shape,
          entries: [
            {
              peer_ip: peer_ip,
              uid: @assignment.derived_uid,
              gid: @assignment.derived_uid,
              options: %w[rw sync no_subtree_check all_squash sec=sys]
            }
          ]
        }
      end

      def build_gateway_provision_payload
        cfg = @storage.configuration
        {
          storage_id: @storage.id,
          account_id: @storage.account_id,
          upstream_source_host: cfg["upstream_source_host"],
          upstream_export_path: cfg["upstream_export_path"],
          upstream_mount_options: cfg["upstream_mount_options"].presence || %w[vers=4.2 proto=tcp hard],
          re_export_path: cfg["re_export_path"],
          fsid: deterministic_fsid(@storage.id),
          gateway_unit_name: "#{MOUNT_UNIT_PREFIX}gw-#{@storage.id}.mount"
        }
      end

      def build_gateway_deprovision_payload
        cfg = @storage.configuration
        {
          storage_id: @storage.id,
          re_export_path: cfg["re_export_path"],
          gateway_unit_name: "#{MOUNT_UNIT_PREFIX}gw-#{@storage.id}.mount"
        }
      end

      private

      def recipe_for(assignment)
        storage = assignment.file_storage
        peer = ::Sdwan::Peer.find_by(
          node_instance_id: assignment.node_instance_id,
          sdwan_network_id: assignment.sdwan_network_id
        )

        context = {
          instance_id: assignment.node_instance_id,
          instance_hostname: assignment.node_instance&.name,
          peer_ip: peer&.assigned_address,
          uid: assignment.derived_uid,
          gid: assignment.derived_uid,
          account_id: assignment.account_id,
          sdwan_network_id: assignment.sdwan_network_id,
          virtual_ip_address: assignment.sdwan_virtual_ip&.cidr&.split("/")&.first,
          deployment_shape: storage&.deployment_shape,
          storage_configuration: storage&.configuration
        }
        storage.node_mount_recipe(context: context) || {}
      end

      def combined_options(recipe)
        base = recipe.is_a?(Hash) ? (recipe[:options] || []) : []
        extra = @assignment.mount_options.is_a?(Array) ? @assignment.mount_options : (@assignment.mount_options&.values || [])
        (base + extra + (@assignment.read_only? ? %w[ro] : [])).uniq
      end

      def encryption_payload(encryption_key)
        mode = @assignment.effective_encryption_mode
        return { mode: "none" } if mode == "none"

        {
          mode: mode,
          key_id: encryption_key&.id,
          key_url: encryption_key ? "/api/v1/system/node_api/storage_assignments/#{@assignment.id}/encryption_key" : nil,
          algorithm: encryption_key&.algorithm
        }
      end

      def systemd_unit_for(assignment)
        sanitized = assignment.mount_path.tr("/", "-").sub(/^-/, "")
        "#{MOUNT_UNIT_PREFIX}#{sanitized}.mount"
      end

      def wg_interface_hint
        network_id = @assignment.sdwan_network_id&.to_s
        return nil unless network_id

        "wg-sdwan-#{network_id.delete('-').first(6)}"
      end

      def requires_wg?(recipe)
        type = recipe.is_a?(Hash) ? recipe[:type] : nil
        # Object storage uses native egress; everything else rides SDWAN
        !%w[s3fs gcsfuse rclone].include?(type.to_s)
      end

      def deterministic_fsid(storage_id)
        Digest::SHA256.hexdigest(storage_id.to_s).first(8)
      end
    end
  end
end
