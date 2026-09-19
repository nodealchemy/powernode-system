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

      def self.build_mount_payload(assignment:, credential:, encryption_key: nil, remount: false, previous_credential_ids: [])
        new(assignment: assignment).build_mount_payload(
          credential: credential, encryption_key: encryption_key,
          remount: remount, previous_credential_ids: previous_credential_ids
        )
      end

      def self.build_unmount_payload(assignment:)
        new(assignment: assignment).build_unmount_payload
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

      # remount / previous_credential_ids (IMP-e48612a32273) — ids only,
      # never secret material: `credential` above already only ever carries
      # id/kind/url (the agent fetches the actual password via that url,
      # through node_api, exactly as on a first mount). remount tells the
      # agent to `systemctl restart` instead of `systemctl start` — a start
      # on an already-active .mount unit is a no-op, which is the whole bug
      # this task exists to fix. previous_credential_ids (plural — rework
      # hole (b), review correction: derived from every credential still
      # "rotating" on this assignment, not a single metadata breadcrumb, so
      # rotate-rotate-confirm cleans up every stale cred file in one
      # remount, not just the latest) lets the agent clean up those OLD
      # credential files (keyed by credential id under
      # /run/sdwan/mount-creds) once — and only once — the restart actually
      # succeeds; see agent/internal/storage/cifs.go.
      def build_mount_payload(credential:, encryption_key: nil, remount: false, previous_credential_ids: [])
        recipe = recipe_for(@assignment)
        payload = {
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
          wg_interface_hint: wg_interface_hint,
          remount: remount
        }
        payload[:previous_credential_ids] = previous_credential_ids if previous_credential_ids.present?
        payload
      end

      def build_unmount_payload
        {
          assignment_id: @assignment.id,
          unit_name: systemd_unit_for(@assignment),
          mount_path: @assignment.mount_path
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
          uid: assignment.anonuid,
          gid: assignment.anongid,
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

      # Resolved through the single source. This used to inline its OWN
      # re-derivation of the network handle (network_id minus dashes, first
      # six) — a third independent spelling of a name the agent derives from
      # the HostVrfAssignment's short_id (IMP-54fdf40fbf9d).
      #
      # SCOPE, stated because the obvious reading is wrong: this converges the
      # STRING, and that is all it does. The agent consumes the hint as a
      # systemd UNIT name — renderMountUnit emits `Requires=<hint>.service`
      # (agent/internal/storage/systemd.go) — and nothing anywhere creates a
      # wg-sdwan-*.service unit; the interface is made with `ip link add`.
      # So the dependency was unsatisfiable before this change and remains
      # unsatisfiable after it. Do not read this method as having fixed the
      # storage mount ordering; that is a separate, still-open defect.
      #
      # Also note the nil below is a behaviour change: the old inline form
      # returned a string whenever sdwan_network_id was set, this returns nil
      # when the association fails to load (hard-deleted network), which drops
      # the Requires= line entirely rather than emitting a dangling one.
      def wg_interface_hint
        network = @assignment.sdwan_network
        return nil unless network

        ::Sdwan::HostVrfAssignment.wg_iface_name_for(
          network: network, node_instance: @assignment.node_instance
        )
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
