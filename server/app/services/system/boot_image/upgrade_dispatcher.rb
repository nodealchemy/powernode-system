# frozen_string_literal: true

module System
  module BootImage
    # Single, shared path that dispatches an in-place boot-image upgrade for one
    # NodeInstance (campaign 019f505f). Both the operator MCP action
    # (SystemFleetTool#upgrade_boot_image) and the fleet drift-rollout executor
    # (BootImageDriftRolloutExecutor) go through here so the FAIL-CLOSED cosign /
    # UKI verifiability guards live in exactly ONE place — no caller can ever
    # queue an unverifiable boot image onto a node.
    #
    # Guard order (all fail closed): no platform → no promoted image → no
    # standalone UKI artifact → no platform cosign public key → no UKI cosign
    # bundle. Then: no-op when already current (unless force), and in-flight
    # dedup (unless force).
    class UpgradeDispatcher
      Result = Struct.new(:upgraded, :task, :reason, :already_current, :deduplicated, :target_git_sha,
                          keyword_init: true) do
        def ok? = reason.nil?
      end

      DOWNLOAD_PATH = "/api/v1/system/node_api/boot_image/download"

      def self.dispatch!(instance:, source:, initiated_by: nil, force: false)
        new(instance: instance, source: source, initiated_by: initiated_by, force: force).dispatch!
      end

      # The platform's static cosign PUBLIC key (PEM), from
      # POWERNODE_COSIGN_PUBLIC_KEY (inline) or POWERNODE_COSIGN_PUBLIC_KEY_FILE
      # (path) — the same config module_oci_ingest_service verifies against. nil
      # when unset (the dispatch then fails closed).
      def self.platform_cosign_public_key
        inline = ENV["POWERNODE_COSIGN_PUBLIC_KEY"].presence
        return inline if inline

        path = ENV["POWERNODE_COSIGN_PUBLIC_KEY_FILE"].presence
        return nil if path.blank?

        File.exist?(path) ? File.read(path) : nil
      rescue StandardError => e
        ::Rails.logger.warn("[BootImage::UpgradeDispatcher] cosign public key read failed: #{e.class}: #{e.message}")
        nil
      end

      # Instance-independent reasons a platform can't be upgraded right now, or
      # nil when a dispatch could proceed. The rollout executor calls this at PLAN
      # time so a plan surfaces "cannot dispatch: no cosign bundle" instead of a
      # green plan that would silently no-op on approval.
      def self.platform_blocker(platform)
        return "no resolvable node platform" if platform.nil?
        if platform.disk_image_git_sha.blank? || platform.disk_image_oci_ref.blank?
          return "platform has no promoted disk image"
        end
        return "promoted image has no standalone UKI artifact" if platform.disk_image_uki_oci_ref.blank?
        return "platform cosign public key (POWERNODE_COSIGN_PUBLIC_KEY) not configured" if platform_cosign_public_key.blank?

        pub = platform.disk_image_publications.find_by(git_sha: platform.disk_image_git_sha)
        return "promoted image has no UKI cosign signature bundle" if pub&.uki_cosign_bundle.blank?

        nil
      end

      def initialize(instance:, source:, initiated_by: nil, force: false)
        @instance = instance
        @source = source
        @initiated_by = initiated_by
        @force = force
      end

      def dispatch!
        platform = @instance.node&.node_platform
        return err("Instance has no resolvable node platform") if platform.nil?

        target_sha = platform.disk_image_git_sha
        if target_sha.blank? || platform.disk_image_oci_ref.blank?
          return err("Platform has no promoted disk image to upgrade to")
        end
        if platform.disk_image_uki_oci_ref.blank?
          return err("Promoted image has no standalone UKI artifact (built before the in-place-upgrade CI) — " \
                     "republish/promote a newer image to enable boot-image upgrades")
        end
        cosign_pubkey = self.class.platform_cosign_public_key
        if cosign_pubkey.blank?
          return err("Refusing boot-image upgrade: the platform cosign public key " \
                     "(POWERNODE_COSIGN_PUBLIC_KEY / _FILE) is not configured — the node could not verify the pulled UKI")
        end
        promoted_pub = platform.disk_image_publications.find_by(git_sha: target_sha)
        cosign_bundle = promoted_pub&.uki_cosign_bundle
        if cosign_bundle.blank?
          return err("Promoted image has no UKI cosign signature bundle — cannot dispatch an unverifiable boot-image upgrade")
        end

        if !@force && @instance.booted_image_git_sha.present? && @instance.booted_image_git_sha == target_sha
          return Result.new(upgraded: false, already_current: true, target_git_sha: target_sha)
        end
        unless @force
          existing = in_flight_task
          if existing
            return Result.new(upgraded: false, deduplicated: true, task: existing, target_git_sha: target_sha)
          end
        end

        task = ::System::Task.create!(
          account: @instance.account, operable: @instance,
          command: "upgrade_boot_image", status: "pending",
          initiated_by: @initiated_by,
          options: {
            "target_git_sha"       => target_sha,
            "uki_oci_ref"          => platform.disk_image_uki_oci_ref,
            "uki_sha256"           => platform.disk_image_uki_sha256,
            "cosign_public_key"    => cosign_pubkey,
            "cosign_bundle_b64"    => cosign_bundle,
            "download_path"        => DOWNLOAD_PATH,
            "source"               => @source,
            "triggered_by_user_id" => @initiated_by&.id,
            "triggered_at"         => Time.current.iso8601
          }
        )
        Result.new(upgraded: true, task: task, target_git_sha: target_sha)
      rescue ActiveRecord::RecordInvalid => e
        err("Failed to queue boot-image upgrade: #{e.message}")
      end

      private

      def in_flight_task
        ::System::Task
          .where(account: @instance.account, operable: @instance, command: "upgrade_boot_image")
          .where(status: %w[pending scheduled running])
          .order(created_at: :desc).first
      end

      def err(msg) = Result.new(upgraded: false, reason: msg)
    end
  end
end
