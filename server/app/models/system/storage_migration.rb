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

      node_instance.update!(config: (node_instance.config || {}).merge("storage_volume" => new_binding))
      append_audit!(
        message: "Promoted binding to target volume #{target_volume.id}",
        details: { volume_id: target_volume.id, subpath: target_subpath }
      )
    rescue StandardError => e
      Rails.logger.warn("[StorageMigration#promote_target_binding!] failed: #{e.message}")
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

    private

    def source_not_target
      return if source_volume_id.blank? || target_volume_id.blank?
      return if source_volume_id != target_volume_id
      errors.add(:target_volume_id, "must differ from source_volume_id")
    end
  end
end
