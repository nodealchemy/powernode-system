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
  #
  # The closure is read without a lock on the template's OTHER joins, so a join
  # assigned concurrently (between the plan and the commit) that also requires
  # a purged module is not seen. That row is purged and the next apply
  # re-creates it — one flap, self-healing.
  #
  # BLAST RADIUS. After the commit — never inside the transaction, where a
  # rollback would leave a phantom event — the service records the mutation
  # through System::TemplateMutationRecorder (the TemplateApprovalPolicy
  # classification plus a `system.template_mutation` FleetEvent) when the join
  # was shipping or any row was purged: a disabled join's derived rows were kept
  # by the disable, and this purge is what takes the module off those nodes.
  # Both doors therefore record exactly the same radius; the radius rides back
  # on the Result.
  class TemplateModuleUnassignService
    # Reply and event payloads list at most this many node ids and rows; the
    # counts are always exact. A fleet-sized template must not turn the reply
    # or the event's jsonb column into a megabyte list.
    LISTED_LIMIT = 100

    Result = Struct.new(:template_module_id, :purged, :repointed, :blast_radius, keyword_init: true) do
      def purged_count
        purged.size
      end

      def purged_node_ids
        purged.map { |row| row[:node_id] }.uniq
      end

      # The capped node-id summary the radius and the event carry.
      def radius_extra
        ids = purged_node_ids
        { purged_assignment_count: purged_count, purged_node_count: ids.size,
          purged_node_ids: ids.first(LISTED_LIMIT), purged_node_ids_truncated: ids.size > LISTED_LIMIT }
      end

      # The shape both surfaces return.
      def to_payload
        ids = purged_node_ids
        {
          purged_assignments: {
            count: purged_count, node_count: ids.size,
            node_ids: ids.first(LISTED_LIMIT), assignments: purged.first(LISTED_LIMIT),
            truncated: ids.size > LISTED_LIMIT || purged_count > LISTED_LIMIT
          },
          repointed_assignments: repointed.first(LISTED_LIMIT),
          repointed_count: repointed.size
        }.tap { |payload| payload[:blast_radius] = blast_radius if blast_radius }
      end
    end

    def initialize(template_module)
      @join = template_module
    end

    # initiated_by / source identify the caller on the recorded FleetEvent.
    def call!(initiated_by:, source:)
      shipped = @join.enabled
      result = purge!
      if shipped || result.purged_count.positive?
        result.blast_radius = ::System::TemplateMutationRecorder.record!(
          account: @join.node_template.account, template: @join.node_template, node_module: @join.node_module,
          change: "module_unassigned", initiated_by: initiated_by, source: source, extra: result.radius_extra
        )
      end
      result
    end

    private

    def purge!
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
