# frozen_string_literal: true

module System
  class StorageCredential < BaseRecord
    include System::Base
    include ::VaultCredential

    self.vault_credential_type = "storage_node_access"

    KINDS = %w[peer_ip_acl cifs_user_pass sts_token tls_cert webdav_basic].freeze
    STATUSES = %w[issued active rotating revoked expired failed].freeze

    belongs_to :storage_assignment, class_name: "System::StorageAssignment"
    belongs_to :node_instance, class_name: "::System::NodeInstance"

    delegate :account, to: :storage_assignment
    delegate :account_id, to: :storage_assignment

    validates :kind, inclusion: { in: KINDS }
    validates :status, inclusion: { in: STATUSES }

    scope :active, -> { where(status: %w[issued active]) }
    scope :rotating, -> { where(status: "rotating") }
    scope :expired_or_failed, -> { where(status: %w[expired failed revoked]) }

    def expired?
      expires_at.present? && expires_at <= Time.current
    end

    def needs_rotation?(window: 1.day)
      expires_at.present? && expires_at <= window.from_now
    end

    def activate!
      update!(status: "active")
    end

    def mark_rotating!
      update!(status: "rotating")
    end

    def revoke!
      update!(status: "revoked")
    end
  end
end
