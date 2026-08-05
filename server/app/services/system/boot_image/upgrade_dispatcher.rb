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
    # Guard order (all fail closed, in .preflight): no platform → no promoted
    # image → no publication row for the promoted sha → that row was never
    # published → no standalone UKI artifact → no platform cosign public key →
    # no UKI cosign bundle. Then: no-op when already current (unless force),
    # and in-flight dedup (unless force).
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

      # The instance-independent guard chain, evaluated in exactly ONE place so
      # the PLAN-time blocker and the DISPATCH-time guards can never diverge:
      # 019f505f moved the UKI pin source to the promoted publication row in
      # #dispatch! but left platform_blocker reading the NodePlatform
      # disk_image_uki_* columns, so a platform whose columns were populated but
      # whose publication row carried no UKI pins planned GREEN and then
      # dispatched ZERO tasks (IMP-4452cb88e195).
      #
      # Returns [promoted_publication, failure_symbol, cosign_public_key];
      # failure_symbol is nil when a dispatch could proceed. The publication is
      # also nil for the failures found before it resolves.
      #
      # The cosign key is handed back rather than re-read by the caller because
      # platform_cosign_public_key is EFFECTFUL — it can read
      # POWERNODE_COSIGN_PUBLIC_KEY_FILE off disk and rescues StandardError to
      # nil — so validating one read and shipping another could queue a task
      # carrying a nil key if the file rotates in between. Check and use must be
      # the same bytes.
      def self.preflight(platform)
        return [ nil, :no_platform ] if platform.nil?
        if platform.disk_image_git_sha.blank? || platform.disk_image_oci_ref.blank?
          return [ nil, :no_promoted_image ]
        end

        # Deliberately a bare find_by, with no filter folded into the query:
        # (node_platform_id, git_sha) is UNIQUE, so this already returns at most
        # one row and no added condition could select a DIFFERENT one
        # (IMP-fdaccb8e7c74). The publication-state check below is therefore a
        # separate question — not "which row" but "is this row fit to dispatch"
        # — and is written as a guard on the resolved row so it stays visibly
        # independent of row selection.
        pub = platform.disk_image_publications.find_by(git_sha: platform.disk_image_git_sha)
        return [ nil, :pointer_inconsistent ] if pub.nil?
        # A pointer aimed at a row that never reached :published. The row is not
        # empty — uki_oci_ref/uki_sha256/uki_cosign_bundle are written at WEBHOOK
        # RECEIVE time (webhooks/disk_image_built_controller.rb), before any
        # cosign or sha256 verification — so the UKI guards below sail right past
        # an unverified build, and only publication state catches it.
        #
        # published_at, not status, is the discriminator: only mark_published and
        # reactivate ever set it (disk_image_publication.rb, events `mark_published`
        # and `reactivate`) and nothing clears it, while `retired` is also
        # reachable from failed/verifying via the stuck-build cleanup. Every
        # writer of disk_image_git_sha (DiskImagePublicationProcessor#publish!,
        # DiskImage::PromotePublication, DiskImage::RollbackPublication) sets
        # published_at in the SAME transaction as the pointer flip, so a
        # legitimately promoted row can never be caught here — including
        # transiently.
        #
        # This guard is ONLY sound because published_at cannot be set by a
        # transition whose guard failed (IMP-6d2dd4533bd7). Both
        # `mark_published` and `reactivate` used to stamp it via an
        # event-level `before`, which aasm 5.5.2 fires BEFORE the guard is
        # checked — so a guard-failing mark_published (a :verifying row with
        # no file_object_id) or reactivate (a :retired row with no
        # file_object_id) could forge a published_at that would sail
        # straight past this check. The fix moved both writes to a
        # transition-scoped `after`, which only fires once the guard has
        # already passed — see the `mark_published` and `reactivate` events
        # in disk_image_publication.rb for the full trace through the
        # aasm source. Do not weaken this discriminator without re-verifying
        # that invariant still holds.
        return [ pub, :never_published ] if pub.published_at.nil?
        # purge! nils file_object_id and hard-deletes the disk-image bytes but
        # (see DiskImagePublication#purge!) leaves published_at untouched —
        # nothing clears it, ever — so the guard above cannot tell a purged
        # row from a healthy one. Deliberately NOT reusing #promotable? here:
        # that guards file_object_id (the disk image), a DIFFERENT artifact
        # from the UKI this dispatcher actually serves (OCI-registry-hosted,
        # via OciBlobProxyService, independent of file_object) — and
        # promoted_pointer_publication_state_spec.rb already establishes that
        # a `retired` row must stay dispatchable for exactly that reason.
        # `purged` is the one status genuinely new-invalid here.
        return [ pub, :publication_purged ] if pub.purged?
        return [ pub, :no_uki_artifact ] if pub.uki_oci_ref.blank? || pub.uki_sha256.blank?

        cosign_key = platform_cosign_public_key
        return [ pub, :no_cosign_key ] if cosign_key.blank?
        return [ pub, :no_cosign_bundle ] if pub.uki_cosign_bundle.blank?

        [ pub, nil, cosign_key ]
      end

      # Instance-independent reasons a platform can't be upgraded right now, or
      # nil when a dispatch could proceed. The rollout executor calls this at PLAN
      # time so a plan surfaces "cannot dispatch: no cosign bundle" instead of a
      # green plan that would silently no-op on approval.
      def self.platform_blocker(platform)
        _pub, failure = preflight(platform)
        return nil if failure.nil?

        case failure
        when :no_platform           then "no resolvable node platform"
        when :no_promoted_image     then "platform has no promoted disk image"
        when :pointer_inconsistent
          "platform pointer inconsistent: no published record for promoted git_sha #{platform.disk_image_git_sha}"
        when :never_published
          "platform pointer names a publication that was never published (git_sha #{platform.disk_image_git_sha})"
        when :publication_purged
          "platform pointer names a publication that has been purged (git_sha #{platform.disk_image_git_sha}) — " \
          "its retention grace window expired and the platform no longer stands behind this build"
        when :no_uki_artifact       then "promoted image has no standalone UKI artifact"
        when :no_cosign_key         then "platform cosign public key (POWERNODE_COSIGN_PUBLIC_KEY) not configured"
        when :no_cosign_bundle      then "promoted image has no UKI cosign signature bundle"
          # A new .preflight symbol reaching here would fall through to nil,
          # which is indistinguishable from "not blocked" — the rollout would
          # plan GREEN and dispatch nothing. Fail loud instead.
        else raise ArgumentError, "unhandled preflight failure: #{failure.inspect}"
        end
      end

      def initialize(instance:, source:, initiated_by: nil, force: false)
        @instance = instance
        @source = source
        @initiated_by = initiated_by
        @force = force
      end

      def dispatch!
        platform = @instance.node&.node_platform
        # The UKI pins + cosign bundle come from the promoted PUBLICATION ROW
        # (single source of truth), NOT the NodePlatform.disk_image_uki_* columns:
        # a partial-field promote writer can leave those columns stale relative to
        # disk_image_git_sha, smearing a mismatched (uki, bundle) pair into the
        # task → cosign verify fails on-node (campaign 019f505f). .preflight
        # resolves the publication matching the promoted sha and runs the guard
        # chain the plan-time blocker shares, so a dispatch is self-consistent
        # with the plan that authorized it.
        promoted_pub, failure, cosign_pubkey = self.class.preflight(platform)
        return err(dispatch_failure_message(failure, platform)) if failure

        target_sha    = platform.disk_image_git_sha
        cosign_bundle = promoted_pub.uki_cosign_bundle

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
            "uki_oci_ref"          => promoted_pub.uki_oci_ref,
            "uki_sha256"           => promoted_pub.uki_sha256,
            "cosign_public_key"    => cosign_pubkey,
            "cosign_bundle_b64"    => cosign_bundle,
            "download_path"        => download_path_for(promoted_pub),
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

      # The node GETs this path VERBATIM — it is server-authored task data, not
      # an agent constant (agent/internal/runtime/tasks/handlers/upgrade_boot_image.go
      # reads it with a plain string cast, and bootupgrade.go concatenates it
      # onto the platform URL with no parsing). Pinning the digest into it is
      # therefore how the download endpoint learns WHICH artifact this task was
      # pinned to, with no agent change and no fleet rollout.
      #
      # Without the pin, the endpoint can only serve whatever is promoted at
      # download time: a promote landing between dispatch and execution swaps the
      # bytes under an in-flight task and the node aborts on "UKI sha256
      # mismatch" (IMP-b55869029a57). Fail-closed on-node, but every in-flight
      # upgrade dies during any promote window.
      #
      # This is the SAME digest carried in the uki_sha256 option the agent
      # verifies the downloaded bytes against — one value, so the artifact
      # requested and the artifact accepted cannot drift apart. The endpoint
      # still honors an unparameterized path, which is what tasks queued before
      # this change carry.
      # .preflight already refused the dispatch (:no_uki_artifact) when the
      # publication carries no uki_sha256, so the digest is present here.
      def download_path_for(publication)
        "#{DOWNLOAD_PATH}?digest=#{publication.uki_sha256}"
      end

      # Operator-facing wording for each .preflight failure. Deliberately more
      # verbose than platform_blocker's plan-time phrasing (which is embedded in
      # a halt_reason) — same conditions, different audience.
      def dispatch_failure_message(failure, platform)
        case failure
        when :no_platform       then "Instance has no resolvable node platform"
        when :no_promoted_image then "Platform has no promoted disk image to upgrade to"
        when :pointer_inconsistent
          "Platform pointer inconsistent: no published record for promoted git_sha #{platform.disk_image_git_sha}"
        when :never_published
          "Platform pointer names a publication that was never published (git_sha " \
          "#{platform.disk_image_git_sha}) — its artifacts never passed cosign/sha verification. " \
          "Promote a published publication before upgrading."
        when :publication_purged
          "Platform pointer names a publication that has been purged (git_sha " \
          "#{platform.disk_image_git_sha}) — its retention grace window expired and the platform " \
          "no longer stands behind this build. Promote a current publication before upgrading."
        when :no_uki_artifact
          "Promoted image has no standalone UKI artifact (built before the in-place-upgrade CI) — " \
          "republish/promote a newer image to enable boot-image upgrades"
        when :no_cosign_key
          "Refusing boot-image upgrade: the platform cosign public key " \
          "(POWERNODE_COSIGN_PUBLIC_KEY / _FILE) is not configured — the node could not verify the pulled UKI"
        when :no_cosign_bundle
          "Promoted image has no UKI cosign signature bundle — cannot dispatch an unverifiable boot-image upgrade"
          # Falling through to nil here would produce err(nil), and Result#ok?
          # is `reason.nil?` — so an unhandled guard would read as SUCCESS to
          # every caller, which then dereferences a nil task. Fail loud instead.
        else raise ArgumentError, "unhandled preflight failure: #{failure.inspect}"
        end
      end

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
