# frozen_string_literal: true

module System
  # Tracks an in-flight storage migration: moving a stateful
  # component's data (e.g. /var/lib/postgresql) from one
  # ProviderVolume to another while preserving the
  # (deployment, role) binding. Distinct from System::Migration
  # which is cross-peer record transfer.
  #
  # State machine:
  #
  #   planned ──approve──> approved ──prepare──> preparing
  #     │                    │                       │
  #     │                    │                       ▼
  #     │                    │                    syncing
  #     │                    │                       │
  #     │                    │                       ▼
  #     │                    │                   verifying
  #     │                    │                       │
  #     │                    │                       ▼
  #     │                    │                    cutover
  #     │                    │                       │
  #     │                    │                       ▼
  #     └───cancel───┐ ┌────cancel────┐ ┌──────> completed (terminal)
  #                  ▼ ▼              ▼
  #               cancelled        failed (terminal at any non-terminal)
  #
  # The state advance happens server-side on operator/agent action;
  # the actual data copy (rsync) runs on the on-node Go agent.
  #
  # Plan reference: E7.2.
  class StorageMigration < BaseRecord
    include System::Base

    # Increment 9 — revert/cleanup are orthogonal to `status`: they
    # track the consistency of the physical node binding, not whether
    # the copy operation itself succeeded. Both live entirely in
    # `metadata` (no new columns — the jsonb column already carries
    # everything a revert/cleanup lifecycle needs).
    DEFAULT_CLEANUP_GRACE_HOURS = 24
    CLEANUP_GRACE_HOURS_SETTING_KEY = "system.storage.migration.cleanup_grace_hours"

    STATUSES = %w[
      planned approved preparing syncing verifying cutover
      completed failed cancelled
    ].freeze
    TERMINAL_STATUSES = %w[completed failed cancelled].freeze
    NON_TERMINAL_STATUSES = STATUSES - TERMINAL_STATUSES

    # Valid forward transitions. Any non-terminal state can transition
    # to `failed` (set via #mark_failed!); planned/approved/preparing
    # can transition to `cancelled` via #cancel!.
    TRANSITIONS = {
      "planned"   => %w[approved cancelled failed],
      "approved"  => %w[preparing cancelled failed],
      "preparing" => %w[syncing cancelled failed],
      "syncing"   => %w[verifying failed],
      "verifying" => %w[cutover failed],
      "cutover"   => %w[completed failed],
      "completed" => [],
      "failed"    => [],
      "cancelled" => []
    }.freeze

    self.table_name = "system_storage_migrations"

    belongs_to :account
    belongs_to :node_instance, class_name: "System::NodeInstance"
    belongs_to :source_volume, class_name: "System::ProviderVolume"
    belongs_to :target_volume, class_name: "System::ProviderVolume"
    belongs_to :initiated_by_user, class_name: "User", optional: true

    attribute :plan,      :jsonb, default: -> { {} }
    attribute :audit_log, :jsonb, default: -> { [] }
    attribute :metadata,  :jsonb, default: -> { {} }

    validates :role, presence: true, length: { maximum: 64 }
    validates :status, presence: true, inclusion: { in: STATUSES }
    validate  :source_not_target

    scope :active,   -> { where.not(status: TERMINAL_STATUSES) }
    scope :terminal, -> { where(status: TERMINAL_STATUSES) }
    scope :for_instance, ->(id) { where(node_instance_id: id) }
    # Terminal migrations with a pending revert/cleanup intent still
    # need to reach the on-node agent — see node_api#index, which
    # unions this with `active` since the agent's poll loop otherwise
    # only ever sees non-terminal rows.
    scope :pending_binding_intent, -> {
      where("metadata->>'revert_status' = 'requested' OR metadata->>'cleanup_status' = 'requested'")
    }

    class << self
      # Grace-window resolution (config-driven-config convention —
      # mirrors Ai::FableRouting.enabled_for?): 1) Account#settings
      # override, 2) SiteSetting global default, 3) baked-in default.
      # No hardcoded constant reaches callers unqualified.
      def cleanup_grace_hours(account:)
        account_value = account.respond_to?(:settings) ? account.settings&.dig(CLEANUP_GRACE_HOURS_SETTING_KEY) : nil
        return account_value.to_i.clamp(0, 24 * 90) if account_value.present?

        site_value = begin
          ::SiteSetting.get(CLEANUP_GRACE_HOURS_SETTING_KEY)
        rescue StandardError
          nil
        end
        return site_value.to_i.clamp(0, 24 * 90) if site_value.present?

        DEFAULT_CLEANUP_GRACE_HOURS
      end
    end

    def terminal?
      TERMINAL_STATUSES.include?(status)
    end

    def can_transition_to?(target)
      TRANSITIONS.fetch(status, []).include?(target.to_s)
    end

    # Append an audit entry capturing the transition. Caller passes a
    # description; we stamp at + status_before / status_after. The
    # audit_log is the operator-visible timeline.
    def transition_to!(new_status, message: nil, details: {})
      raise ArgumentError, "Invalid status #{new_status}" unless STATUSES.include?(new_status.to_s)
      raise ArgumentError, "Illegal transition #{status} → #{new_status}" unless can_transition_to?(new_status)

      append_audit!(
        message: message,
        status_before: status,
        status_after: new_status.to_s,
        details: details
      )

      attrs = { status: new_status.to_s }
      attrs[:approved_at]  = Time.current if new_status.to_s == "approved"
      attrs[:started_at]   = Time.current if new_status.to_s == "preparing" && started_at.blank?
      attrs[:completed_at] = Time.current if new_status.to_s == "completed"
      attrs[:failed_at]    = Time.current if new_status.to_s == "failed"
      attrs[:cancelled_at] = Time.current if new_status.to_s == "cancelled"
      update!(attrs)
      promote_target_binding! if new_status.to_s == "completed"
      self
    end

    # When the agent reports cutover → completed, swap the instance's
    # storage_volume binding from source → target so subsequent reads
    # of NodeInstance.config["storage_volume"] (heartbeat fetches,
    # post-restart agent boot) see the new home. Without this swap,
    # the migration's data lives at the target but the instance keeps
    # mounting source — a silent half-cutover.
    #
    # Mirrors PlatformDeploymentOrchestrator#attach_storage_volume!
    # binding shape so the agent reuses the same mount.ReconcileStorageVolume
    # code path with no extra branching.
    def promote_target_binding!
      return unless node_instance && target_volume

      previous = node_instance.config&.dig("storage_volume") || {}
      # Persist the pre-promotion binding BEFORE attempting the mutation
      # below, so it survives even if node_instance.update! raises —
      # closes the gap where `previous` used to live only in a local
      # var and was lost the moment this method returned. This is the
      # exact source revert_binding! reconstructs from when a
      # "completed" migration never actually promoted (see rescue).
      update!(metadata: metadata.merge("prior_binding" => previous))

      transport = target_volume.volume_type&.volume_type.to_s
      mount_point = previous["mount_point"].presence ||
                    ::System::Platform::StorageRecommendations.mount_point_for(
                      account: account, role: role
                    )

      new_binding = previous.merge(
        "volume_id"    => target_volume.id,
        "volume_name"  => target_volume.name,
        "size_gb"      => target_volume.size_gb,
        "transport"    => transport,
        "mount_type"   => %w[nfs smb iscsi].include?(transport) ? transport : "device",
        "mount_point"  => mount_point,
        "role"         => role,
        "subpath"      => target_subpath,
        "attached_at"  => Time.current.iso8601
      )

      if %w[nfs smb iscsi].include?(transport) && target_volume.config.is_a?(Hash) &&
         target_volume.config[transport].is_a?(Hash)
        transport_cfg = target_volume.config[transport].dup
        transport_cfg["subpath"] = target_subpath
        if transport == "nfs"
          server = transport_cfg["server"].to_s
          export = transport_cfg["export_path"].to_s.chomp("/")
          transport_cfg["full_export_path"] = "#{server}:#{export}/#{target_subpath.to_s.delete_prefix('/')}" if server.present? && export.present?
        end
        new_binding[transport] = transport_cfg
        new_binding.delete("device_name")
      end

      # Only `storage_volume` — see System::ConfigDocument. `node_instance` is
      # an association on a migration row that has been open across a sync and
      # a cutover, so its document is arbitrarily old.
      node_instance.merge_config!("storage_volume" => new_binding)
      append_audit!(
        message: "Promoted binding to target volume #{target_volume.id}",
        details: { volume_id: target_volume.id, subpath: target_subpath }
      )
    rescue StandardError => e
      Rails.logger.warn("[StorageMigration#promote_target_binding!] failed: #{e.message}")
      # `promote_failed` is the discriminator revert_binding! uses to
      # allow reverting a "completed" migration: cutover already
      # physically re-pointed the node to target, but this bookkeeping
      # update never landed — node_instance.config still (accidentally)
      # says source, so the DB and physical reality disagree.
      update!(metadata: metadata.merge(
        "promote_failed"    => true,
        "promote_failed_at" => Time.current.iso8601,
        "promote_error"     => e.message
      ))
      append_audit!(message: "promote_target_binding! warning: #{e.message}")
    end

    def append_audit!(message: nil, status_before: nil, status_after: nil, details: {})
      entry = {
        "at" => Time.current.iso8601,
        "message" => message,
        "status_before" => status_before,
        "status_after" => status_after,
        "details" => details
      }.compact
      self.audit_log = Array(audit_log) + [ entry ]
      save!
    end

    # Failure shortcut — valid from any non-terminal state.
    def mark_failed!(reason:)
      return if terminal?

      # A failure reported while status=="cutover" means the agent was
      # mid-way through re-pointing the consumer's canonical mount when
      # it gave up — the mount may already be sitting on target (or on
      # neither source nor target, if it failed between the umount and
      # the remount) while node_instance.config still says source
      # (promote_target_binding! only ever runs on completed). This
      # flag is purely a UI/runbook signal for "revert is worth
      # recommending here" — see #can_revert_binding? for the actual
      # reachability gate, which is deliberately broader (any `failed`
      # migration) since re-mounting source when it's already source
      # is a safe no-op.
      diverged = status == "cutover"
      if diverged
        self.metadata = metadata.merge(
          "cutover_diverged"    => true,
          "cutover_diverged_at" => Time.current.iso8601
        )
      end
      append_audit!(message: "Migration failed: #{reason}", status_before: status, status_after: "failed")
      update!(status: "failed", failed_at: Time.current, error_message: reason)
    end

    # Cancellation — valid only before sync starts.
    def cancel!(reason: nil, user: nil)
      return if terminal?
      unless %w[planned approved preparing].include?(status)
        raise ArgumentError, "Cannot cancel — sync already in progress (status=#{status})"
      end
      append_audit!(
        message: reason.to_s.presence || "Cancelled",
        status_before: status, status_after: "cancelled",
        details: user ? { cancelled_by_user_id: user.id } : {}
      )
      update!(status: "cancelled", cancelled_at: Time.current)
    end

    # Progress reporting from the on-node agent. Lets the operator
    # follow along during syncing/verifying without poking the agent
    # directly.
    def report_progress!(bytes_copied: nil, bytes_total: nil, bytes_verified: nil, note: nil)
      attrs = {}
      attrs[:bytes_copied]   = bytes_copied   if bytes_copied
      attrs[:bytes_total]    = bytes_total    if bytes_total
      attrs[:bytes_verified] = bytes_verified if bytes_verified
      update!(attrs) unless attrs.empty?
      append_audit!(message: note, details: attrs) if note || !attrs.empty?
    end

    # === Increment 9 — revert_binding! (R) ==================================
    #
    # Re-points the consumer's canonical mount back to source: the
    # inverse of the cutover step. Reachable from `failed` (any
    # cutover-phase failure, per mark_failed! above — re-mounting an
    # already-source binding is a safe no-op if the mount never
    # actually moved) and from `completed` when promote_target_binding!
    # raised + was rescued (the swallowed half-cutover: cutover
    # physically succeeded but the DB bookkeeping update never landed).
    #
    # This method only records intent + audits — the NODE does the
    # actual mount work. See node_api/storage_migrations_controller.rb
    # (index surfaces `revert_requested`) and the Go agent's
    # migration.Runner#stepRevert.
    def can_revert_binding?
      status == "failed" || (status == "completed" && !!ActiveModel::Type::Boolean.new.cast(metadata["promote_failed"]))
    end

    def revert_binding!(reason: nil, user: nil)
      raise ArgumentError, "Cannot revert binding from status=#{status}" unless can_revert_binding?

      self.metadata = metadata.merge(
        "revert_status"               => "requested",
        "revert_requested_at"         => Time.current.iso8601,
        "revert_reason"               => reason,
        "revert_requested_by_user_id" => user&.id
      )
      append_audit!(
        message: "Revert-to-source requested by #{user&.email || 'system'}" \
                 "#{reason.present? ? ": #{reason}" : ''}",
        details: { revert_requested_by_user_id: user&.id, reason: reason }.compact
      )
      self
    end

    # Called by node_api once the agent reports the mount is back on
    # source. `artifacts` is the agent's per-step report (e.g. the
    # canonical path it remounted) — one audit entry per artifact so
    # the trail names the exact path + actor, matching cleanup's
    # per-artifact audit convention below.
    def revert_completed!(artifacts: [])
      self.metadata = metadata.merge("revert_status" => "completed", "reverted_at" => Time.current.iso8601)
      entries = Array(artifacts)
      if entries.empty?
        append_audit!(message: "Binding reverted to source (agent)")
      else
        entries.each { |artifact| append_audit!(message: "Reverted: #{artifact_path(artifact)}", details: artifact_details(artifact)) }
      end
      self
    end

    def revert_failed!(reason:)
      self.metadata = metadata.merge("revert_status" => "failed", "revert_error" => reason)
      append_audit!(message: "Revert failed: #{reason}")
      self
    end

    # === Increment 9 — cleanup (C) ===========================================
    #
    # Destructive, target-side, subpath-scoped only: the target volume
    # is never attach_volume-bound during a migration, so a
    # volume-level delete could reach OTHER deployments' data on
    # shared NFS — this method (and the agent side) only ever operate
    # on target_subpath / snapshot_subpath, never the volume or
    # source. Reachable only from `failed`, or `cancelled` once
    # preparing was actually reached (started_at present) — an early
    # cancel before preparing never touched the target, so there is
    # nothing to clean.
    #
    # Explicit operator action only — nothing in this codebase calls
    # this automatically on failure (partial target data is
    # forensically useful while triaging).
    def can_cleanup?
      status == "failed" || (status == "cancelled" && started_at.present?)
    end

    def cleanup_available_at(grace_hours:)
      (failed_at || cancelled_at || updated_at) + grace_hours.to_i.hours
    end

    def request_cleanup!(reason: nil, user: nil, grace_hours: DEFAULT_CLEANUP_GRACE_HOURS, immediate: false)
      raise ArgumentError, "Cannot clean up from status=#{status}" unless can_cleanup?

      unless immediate
        available_at = cleanup_available_at(grace_hours: grace_hours)
        if Time.current < available_at
          remaining_hours = ((available_at - Time.current) / 1.hour).ceil
          raise ArgumentError,
                "Cleanup grace window not yet elapsed — #{remaining_hours}h remaining " \
                "(pass immediate: true to override)"
        end
      end

      self.metadata = metadata.merge(
        "cleanup_status"              => "requested",
        "cleanup_requested_at"        => Time.current.iso8601,
        "cleanup_reason"              => reason,
        "cleanup_requested_by_user_id" => user&.id,
        "cleanup_grace_hours"         => grace_hours,
        "cleanup_immediate"           => immediate
      )
      append_audit!(
        message: "Cleanup requested by #{user&.email || 'system'}" \
                 "#{immediate ? ' (immediate)' : ''}#{reason.present? ? ": #{reason}" : ''}",
        details: { cleanup_requested_by_user_id: user&.id, reason: reason, immediate: immediate }.compact
      )
      self
    end

    # Called by node_api once the agent reports the target-side
    # artifacts are gone. One audit entry per artifact naming the
    # exact path + whether it was already clean (idempotent re-entry)
    # — the audit trail is the record of what got deleted where.
    def cleanup_completed!(artifacts: [])
      self.metadata = metadata.merge("cleanup_status" => "completed", "cleaned_at" => Time.current.iso8601)
      entries = Array(artifacts)
      if entries.empty?
        append_audit!(message: "Cleanup completed (agent reported no artifacts)")
      else
        entries.each do |artifact|
          details = artifact_details(artifact)
          already_clean = ActiveModel::Type::Boolean.new.cast(details["already_clean"])
          append_audit!(
            message: "Cleaned #{artifact_path(artifact)}#{already_clean ? ' (already clean)' : ''}",
            details: details
          )
        end
      end
      self
    end

    def cleanup_failed!(reason:)
      self.metadata = metadata.merge("cleanup_status" => "failed", "cleanup_error" => reason)
      append_audit!(message: "Cleanup failed: #{reason}")
      self
    end

    private

    def artifact_details(artifact)
      artifact.is_a?(Hash) ? artifact.to_h.stringify_keys : { "raw" => artifact }
    end

    def artifact_path(artifact)
      details = artifact_details(artifact)
      details["path"].presence || details["mount_point"].presence || details["label"].presence || "artifact"
    end

    def source_not_target
      return if source_volume_id.blank? || target_volume_id.blank?
      return if source_volume_id != target_volume_id
      errors.add(:target_volume_id, "must differ from source_volume_id")
    end
  end
end
