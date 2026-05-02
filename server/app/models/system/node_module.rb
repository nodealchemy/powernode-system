# frozen_string_literal: true

module System
  class NodeModule < BaseRecord
    include System::Base

    # === Constants ===
    VARIETIES = %w[config instance subscription].freeze

    # rsync-glob spec fields (legacy node_module.rb:34-37). Stored as JSONB
    # arrays of base64-encoded strings (one per glob line). Round-tripped via
    # encode_spec / decode_spec.
    #
    # The five fields, with distinct semantics:
    #   - mask: paths I exclude from MY OWN blob during the build (rsync
    #     local-exclude). Used for build cruft (/var/cache/apt, doc/man,
    #     /var/log) that the package install creates but I don't want to
    #     ship. Does NOT cross module boundaries.
    #   - file_spec: paths I include in my blob (rsync local-include).
    #   - package_spec: deb packages installed into my build chroot.
    #   - dependency_spec: build-time dependencies between modules.
    #   - protected_spec (added 2026-05-02): paths I CLAIM as sensitive.
    #     Flows in BOTH priority directions into every neighbor's
    #     effective_mask, so no neighbor's blob may ship the claimed paths.
    #     Used for things like /etc/shadow, /etc/ssh/ssh_host_*_key,
    #     /etc/sudoers — where a union-mount override would be a security
    #     regression. mask and protected_spec are intentionally separate:
    #     a module typically wants to SHIP its protected paths (system-base
    #     ships /etc/shadow), so the claim must not also self-exclude.
    SPEC_FIELDS = %i[mask file_spec package_spec dependency_spec protected_spec].freeze

    # effective_priority = (category.position * MULTIPLIER) + module.priority.
    # Using `position` on NodeModuleCategory (the platform's analogue of the
    # legacy `priority` field). Multiplier of 1000 mirrors legacy default
    # (Powernode.config.module_priority_category_multiplier). Override via
    # Rails config if needed.
    PRIORITY_CATEGORY_MULTIPLIER = (Rails.application.config.try(:system_module_priority_category_multiplier) || 1000).freeze
    PRIORITY_PLACES = (Rails.application.config.try(:system_module_priority_places) || 7).freeze

    # === Associations ===
    belongs_to :account
    belongs_to :node_platform, class_name: 'System::NodePlatform', optional: true
    belongs_to :category, class_name: 'System::NodeModuleCategory', optional: true
    belongs_to :copy_path, class_name: 'System::NodeModuleCopyPath', optional: true

    # Dependant-module scoping (Golden Eclipse M0.J — restores legacy
    # parent_module / config-variety / instance-variety hierarchy from
    # ~/Drive/Projects/powernode-server/app/models/node_module.rb).
    #
    # - parent_module: the subscription-variety base whose deployment this child overrides
    # - node: the node this child is bound to (config + instance varieties both)
    # - node_instance: the specific instance this child overrides (instance variety only)
    belongs_to :parent_module, class_name: 'System::NodeModule', optional: true
    has_many :child_modules,
             class_name: 'System::NodeModule',
             foreign_key: :parent_module_id,
             dependent: :destroy
    belongs_to :node, class_name: 'System::Node', optional: true
    belongs_to :node_instance, class_name: 'System::NodeInstance', optional: true

    # Scopes for dependant lookup
    scope :dependants, -> { where.not(parent_module_id: nil) }
    scope :base_modules, -> { where(parent_module_id: nil) }
    scope :for_node, ->(node) { where(node_id: node) }
    scope :for_instance, ->(instance) { where(node_instance_id: instance) }

    # Versioning associations
    has_many :versions, class_name: 'System::NodeModuleVersion', dependent: :destroy
    belongs_to :current_version, class_name: 'System::NodeModuleVersion', optional: true

    # Node assignments (which nodes have this module)
    has_many :node_module_assignments, class_name: 'System::NodeModuleAssignment', dependent: :destroy
    has_many :nodes, through: :node_module_assignments

    # Template assignments (which templates include this module)
    has_many :template_modules, class_name: 'System::TemplateModule', dependent: :destroy
    has_many :node_templates, through: :template_modules

    # Puppet module assignments (configuration management)
    has_many :module_puppet_assignments, class_name: 'System::ModulePuppetAssignment', dependent: :destroy
    has_many :puppet_modules, through: :module_puppet_assignments

    # Dependencies (what this module requires)
    has_many :module_dependencies,
             class_name: 'System::ModuleDependency',
             foreign_key: :node_module_id,
             dependent: :destroy
    has_many :dependencies,
             through: :module_dependencies,
             source: :dependency

    # Dependents (what requires this module)
    has_many :dependent_relationships,
             class_name: 'System::ModuleDependency',
             foreign_key: :dependency_id,
             dependent: :destroy
    has_many :dependents,
             through: :dependent_relationships,
             source: :node_module

    # === Validations ===
    validates :name, presence: true, uniqueness: { scope: :account_id, case_sensitive: false }
    validates :variety, presence: true, inclusion: { in: VARIETIES }
    validates :priority, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

    # === Scopes ===
    scope :enabled, -> { where(enabled: true) }
    scope :disabled, -> { where(enabled: false) }
    scope :public_modules, -> { where(public: true) }
    scope :private_modules, -> { where(public: false) }
    scope :by_variety, ->(variety) { where(variety: variety) }
    scope :config_modules, -> { by_variety('config') }
    scope :instance_modules, -> { by_variety('instance') }
    scope :subscription_modules, -> { by_variety('subscription') }
    scope :by_priority, -> { order(priority: :desc, name: :asc) }
    scope :by_name, -> { order(name: :asc) }
    scope :for_platform, ->(platform_id) { where(node_platform_id: platform_id) }
    scope :in_category, ->(category_id) { where(category_id: category_id) }
    scope :locked, -> { where(lock_spec: true) }
    scope :unlocked, -> { where(lock_spec: false) }
    scope :versioned, -> { where.not(current_version_id: nil) }

    # === Callbacks ===
    before_validation :encode_specs
    before_update :check_lock_status, if: :will_save_change_to_versioned_attributes?
    after_update :auto_create_version, if: :saved_change_to_versioned_attributes?

    # === Methods ===

    # Returns true when this module is a dependant child (has a parent_module).
    def dependant?
      parent_module_id.present?
    end

    # Display name with legacy parent-aware rendering for dependant children.
    # Legacy: ~/Drive/Projects/powernode-server/app/models/node_module.rb:154-162
    # - config-variety dependant: "<parent.name> for <node.name>"
    # - instance-variety dependant: "<parent.name> for <instance.name>"
    # - everything else: the module's own name
    def display_name
      return name unless dependant?

      base = parent_module.display_name
      if instance? && node_instance
        "#{base} for #{node_instance.name}"
      elsif config? && node
        "#{base} for #{node.name}"
      else
        name
      end
    end

    # Lock-spec alias for legacy parity (legacy `immutable?` on NodeModule
    # delegates to subscription.locked? in some places; for the platform we
    # use lock_spec directly).
    def immutable?
      lock_spec == true
    end

    # Effective priority used for union-mount ordering and `effective_mask`
    # neighbor analysis. Higher = mounted "later" (closer to root, takes
    # precedence in overlay).
    # Legacy: ~/Drive/Projects/powernode-server/app/models/node_module.rb:110-112
    def effective_priority
      cat_position = category&.position.to_i
      (cat_position * PRIORITY_CATEGORY_MULTIPLIER) + priority.to_i
    end

    # Decoded text representation of each glob spec field (one decoded line
    # per array element, joined by newlines). Used by serializers and the
    # operator UI. Legacy: node_module.rb:248-283.
    def mask_text;            decode_spec_text(mask); end
    def file_spec_text;       decode_spec_text(file_spec); end
    def package_spec_text;    decode_spec_text(package_spec); end
    def dependency_spec_text; decode_spec_text(dependency_spec); end
    def protected_spec_text;  decode_spec_text(protected_spec); end

    # `.info` file content the on-node agent receives via
    # /node_api/modules JSON response. Legacy: node_module.rb:127-138.
    def info
      <<~INFO
        name=#{name}
        init_restart=#{init_restart}
        init_start=#{init_start}
        init_stop=#{init_stop}
        priority=#{effective_priority.to_s.rjust(PRIORITY_PLACES, '0')}
        reboot=#{reboot_required ? 'true' : 'false'}
        version=#{current_version_number}
        copy_path=#{copy_path&.destination_path}
      INFO
    end

    # Priority-aware effective mask — the rsync exclude list used when this
    # module's blob is built. Folds:
    #
    #   - This module's OWN mask (local rsync exclude — build cruft).
    #   - Every NEIGHBOR's protected_spec (both priority directions). This
    #     is the cross-neighbor claim: any path a neighbor flagged as
    #     sensitive gets excluded from this blob, so the union mount
    #     can't see two layers competing for the same path.
    #   - Higher-priority neighbors' mask (legacy carry-down — preserves
    #     pre-protected_spec semantics; neighbors who haven't migrated
    #     to protected_spec still get their claims honored downward).
    #   - Higher-priority neighbors' file_spec + dependency_spec when
    #     they are immutable — locked higher modules' content can't
    #     leak into this lower-priority blob.
    #
    # Symmetry: mask is local-only except for the legacy higher-down
    # carry; protected_spec is the supported cross-module claim and
    # flows in both directions. New modules should declare sensitive
    # paths via protected_spec, not mask.
    #
    # Legacy reference: ~/Drive/Projects/powernode-server/app/models/node_module.rb:252-266.
    # protected_spec direction added 2026-05-02.
    #
    # `target` is the deployment context — a Node or NodeInstance whose union
    # mount this module participates in. With no target, returns this module's
    # own mask (no neighbor carve-out).
    def effective_mask(target: nil)
      return Array(mask) if target.nil?

      neighbors = neighboring_modules_for(target)
      collected = neighbors.each_with_object([]) do |neighbor, acc|
        next if neighbor.id == id

        # protected_spec flows in both directions — every neighbor's
        # sensitive-path claim is honored regardless of priority.
        acc.concat(Array(neighbor.protected_spec))

        if neighbor.effective_priority > effective_priority
          # Legacy higher-down carry of mask + immutable file/dep promotion.
          acc.concat(Array(neighbor.mask))
          if neighbor.immutable?
            acc.concat(Array(neighbor.file_spec))
            acc.concat(Array(neighbor.dependency_spec))
          end
        end
      end
      (collected + Array(mask)).uniq.sort
    end

    # Generates the rsync filter rules used by the M1 CI composer stage to
    # carve a slim module out of a fat builder rootfs. Legacy: node_module.rb:268-271.
    # Format: "- excl1\n- excl2\n+ incl1\n+ incl2\n- *\n"
    def rsync_spec(target: nil)
      excl = decode_spec(effective_mask(target: target)).map { |l| "- #{l}\n" }
      incl = decode_spec(file_spec).map { |l| "+ #{l}\n" }
      "#{excl.join}#{incl.join}- *\n"
    end

    def config?
      variety == 'config'
    end

    def instance?
      variety == 'instance'
    end

    def subscription?
      variety == 'subscription'
    end

    def has_dependencies?
      module_dependencies.exists?
    end

    def has_dependents?
      dependent_relationships.exists?
    end

    def required_dependencies
      dependencies.joins(:module_dependencies).where(system_module_dependencies: { required: true })
    end

    def optional_dependencies
      dependencies.joins(:module_dependencies).where(system_module_dependencies: { required: false })
    end

    def all_dependencies(visited = Set.new)
      return [] if visited.include?(id)
      visited.add(id)

      direct = dependencies.to_a
      indirect = direct.flat_map { |dep| dep.all_dependencies(visited) }
      (direct + indirect).uniq
    end

    def assignment_count
      node_module_assignments.count
    end

    def template_count
      template_modules.count
    end

    def puppet_module_count
      module_puppet_assignments.count
    end

    def has_puppet_modules?
      module_puppet_assignments.exists?
    end

    def enabled_puppet_modules
      puppet_modules.enabled
    end

    def puppet_assignments_by_priority
      module_puppet_assignments.enabled.by_priority
    end

    # === Versioning Methods ===

    # Check if module spec is locked (immutable)
    def locked?
      lock_spec == true
    end

    # Lock the module to prevent updates
    def lock!
      update!(lock_spec: true)
    end

    # Unlock the module to allow updates
    def unlock!
      update!(lock_spec: false)
    end

    # Get version service for this module
    def version_service(current_user: nil)
      System::ModuleVersionService.new(self, current_user: current_user)
    end

    # Create a new version with changelog
    def create_version!(changelog: nil, user: nil)
      version_service(current_user: user).create_version(changelog: changelog)
    end

    # Rollback to a specific version
    def rollback_to!(version, changelog: nil, user: nil)
      version_service(current_user: user).rollback_to(version, changelog: changelog)
    end

    # Rollback to previous version
    def rollback_to_previous!(user: nil)
      version_service(current_user: user).rollback_to_previous
    end

    # Check if module has any versions
    def versioned?
      versions.exists?
    end

    # Get the latest version
    def latest_version
      versions.ordered.first
    end

    # Get version by number
    def version(number)
      versions.find_by(version_number: number)
    end

    # Get version history
    def version_history(limit: 20)
      version_service.version_history(limit: limit)
    end

    # Check if data file integrity matches checksum
    def verify_data_file(content)
      return false unless data_checksum.present?

      Digest::SHA256.hexdigest(content) == data_checksum
    end

    # Set data file with automatic checksum calculation
    def set_data_file(filename:, content:)
      self.data_file_name = filename
      self.data_file_size = content.bytesize
      self.data_checksum = Digest::SHA256.hexdigest(content)
    end

    private

    # === Spec encoding / decoding (legacy node_module.rb:304-321) ===
    # All four glob-spec fields are stored as Array<String> where each String
    # is base64-encoded raw glob line. encode_spec converts a multi-line
    # String input (from a form/textarea) into the array shape; decode_spec
    # round-trips back to raw strings.

    def encode_specs
      SPEC_FIELDS.each do |field|
        next unless attribute_changed?(field.to_s)

        write_attribute(field, encode_spec(read_attribute(field)))
      end
    end

    def encode_spec(attribute)
      return attribute unless attribute.is_a?(String)

      attribute
        .split(/\r?\n/)
        .map(&:strip)
        .uniq
        .sort
        .reject(&:empty?)
        .map { |line| Base64.strict_encode64(line) }
    end

    def decode_spec(spec)
      return spec unless spec.is_a?(Array)

      spec.map { |encoded| Base64.decode64(encoded) }
    end

    def decode_spec_text(spec)
      return spec.to_s unless spec.is_a?(Array)

      decode_spec(spec).map { |line| "#{line}\n" }.join
    end

    # Used by `effective_mask` neighbor analysis — returns sibling modules
    # the target's union will compose alongside this one. Honors per-(node,
    # module) enable state via NodeModuleAssignment.enabled.
    # When dependant-module restoration (M0.J) lands, this should also include
    # children scoped to the target.
    def neighboring_modules_for(target)
      node = case target
             when System::NodeInstance then target.node
             when System::Node         then target
             else return []
             end
      return [] unless node

      System::NodeModuleAssignment
        .where(node_id: node.id, enabled: true)
        .includes(:node_module)
        .map(&:node_module)
        .compact
    end

    # Attributes that trigger versioning when changed
    VERSIONED_ATTRIBUTES = %w[
      mask file_spec package_spec dependency_spec protected_spec config
      data_file_name data_checksum data_file_size
    ].freeze

    def will_save_change_to_versioned_attributes?
      (changed & VERSIONED_ATTRIBUTES).any?
    end

    def saved_change_to_versioned_attributes?
      (saved_changes.keys & VERSIONED_ATTRIBUTES).any?
    end

    def check_lock_status
      return unless lock_spec && !lock_spec_changed?

      errors.add(:base, 'Module is locked and cannot be modified')
      throw(:abort)
    end

    def auto_create_version
      # Skip if we're in the middle of a rollback or manual version creation
      return if @skip_auto_version

      # Only auto-version if this is a significant change
      return unless versioned?

      @skip_auto_version = true
      create_version!(changelog: 'Auto-versioned on update')
    ensure
      @skip_auto_version = false
    end
  end
end
