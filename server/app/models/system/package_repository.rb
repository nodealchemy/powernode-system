# frozen_string_literal: true

module System
  # An upstream apt/rpm/dnf package repository registered with the platform.
  #
  # Two visibility modes coexist:
  #
  #   visibility=account, account_id NOT NULL: scoped to one account, only that
  #     account can see, sync, materialize from, or mutate it.
  #
  #   visibility=shared,  account_id IS NULL:  system-wide. Any account can read
  #     (browse packages, materialize their own modules from it). Only users
  #     with the `system.package_repositories.manage_shared` permission can
  #     create, edit, or delete shared repos. Used for canonical upstream
  #     archives (Ubuntu noble, EPEL 9, etc.) that every account benefits from.
  #
  # The visibility ⟺ account_id-IS-NULL invariant is enforced by a CHECK
  # constraint at the DB level (chk_pkgrepo_visibility_account_consistency).
  # Don't try to write inconsistent combinations from Ruby — the DB will
  # reject them and the error message is opaque.
  class PackageRepository < BaseRecord
    # Intentionally does NOT include System::Base — that concern declares
    # `belongs_to :account` (required) and we need account_id to be nullable
    # for shared repos. We re-declare the association as optional below and
    # provide our own account-aware scopes.

    KINDS       = %w[apt rpm dnf].freeze
    VISIBILITIES = %w[account shared].freeze
    SYNC_STATUSES = %w[idle syncing failed].freeze

    # === Associations ===
    belongs_to :account, optional: true
    belongs_to :node_platform, class_name: "System::NodePlatform", optional: true
    belongs_to :created_by, class_name: "::User"

    has_many :packages,
             class_name: "System::Package",
             foreign_key: :package_repository_id,
             dependent: :destroy
    has_many :package_module_links,
             class_name: "System::PackageModuleLink",
             foreign_key: :package_repository_id,
             dependent: :restrict_with_error

    # === Validations ===
    validates :name, presence: true
    validates :kind, presence: true, inclusion: { in: KINDS }
    validates :visibility, presence: true, inclusion: { in: VISIBILITIES }
    validates :base_url, presence: true,
                         format: { with: %r{\Ahttps?://}, message: "must be http(s)" }
    validates :sync_status, inclusion: { in: SYNC_STATUSES }
    validates :priority, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validate  :visibility_account_consistency
    validate  :apt_or_rpm_config_present

    # === Scopes ===
    scope :enabled,  -> { where(enabled: true) }
    scope :disabled, -> { where(enabled: false) }
    scope :shared,   -> { where(visibility: "shared", account_id: nil) }
    scope :account_scoped, -> { where(visibility: "account").where.not(account_id: nil) }
    scope :for_kind, ->(kind) { where(kind: kind) }

    # Returns repos accessible to the given account: account's own + all shared.
    # NULL account = admin/system context → returns everything.
    scope :accessible_to, ->(account) {
      if account.nil?
        all
      else
        where("account_id = ? OR account_id IS NULL", account.id)
      end
    }

    # === Callbacks ===
    # The architectures column is a JSONB array of strings, so a built-in
    # counter_cache can't track it (counter_cache requires a belongs_to FK).
    # Instead, fire after_commit callbacks to bump NodeArchitecture.package_
    # repository_count for each canonical arch the repo touches. find_normalized
    # handles apt/rpm name aliases, so "amd64" and "x86_64" count against the
    # same canonical row.
    #
    # The sync-status updates (mark_syncing!/mark_synced!/mark_sync_failed!)
    # go through update! but don't touch the `architectures` column, so the
    # `saved_change_to_architectures?` guard prevents spurious counter writes
    # on every sync tick.

    # Canonicalize architectures on every write. Operators or AI agents can
    # submit kind-specific names ("x86_64"), aliases ("amd64-graviton"), or
    # already-canonical names ("amd64") — we normalize to the canonical form
    # via NodeArchitecture.find_normalized so the JSONB column always stores
    # the catalog's `name` values. Downstream consumers (adapters, the sync
    # service) translate back to kind-specific via #architectures_for_kind.
    # Runs before validation so the canonicalized form is what gets validated.
    before_validation :canonicalize_architectures

    after_create_commit  :increment_arch_counters
    after_update_commit  :diff_arch_counters
    after_destroy_commit :decrement_arch_counters

    # === Methods ===
    def shared?
      visibility == "shared"
    end

    def account_scoped?
      visibility == "account"
    end

    def syncing?
      sync_status == "syncing"
    end

    def can_be_managed_by?(user)
      return false unless user
      if shared?
        user.has_permission?("system.package_repositories.manage_shared")
      else
        account_id == user.account_id &&
          user.has_permission?("system.package_repositories.update")
      end
    end

    # Apt-specific accessors against the apt_config JSONB blob
    def suite
      apt_config["suite"]
    end

    def components
      Array(apt_config["components"])
    end

    # Rpm-specific accessors against the rpm_config JSONB blob
    def releasever
      rpm_config["releasever"]
    end

    def gpgcheck?
      rpm_config.fetch("gpgcheck", true)
    end

    def metalink
      rpm_config["metalink"]
    end

    def mark_syncing!
      update!(sync_status: "syncing")
    end

    def mark_synced!(package_count:)
      update!(
        sync_status: "idle",
        last_synced_at: Time.current,
        last_sync_error: nil,
        package_count: package_count
      )
    end

    def mark_sync_failed!(error_message)
      update!(sync_status: "failed", last_sync_error: error_message.to_s.truncate(2000))
    end

    # Translate this repo's canonical architectures back to the kind-
    # specific names its adapter expects. The PackageRepository column
    # stores canonical names (post-T2.A), but apt's `binary-<arch>/Packages.xz`
    # URLs need apt-style names and rpm's `--forcearch=<arch>` needs rpm-style
    # names. This method is the translation point at the adapter boundary.
    #
    # Returns an array; preserves order; drops entries whose canonical
    # value can't be resolved (defensive — shouldn't happen since the
    # before_validation hook rejects unmappable input).
    def architectures_for_kind
      Array(architectures).filter_map do |canonical_name|
        arch = ::System::NodeArchitecture.find_normalized(canonical_name)
        next nil unless arch
        arch.value_for_kind(kind)
      end
    end

    private

    def visibility_account_consistency
      if shared? && account_id.present?
        errors.add(:account_id, "must be nil for shared repositories")
      elsif account_scoped? && account_id.blank?
        errors.add(:account_id, "is required for account-scoped repositories")
      end
    end

    def apt_or_rpm_config_present
      case kind
      when "apt"
        if suite.blank?
          errors.add(:apt_config, "must contain 'suite' for apt repositories")
        end
        if components.empty?
          errors.add(:apt_config, "must contain at least one 'components' entry for apt repositories")
        end
      when "rpm", "dnf"
        if releasever.blank? && metalink.blank?
          errors.add(:rpm_config, "must contain 'releasever' or 'metalink' for rpm/dnf repositories")
        end
      end
    end

    # === Architecture canonicalization (T2.A) ===

    # before_validation hook — coerces every entry in `architectures` to
    # the canonical name from the NodeArchitecture catalog. Accepts:
    #   - canonical names ("amd64") — pass through
    #   - kind-specific names ("x86_64", "aarch64") — translated
    #   - aliases ("amd64-graviton") — translated via the aliases JSONB
    # Unmappable entries are silently dropped — the operator should
    # define an alias on a canonical row if they want a vendor tag preserved.
    def canonicalize_architectures
      raw = Array(architectures)
      return if raw.empty?

      canonicalized = raw.filter_map do |value|
        arch = ::System::NodeArchitecture.find_normalized(value)
        arch&.name
      end.uniq

      self.architectures = canonicalized
    end

    # === Arch-counter helpers (called by after_commit hooks above) ===

    def increment_arch_counters
      bump_arch_counters(Array(architectures), delta: 1)
    end

    def decrement_arch_counters
      bump_arch_counters(Array(architectures), delta: -1)
    end

    def diff_arch_counters
      return unless saved_change_to_architectures?

      old_arches, new_arches = saved_change_to_architectures
      bump_arch_counters(Array(old_arches) - Array(new_arches), delta: -1)
      bump_arch_counters(Array(new_arches) - Array(old_arches), delta: 1)
    end

    def bump_arch_counters(arch_names, delta:)
      arch_names.uniq.each do |name|
        arch = ::System::NodeArchitecture.find_normalized(name)
        next unless arch

        if delta.positive?
          ::System::NodeArchitecture.increment_counter(:package_repository_count, arch.id)
        else
          ::System::NodeArchitecture.decrement_counter(:package_repository_count, arch.id)
        end
      end
    end
  end
end
