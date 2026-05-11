# frozen_string_literal: true

module System
  # Platform-wide catalog of CPU architectures. NOT account-scoped — a
  # single canonical "x86_64" row is shared across every account so
  # cross-account fleet queries don't need per-account normalization.
  #
  # See i-would-like-to-zesty-glade.md (Tier 1) for the design.
  class NodeArchitecture < BaseRecord
    self.table_name = "system_node_architectures"

    # Constants
    IMAGE_FORMATS = %w[raw qcow2 vmdk vhd ami iso].freeze
    FAMILIES      = %w[x86 arm power z risc-v mips other].freeze

    # Associations
    has_many :node_platforms, class_name: "System::NodePlatform", dependent: :restrict_with_error

    # File attachments via FileManagement::Object (platform-shared file
    # management — provides multi-backend storage, versioning, sharing,
    # processing pipeline, ACL).
    belongs_to :kernel_file_object,  class_name: "FileManagement::Object", optional: true
    belongs_to :ramdisk_file_object, class_name: "FileManagement::Object", optional: true
    belongs_to :image_file_object,   class_name: "FileManagement::Object", optional: true

    # Validations
    validates :name, presence: true, uniqueness: true
    validates :family, inclusion: { in: FAMILIES }
    validates :image_format, inclusion: { in: IMAGE_FORMATS }, allow_nil: true
    validates :kernel_checksum, format: { with: /\A[a-f0-9]{64}\z/i, message: "must be a valid SHA256 hash" }, allow_nil: true
    validates :ramdisk_checksum, format: { with: /\A[a-f0-9]{64}\z/i, message: "must be a valid SHA256 hash" }, allow_nil: true
    validates :image_checksum, format: { with: /\A[a-f0-9]{64}\z/i, message: "must be a valid SHA256 hash" }, allow_nil: true

    # Scopes (these were inherited from System::Base; re-declared here
    # because dropping the concern dropped its account-scoped scopes).
    scope :enabled,         -> { where(enabled: true) }
    scope :disabled,        -> { where(enabled: false) }
    scope :public_access,   -> { where(public: true) }
    scope :private_access,  -> { where(public: false) }
    scope :canonical,       -> { where(is_canonical: true) }
    scope :custom,          -> { where(is_canonical: false) }
    scope :ordered,         -> { order(:family, :name) }
    scope :recently_created,-> { order(created_at: :desc) }
    scope :recently_updated,-> { order(updated_at: :desc) }
    scope :by_family,       ->(family) { where(family: family) }

    # === State helpers ===
    def enabled?
      enabled == true
    end

    def public?
      self[:public] == true
    end

    # Canonical rows can't be mutated or deleted via the API — they
    # only evolve via a migration. The model-level guard is belt-and-
    # suspenders on top of the controller check; useful when scripts /
    # the rails console bypass the controller.
    def protected_canonical?
      is_canonical == true
    end

    # === Lookups by kind-specific name ===
    def self.find_by_apt_name(name)
      return nil if name.blank?
      where("LOWER(apt_name) = ?", name.to_s.downcase).first
    end

    def self.find_by_rpm_name(name)
      return nil if name.blank?
      where("LOWER(rpm_name) = ?", name.to_s.downcase).first
    end

    # Resolve a value (could be canonical `name`, apt_name, or rpm_name)
    # to its canonical row. Returns nil if no match.
    def self.find_normalized(value)
      return nil if value.blank?

      v = value.to_s.downcase
      where("LOWER(name) = ? OR LOWER(apt_name) = ? OR LOWER(rpm_name) = ?", v, v, v).first
    end

    # Project a row onto the kind-specific name an apt/rpm repo expects.
    def value_for_kind(kind)
      case kind.to_s
      when "apt"      then apt_name || name
      when "rpm", "dnf" then rpm_name || name
      else name
      end
    end

    # The seven canonical CPU architectures the platform ships with. Canonical
    # names follow apt/Debian convention (amd64, arm64, armhf, i386, ppc64el)
    # because the platform builds on Ubuntu and production callers default
    # to apt-style names. Migration seeds these in dev/prod; test environments
    # (which use schema:load, not migrations) ensure these exist via
    # #ensure_canonical_seed! on first AccountBootstrapService call. Single
    # source of truth so both paths can't drift.
    CANONICAL_SEED_DATA = [
      { name: "amd64",   family: "x86",    display_name: "Intel/AMD 64-bit",
        apt_name: "amd64",   rpm_name: "x86_64",
        description: "64-bit x86 architecture used by Intel and AMD processors. The dominant server and desktop CPU since the mid-2000s; runs essentially all mainstream Linux distributions." },
      { name: "arm64",   family: "arm",    display_name: "ARM 64-bit",
        apt_name: "arm64",   rpm_name: "aarch64",
        description: "64-bit ARM architecture (ARMv8-A and newer). Powers Apple Silicon Macs, AWS Graviton, Ampere Altra, and most modern Raspberry Pi 4/5 boards." },
      { name: "armhf",   family: "arm",    display_name: "ARM 32-bit (hard-float)",
        apt_name: "armhf",   rpm_name: "armv7hl",
        description: "32-bit ARM with hardware floating-point (VFP). Used by older Raspberry Pi models and embedded boards from before the 64-bit ARM transition." },
      { name: "i386",    family: "x86",    display_name: "Intel/AMD 32-bit",
        apt_name: "i386",    rpm_name: "i686",
        description: "32-bit x86 architecture. Largely deprecated for server workloads but still common in legacy embedded systems and constrained VMs." },
      { name: "ppc64el", family: "power",  display_name: "POWER 64-bit (little-endian)",
        apt_name: "ppc64el", rpm_name: "ppc64le",
        description: "IBM POWER architecture in 64-bit little-endian mode. Used by IBM Power Systems and OpenPOWER hardware for HPC and database workloads." },
      { name: "s390x",   family: "z",      display_name: "IBM Z (System z)",
        apt_name: "s390x",   rpm_name: "s390x",
        description: "IBM System z mainframe architecture. Used by IBM Z and LinuxONE for transaction-heavy enterprise workloads." },
      { name: "riscv64", family: "risc-v", display_name: "RISC-V 64-bit",
        apt_name: "riscv64", rpm_name: "riscv64",
        description: "64-bit RISC-V open ISA. Emerging for embedded systems, accelerators, and increasingly available on developer boards (VisionFive, StarFive, SiFive HiFive)." }
    ].freeze

    def self.ensure_canonical_seed!
      CANONICAL_SEED_DATA.each do |attrs|
        row = find_or_initialize_by(name: attrs[:name])
        row.assign_attributes(
          family: attrs[:family],
          apt_name: attrs[:apt_name],
          rpm_name: attrs[:rpm_name],
          display_name: attrs[:display_name],
          description: attrs[:description],
          is_canonical: true,
          enabled: true,
          public: true
        )
        row.save! if row.changed? || row.new_record?
      end
    end

    # === Boot Image Methods ===
    def has_kernel?
      kernel_file_object.present?
    end

    def has_ramdisk?
      ramdisk_file_object.present?
    end

    def has_image?
      image_file_object.present?
    end

    def boot_ready?
      has_kernel? && has_image?
    end

    def verify_kernel_checksum(file_checksum)
      return true if kernel_checksum.blank?
      kernel_checksum.downcase == file_checksum.to_s.downcase
    end

    def verify_ramdisk_checksum(file_checksum)
      return true if ramdisk_checksum.blank?
      ramdisk_checksum.downcase == file_checksum.to_s.downcase
    end

    def verify_image_checksum(file_checksum)
      return true if image_checksum.blank?
      image_checksum.downcase == file_checksum.to_s.downcase
    end

    def boot_files_info
      {
        kernel: {
          present: has_kernel?,
          checksum: kernel_checksum,
          version: kernel_version
        },
        ramdisk: {
          present: has_ramdisk?,
          checksum: ramdisk_checksum
        },
        image: {
          present: has_image?,
          checksum: image_checksum,
          format: image_format
        }
      }
    end
  end
end
