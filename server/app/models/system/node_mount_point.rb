# frozen_string_literal: true

module System
  class NodeMountPoint < BaseRecord
    include System::Base

    # === Constants ===
    # Synthetic-only mount types. Storage-backed mounts (nfs|cifs|efs|ebs|s3fs)
    # are owned by System::StorageAssignment as of Phase S2.
    MOUNT_TYPES = %w[tmpfs bind custom].freeze

    # === Associations ===
    belongs_to :account

    # Instance mount points (which instances have this mount)
    has_many :instance_mount_points, class_name: "System::InstanceMountPoint", foreign_key: :mount_point_id, dependent: :destroy
    has_many :node_instances, through: :instance_mount_points

    # === Validations ===
    validates :name, presence: true, uniqueness: { scope: :account_id, case_sensitive: false }
    validates :mount_path, presence: true
    validates :mount_type, presence: true, inclusion: { in: MOUNT_TYPES }

    # === Scopes ===
    scope :enabled, -> { where(enabled: true) }
    scope :disabled, -> { where(enabled: false) }
    scope :auto_mount, -> { where(auto_mount: true) }
    scope :manual_mount, -> { where(auto_mount: false) }
    scope :by_type, ->(type) { where(mount_type: type) }
    scope :by_name, -> { order(name: :asc) }

    # === Methods ===
    def tmpfs?
      mount_type == "tmpfs"
    end

    def bind?
      mount_type == "bind"
    end

    def custom?
      mount_type == "custom"
    end

    # Retained for backwards compat with the serializer; after Phase S2 these
    # always return false because storage-backed types now live on
    # System::StorageAssignment.
    def cloud_storage?
      false
    end

    def network_storage?
      false
    end

    def fstab_entry
      opts = options.presence || {}
      mount_opts = opts["options"] || "defaults"
      "#{source} #{mount_path} #{mount_type} #{mount_opts} 0 0"
    end

    def instance_count
      instance_mount_points.count
    end
  end
end
