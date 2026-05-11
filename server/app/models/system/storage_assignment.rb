# frozen_string_literal: true

module System
  class StorageAssignment < BaseRecord
    include System::Base

    STATUSES = %w[pending provisioning mounted degraded unmounting failed disabled].freeze
    ENCRYPTION_MODES = %w[inherit none fscrypt luks client_side_aes].freeze

    belongs_to :account
    belongs_to :node_instance, class_name: "::System::NodeInstance"
    belongs_to :sdwan_network, class_name: "::Sdwan::Network", optional: true
    belongs_to :sdwan_virtual_ip, class_name: "::Sdwan::VirtualIp", optional: true

    has_many :storage_credentials, class_name: "System::StorageCredential", dependent: :destroy
    has_many :mount_encryption_keys, class_name: "System::MountEncryptionKey", dependent: :destroy

    validates :file_storage_id, presence: true
    validates :mount_path, presence: true, format: { with: %r{\A/[\w/.\-]+\z}, message: "must be an absolute path" }
    validates :status, inclusion: { in: STATUSES }
    validates :encryption_mode, inclusion: { in: ENCRYPTION_MODES }
    validate :file_storage_must_exist
    validate :file_storage_must_be_node_mount_capable
    validate :encryption_mode_compatible_with_provider

    scope :enabled, -> { where(enabled: true) }
    scope :auto_mounting, -> { enabled.where(auto_mount: true) }
    scope :pending_reconcile, -> { enabled.where(status: %w[pending provisioning degraded failed]) }
    scope :mounted, -> { where(status: "mounted") }

    after_commit :trigger_reconcile, on: [:create, :update], if: :should_trigger_reconcile?

    # Deterministic POSIX UID derived from the node instance UUID. Used as
    # `anonuid` in the NFS export to flatten on-node identity to a single
    # platform-controlled UID per instance (paired with all_squash).
    # Formula yields 100k unique slots per account; collisions surface in
    # CredentialIssuer audit metadata.
    def derived_uid
      base = 100_000
      base + (node_instance_id.to_s.delete("-").to_i(16) % 100_000)
    end

    # Soft fetch — file_management_storages lives in the platform table set.
    def file_storage
      @file_storage ||= ::FileManagement::Storage.find_by(id: file_storage_id)
    end

    # Resolve `inherit` to the storage's per-provider default. Network types
    # default to fscrypt, block to luks, object to client_side_aes, local to none.
    def effective_encryption_mode
      return encryption_mode unless encryption_mode == "inherit"

      storage = file_storage
      return "none" unless storage

      case storage.provider_type
      when "nfs", "smb"      then "fscrypt"
      when "ebs"             then "luks"
      when "s3", "gcs", "azure" then "client_side_aes"
      else "none"
      end
    end

    def requires_credential?
      file_storage&.requires_node_credentials == true
    end

    def active_credential
      storage_credentials.where(status: %w[issued active]).order(created_at: :desc).first
    end

    # Lifecycle helpers
    def mark_status!(new_status, error_message: nil)
      update!(
        status: new_status,
        last_status_at: Time.current,
        last_mounted_at: new_status == "mounted" ? Time.current : last_mounted_at,
        error_message: error_message
      )
    end

    private

    def should_trigger_reconcile?
      # Only enqueue reconciliation when the assignment is enabled AND a
      # field that affects mount state changed (or it's a brand-new row).
      return true if saved_change_to_id?

      enabled? && (
        saved_change_to_enabled? ||
        saved_change_to_mount_path? ||
        saved_change_to_mount_options? ||
        saved_change_to_encryption_mode? ||
        saved_change_to_auto_mount?
      )
    end

    def trigger_reconcile
      ::System::Storage::AssignmentReconciliationService.reconcile_assignment!(self)
    rescue StandardError => e
      Rails.logger.error("[StorageAssignment##{id}] reconcile dispatch failed: #{e.class}: #{e.message}")
    end

    def file_storage_must_exist
      return if file_storage.present?

      errors.add(:file_storage_id, "must reference an existing FileManagement::Storage")
    end

    def file_storage_must_be_node_mount_capable
      return unless file_storage

      unless file_storage.node_mount_capable
        errors.add(:file_storage_id, "storage is not flagged node_mount_capable")
      end
    end

    def encryption_mode_compatible_with_provider
      return unless file_storage

      effective = effective_encryption_mode
      provider_type = file_storage.provider_type

      case effective
      when "luks"
        unless %w[ebs custom].include?(provider_type)
          errors.add(:encryption_mode, "LUKS requires block storage (ebs/custom)")
        end
      when "client_side_aes"
        unless %w[s3 gcs azure].include?(provider_type)
          errors.add(:encryption_mode, "client_side_aes only valid for object storage (s3/gcs/azure)")
        end
      end
    end
  end
end
