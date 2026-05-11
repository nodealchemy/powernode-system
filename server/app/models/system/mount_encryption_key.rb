# frozen_string_literal: true

module System
  class MountEncryptionKey < BaseRecord
    include System::Base
    include ::VaultCredential

    self.vault_credential_type = "mount_encryption_key"

    ALGORITHMS = %w[aes-xts-plain64 aes-256-gcm fscrypt-v2].freeze

    belongs_to :storage_assignment, class_name: "System::StorageAssignment"
    belongs_to :node_instance, class_name: "::System::NodeInstance", optional: true
    # node_instance nil → mount-wide key (fscrypt). Present → per-instance LUKS slot.

    delegate :account, to: :storage_assignment
    delegate :account_id, to: :storage_assignment

    validates :algorithm, inclusion: { in: ALGORITHMS }

    scope :active, -> { where(revoked_at: nil) }
    scope :revoked, -> { where.not(revoked_at: nil) }

    def revoked?
      revoked_at.present?
    end

    def revoke!
      update!(revoked_at: Time.current)
    end
  end
end
