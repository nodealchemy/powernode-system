# frozen_string_literal: true

module System
  # Materializes NodeModuleAssignment rows for a Node from the closure
  # of its NodeTemplate's TemplateModules. Wires TemplateExpansionService
  # into a write path — previously the expansion service existed but had
  # no caller (audit 2026-05-11).
  #
  # Apply is idempotent: re-running adds new assignments for modules
  # that entered the closure since the previous run and is a no-op for
  # modules already assigned. Existing assignments are never modified —
  # operator-tuned priority/config/enabled flags on prior assignments
  # are preserved.
  #
  # `purge_stale` (default false) opts into removing template-derived
  # assignments whose modules left the closure (e.g., a TemplateModule
  # was disabled or removed). Only assignments with a non-NULL
  # `source_template_module_id` are eligible for purge — hand-authored
  # assignments stay regardless.
  #
  # `dry_run` (default false) computes the plan without persisting, so
  # operator UI can preview the diff before committing.
  class TemplateApplyService
    Result = Struct.new(
      :ok, :created, :skipped, :purged, :warnings, :errors,
      keyword_init: true
    ) do
      alias_method :ok?, :ok
    end

    def initialize(node)
      @node = node
    end

    # Returns a Result. ok? is false only on validation failure
    # (e.g., node has no template).
    def apply!(dry_run: false, purge_stale: false)
      template = @node.node_template
      return failure("node has no node_template") unless template

      expansion = ::System::TemplateExpansionService.new(
        template_modules: template.template_modules
      ).expand

      existing_assignments_by_module = @node.node_module_assignments
                                            .includes(:node_module)
                                            .index_by(&:node_module_id)

      to_create = []
      to_skip = []
      to_purge = []

      expansion.modules.each do |mod|
        if existing_assignments_by_module.key?(mod.id)
          to_skip << existing_assignments_by_module[mod.id]
          next
        end
        to_create << {
          node_module: mod,
          priority: mod.priority.to_i,
          enabled: true,
          auto_resolved: expansion.auto_resolved_ids.include?(mod.id),
          source_template_module: expansion.source_template_module_for[mod.id]
        }
      end

      if purge_stale
        closure_ids = expansion.modules.map(&:id).to_set
        existing_assignments_by_module.each_value do |asn|
          next if closure_ids.include?(asn.node_module_id)
          next if asn.source_template_module_id.nil?
          to_purge << asn
        end
      end

      return preview(to_create, to_skip, to_purge, expansion) if dry_run

      created_records = []
      ActiveRecord::Base.transaction do
        to_create.each do |attrs|
          created_records << @node.node_module_assignments.create!(attrs)
        end
        to_purge.each(&:destroy!) if purge_stale
      end

      Result.new(
        ok: true,
        created: created_records,
        skipped: to_skip,
        purged: to_purge,
        warnings: expansion.warnings,
        errors: expansion.errors
      )
    rescue ActiveRecord::RecordInvalid => e
      Result.new(
        ok: false, created: [], skipped: [], purged: [],
        warnings: expansion&.warnings || [], errors: ["#{e.class}: #{e.message}"]
      )
    end

    private

    def preview(to_create, to_skip, to_purge, expansion)
      Result.new(
        ok: true,
        created: to_create.map { |a| OpenStruct.new(node_module: a[:node_module], source_template_module: a[:source_template_module]) },
        skipped: to_skip,
        purged: to_purge,
        warnings: expansion.warnings + [ "dry_run: no changes persisted" ],
        errors: expansion.errors
      )
    end

    def failure(message)
      Result.new(ok: false, created: [], skipped: [], purged: [], warnings: [], errors: [ message ])
    end
  end
end
