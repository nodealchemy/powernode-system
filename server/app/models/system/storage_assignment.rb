# frozen_string_literal: true

module System
  class StorageAssignment < BaseRecord
    include System::Base

    STATUSES = %w[pending provisioning mounted degraded unmounting failed disabled].freeze
    ENCRYPTION_MODES = %w[inherit none fscrypt luks client_side_aes].freeze

    # Fleet-wide Unix-identity ownership model (replaces the legacy
    # per-instance hashed derived_uid).
    OWNER_KINDS  = %w[service_user operator nobody root].freeze
    CHOWN_STATES = %w[complete pending running failed manual_required].freeze

    # Numeric IDs for non-service-account owner_kinds — they live in
    # the agent's etcidentity.Baseline (not the platform-allocated
    # 70000..99999 range), so the model knows them statically.
    BASELINE_UIDS = {
      "operator" => 1_000,
      "nobody"   => 65_534,
      "root"     => 0
    }.freeze
    BASELINE_GIDS = BASELINE_UIDS.dup.freeze

    belongs_to :account
    belongs_to :node_instance, class_name: "::System::NodeInstance"
    belongs_to :sdwan_network, class_name: "::Sdwan::Network", optional: true
    belongs_to :sdwan_virtual_ip, class_name: "::Sdwan::VirtualIp", optional: true

    # Owner of the storage's on-disk files. service_user_id is non-null
    # iff owner_kind == "service_user" (enforced by check constraint).
    # shared_group_id is an optional override of anongid for multi-
    # service write-shared mounts.
    belongs_to :service_user, class_name: "::System::ServiceUser", optional: true
    belongs_to :shared_group,
               class_name: "::System::ServiceGroup",
               foreign_key: :shared_group_id,
               optional: true

    has_many :storage_credentials, class_name: "System::StorageCredential", dependent: :destroy
    has_many :mount_encryption_keys, class_name: "System::MountEncryptionKey", dependent: :destroy

    validates :file_storage_id, presence: true
    validates :mount_path, presence: true, format: { with: %r{\A/[\w/.\-]+\z}, message: "must be an absolute path" }
    validates :status, inclusion: { in: STATUSES }
    validates :encryption_mode, inclusion: { in: ENCRYPTION_MODES }
    validates :owner_kind, inclusion: { in: OWNER_KINDS }
    validates :chown_state, inclusion: { in: CHOWN_STATES }
    validates :service_user, presence: true, if: :service_user_owner?
    validate :file_storage_must_exist
    validate :file_storage_must_be_node_mount_capable
    validate :encryption_mode_compatible_with_provider
    validate :service_user_absent_unless_service_user_owner
    validate :owner_change_blocked_while_chown_in_flight, on: :update

    scope :enabled, -> { where(enabled: true) }
    scope :auto_mounting, -> { enabled.where(auto_mount: true) }
    scope :pending_reconcile, -> { enabled.where(status: %w[pending provisioning degraded failed]) }
    scope :mounted, -> { where(status: "mounted") }
    scope :chown_in_flight, -> { where(chown_state: %w[pending running]) }

    before_update :capture_pending_chown,
                  if: -> { will_save_change_to_owner_kind? ||
                          will_save_change_to_service_user_id? ||
                          will_save_change_to_shared_group_id? }

    after_commit :trigger_reconcile, on: [ :create, :update ], if: :should_trigger_reconcile?
    after_commit :dispatch_chown_if_pending, on: :update

    # ----- Identity dispatch (replaces the legacy derived_uid) -----

    # UID that NFS exports, mount payloads, and storage credentials use
    # for file ownership. Replaces System::StorageAssignment#derived_uid
    # (a hash of node_instance_id). Dispatches on owner_kind:
    #
    #   service_user → the platform-allocated ServiceUser's UID
    #                  (70000..99999 range)
    #   operator     → 1000 (matches agent's etcidentity.Baseline)
    #   nobody       → 65534 (NFS root-squash default)
    #   root         → 0
    def anonuid
      case owner_kind
      when "service_user"
        service_user&.uid or raise("service_user_id missing on assignment #{id} despite owner_kind=service_user")
      else
        BASELINE_UIDS.fetch(owner_kind)
      end
    end

    # GID for NFS exports. Defaults to the owner's primary group; if a
    # shared_group is set, that overrides — used for multi-service
    # write-shared mounts where the GID is the unifying access bit
    # (operator picks a group both services join, sets shared_group_id,
    # sets the mount mode to 0775).
    def anongid
      shared_group&.gid || default_gid
    end

    # Human-readable owner identifier for audit logs + operator UI.
    def owner_username
      case owner_kind
      when "service_user" then service_user&.username
      else                     owner_kind
      end
    end

    def owner_groupname
      shared_group&.groupname ||
        (service_user_owner? ? service_user&.primary_groupname : owner_kind)
    end

    # ----- Chown lifecycle predicates -----

    def chown_in_flight?
      %w[pending running].include?(chown_state)
    end

    def chown_failed?
      chown_state == "failed"
    end

    def chown_complete?
      chown_state == "complete"
    end

    # ----- Owner-kind predicates -----

    def service_user_owner?
      owner_kind == "service_user"
    end

    # ----- NFS-export effective UID/GID -----
    #
    # During an in-flight chown, the NFS export config on disk should
    # keep using the PREVIOUS owner so consuming services don't see
    # EACCES when the agent flips file ownership. Once chown completes,
    # the worker_api callback transitions chown_state -> complete,
    # triggers reconcile_assignment!, and NFS exports re-render using
    # the new anonuid/anongid (returned by the standard accessors above).
    def effective_export_uid
      chown_in_flight? ? chown_previous_uid : anonuid
    end

    def effective_export_gid
      chown_in_flight? ? chown_previous_gid : anongid
    end

    # ----- Existing soft-fetch + helpers -----

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

    def default_gid
      case owner_kind
      when "service_user" then service_user&.primary_gid
      else                     BASELINE_GIDS.fetch(owner_kind)
      end
    end

    def should_trigger_reconcile?
      # Only enqueue reconciliation when the assignment is enabled AND a
      # field that affects mount state changed (or it's a brand-new row).
      return true if saved_change_to_id?

      enabled? && (
        saved_change_to_enabled? ||
        saved_change_to_mount_path? ||
        saved_change_to_mount_options? ||
        saved_change_to_encryption_mode? ||
        saved_change_to_auto_mount? ||
        saved_change_to_owner_kind? ||
        saved_change_to_service_user_id? ||
        saved_change_to_shared_group_id? ||
        saved_change_to_chown_state?
      )
    end

    def trigger_reconcile
      ::System::Storage::AssignmentReconciliationService.reconcile_assignment!(self)
    rescue StandardError => e
      Rails.logger.error("[StorageAssignment##{id}] reconcile dispatch failed: #{e.class}: #{e.message}")
    end

    # When ownership fields are about to change, snapshot the
    # PRE-CHANGE effective UID/GID so the agent's chown task knows
    # the source ownership to look for on disk.
    #
    # Subtle: `before_update` runs AFTER attribute assignment but BEFORE
    # the SQL UPDATE commits. The `service_user` association would
    # resolve via the NEW service_user_id (the assigned attribute value),
    # NOT the old one. We use `*_in_database` accessors which return the
    # persisted (pre-change) values, then look up the OLD records
    # explicitly to compute what anonuid/anongid USED to be.
    def capture_pending_chown
      return if chown_in_flight?
      self.chown_previous_uid = persisted_anonuid
      self.chown_previous_gid = persisted_anongid
      self.chown_state        = "pending"
      self.chown_last_error   = nil
      self.chown_completed_at = nil
      self.chown_task_id      = nil
    end

    def persisted_anonuid
      prev_kind = owner_kind_in_database || owner_kind
      case prev_kind
      when "service_user"
        prev_id = service_user_id_in_database || service_user_id
        prev_id ? ::System::ServiceUser.where(id: prev_id).pick(:uid) : nil
      else
        BASELINE_UIDS[prev_kind]
      end
    end

    def persisted_anongid
      prev_shared = shared_group_id_in_database || shared_group_id
      return ::System::ServiceGroup.where(id: prev_shared).pick(:gid) if prev_shared.present?

      prev_kind = owner_kind_in_database || owner_kind
      case prev_kind
      when "service_user"
        prev_id = service_user_id_in_database || service_user_id
        prev_id ? ::System::ServiceUser.where(id: prev_id).joins(:primary_group).pick("system_service_groups.gid") : nil
      else
        BASELINE_GIDS[prev_kind]
      end
    end

    # After the owner change commits, queue an agent task to chown the
    # files on disk. Failure to dispatch is logged but doesn't roll
    # back the commit — the operator can retry via
    # `system_storage_chown_retry`.
    def dispatch_chown_if_pending
      return unless chown_state == "pending"
      ::System::Storage::ChownDispatchService.dispatch!(self)
    rescue StandardError => e
      Rails.logger.error("[StorageAssignment##{id}] chown dispatch failed: #{e.class}: #{e.message}")
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

    def service_user_absent_unless_service_user_owner
      return if service_user_owner?
      return if service_user_id.blank?
      errors.add(:service_user_id,
                 "must be blank when owner_kind is #{owner_kind.inspect}")
    end

    # Reject ownership-field changes while a chown is in flight. Two
    # near-simultaneous owner changes would either lose the second
    # change's intent or end up chowning files to an intermediate UID
    # that no one wants. Operator must wait for the in-flight chown to
    # complete (or use system_storage_chown_retry with force_complete:
    # true to abandon it) before re-changing ownership.
    def owner_change_blocked_while_chown_in_flight
      return unless persisted?
      return unless chown_in_flight?
      return unless will_save_change_to_owner_kind? ||
                    will_save_change_to_service_user_id? ||
                    will_save_change_to_shared_group_id?

      errors.add(:base,
                 "cannot change owner while previous chown is in flight " \
                 "(chown_state=#{chown_state}); wait for completion or " \
                 "call system_storage_chown_retry with force_complete: true")
    end
  end
end
