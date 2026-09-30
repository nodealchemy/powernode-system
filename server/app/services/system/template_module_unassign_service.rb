# frozen_string_literal: true

module System
  # Removes a module from a template: destroys the TemplateModule join AND the
  # NodeModuleAssignments it produced, in one transaction. The one write path
  # for both surfaces — the MCP verb system_unassign_module_from_template and
  # REST DELETE node_templates/:id/modules/:id (IMP-5fa3c8d0e2f7).
  #
  # WHY THE JOIN CANNOT GO ALONE. The FK from
  # system_node_module_assignments.source_template_module_id is ON DELETE SET
  # NULL, and a NULL source is exactly how TemplateApplyService's purge_stale
  # recognises a hand-authored row it must never touch. Destroying the join by
  # itself therefore turned every derived row into a permanent orphan: the node
  # kept a module its template had dropped, and no apply would ever reap it.
  #
  # CLOSURE-AWARE, NOT "every row sourced from the join". The expansion
  # attributes a transitive dependency to its NEAREST explicit ancestor join
  # (ties by priority), so a row can name this join while another join on the
  # same template also requires the module. Destroying that row would strip a
  # module the template still ships. So each derived row is judged against the
  # closure of its node's CURRENT template with this join taken out: a module
  # still in that closure is re-pointed at the join that now brings it in; any
  # other row is destroyed. That is purge_stale's own rule (closure membership),
  # applied at the moment the join goes. A row whose module is in the closure
  # but has no attributable join (the expansion's defensive nil) is destroyed,
  # not left sourceless: a missing module is re-created by the next apply and
  # flagged by TemplateClosureDriftSensor, while an orphan is never reaped.
  #
  # Hand-authored rows (NULL source) and rows derived from any other join are
  # outside the query and cannot be touched.
  #
  # Rows are destroyed one at a time with destroy!, never delete_all: the
  # model's after_destroy records an AssignmentClearance, which is what lets
  # the node agent detach a module when the served list comes back empty.
  #
  # ORDER AND LOCKING. The join is locked FOR UPDATE before anything is read. A
  # concurrent apply inserting a row that references it takes FOR KEY SHARE on
  # the join for the FK check, which blocks against this lock and then fails
  # once the join is gone, so no new orphan can be written between the read
  # and the delete. The plan (what is purged, what is re-pointed) is computed
  # after the lock and BEFORE any write, so its count is the pre-write
  # statement a caller reports as blast radius. The whole thing commits or
  # rolls back as one.
  class TemplateModuleUnassignService
    Result = Struct.new(:template_module_id, :purged, :repointed, keyword_init: true) do
      def purged_count
        purged.size
      end

      def purged_node_ids
        purged.map { |row| row[:node_id] }.uniq
      end

      # The shape both surfaces return.
      def to_payload
        {
          purged_assignments: { count: purged_count, node_ids: purged_node_ids, assignments: purged },
          repointed_assignments: repointed
        }
      end
    end

    def initialize(template_module)
      @join = template_module
    end

    def call!
      ActiveRecord::Base.transaction do
        @join.lock!
        to_purge, to_repoint = plan

        purged = to_purge.map do |assignment|
          assignment.destroy!
          assignment_row(assignment)
        end
        repointed = to_repoint.map do |assignment, source|
          assignment.update!(source_template_module_id: source.id)
          assignment_row(assignment).merge(source_template_module_id: source.id)
        end
        @join.destroy!

        Result.new(template_module_id: @join.id, purged: purged, repointed: repointed)
      end
    end

    private

    def plan
      derived = ::System::NodeModuleAssignment
                .where(source_template_module_id: @join.id)
                .includes(:node)
                .order(:id)
                .lock
                .to_a

      sources_by_template = {}
      to_purge = []
      to_repoint = []
      derived.each do |assignment|
        template_id = assignment.node&.node_template_id
        sources = sources_by_template[template_id] ||= closure_sources(template_id)
        if (source = sources[assignment.node_module_id])
          to_repoint << [ assignment, source ]
        else
          to_purge << assignment
        end
      end
      [ to_purge, to_repoint ]
    end

    # { node_module_id => TemplateModule that brings it in } for the template's
    # closure without this join. Only attributable entries are kept.
    def closure_sources(template_id)
      template = template_id && ::System::NodeTemplate.find_by(id: template_id)
      return {} unless template

      ::System::TemplateExpansionService
        .new(template_modules: template.template_modules.where.not(id: @join.id))
        .expand
        .source_template_module_for
        .compact
    end

    def assignment_row(assignment)
      { assignment_id: assignment.id, node_id: assignment.node_id, node_module_id: assignment.node_module_id }
    end
  end
end
