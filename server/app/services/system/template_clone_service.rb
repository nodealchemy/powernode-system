# frozen_string_literal: true

module System
  # Deep-clones a NodeTemplate including all its TemplateModule rows
  # (with priorities, enabled flags, per-module config, and
  # recommends_override JSON preserved).
  #
  # Cross-account cloning is supported by passing `account:` — useful for
  # template-marketplace import flows. Defaults to the source template's
  # own account.
  #
  # Raises TemplateCloneService::CloneError on validation failure
  # (typically a name collision on the destination account; the unique
  # index is scoped to account_id, so cloning within the same account
  # requires a distinct name).
  #
  # Composition: a clone copies the source's joins wholesale, which is how a
  # composition conflict travels — and because the guard on the assignment
  # write paths is a DELTA, whatever a clone lands becomes permanent baseline
  # that later assignments are then obliged to treat as acceptable. So the
  # clone runs TemplateCompositionAnalysis over the result and REPORTS it
  # (#composition_report / #composition_message, plus a log line) rather
  # than refusing: a clone reproduces state that already exists, and forking
  # a broken template is exactly how an operator gets a copy to repair. The
  # same conflicts are judged again at apply time, where they would otherwise
  # reach real nodes.
  class TemplateCloneService
    class CloneError < StandardError; end

    attr_reader :source_template

    # Populated by #clone! — every conflict the cloned template composes into,
    # each entry stating its own severity, plus a prebuilt message naming the
    # modules. Empty/nil after a clean clone.
    #
    # `composition_report`, not `composition_conflicts`/`composition_warning`:
    # what rides here includes BLOCKING entries, and the old pair reached the
    # HTTP surface under a key named `warnings` — the same key the enforcing
    # assignment paths use for genuinely advisory conflicts, so a caller could
    # not tell a verdict it must act on from one it may ignore
    # (IMP-493db0e5c398). #composition_message keeps the human summary, which
    # is still what gets logged.
    attr_reader :composition_report, :composition_message

    def initialize(source_template)
      @source_template = source_template
      @composition_report = []
    end

    # Returns the new NodeTemplate.
    #
    # new_name — optional override; defaults to "<source name>-copy".
    # account  — optional destination account; defaults to source.account.
    def clone!(new_name: nil, account: nil)
      account ||= source_template.account
      new_name ||= "#{source_template.name}-copy"

      cloned = ActiveRecord::Base.transaction do
        clone = build_template_clone(account, new_name)
        clone.save!
        copy_template_modules!(clone)
        clone
      end

      record_composition!(cloned)
      cloned
    rescue ActiveRecord::RecordInvalid => e
      raise CloneError, e.message
    end

    private

    # Advisory only, so it runs AFTER the commit and cannot fail the clone —
    # a report that can 500 a working flow is worse than the silence it
    # replaces. An analysis that blows up is itself the warning.
    #
    # Scoped to the SOURCE account, not the destination: #copy_template_modules!
    # copies node_module_id verbatim, so on a cross-account clone the new
    # template's joins still point at the source account's modules. Resolving
    # against the destination would find none of them and report a clean
    # composition for every cross-account clone.
    def record_composition!(cloned)
      # Shared fail-closed report (IMP-ba082cb22bda) — one contract with
      # TemplateImporter#composition_report.
      result = ::System::TemplateCompositionAnalysis.report_for(
        account: source_template.account,
        modules: cloned.template_modules.enabled,
        log_tag: "TemplateCloneService",
        subject: "cloned #{source_template.name} → #{cloned.name}"
      )
      @composition_report = result[:report]
      @composition_message = result[:message]
    end

    def build_template_clone(account, new_name)
      attrs = source_template.attributes.except(
        "id", "name", "account_id", "created_at", "updated_at"
      )
      ::System::NodeTemplate.new(attrs).tap do |t|
        t.account = account
        t.name = new_name
        t.config = source_template.config&.deep_dup if t.respond_to?(:config=)
      end
    end

    def copy_template_modules!(cloned_template)
      source_template.template_modules.find_each do |tm|
        attrs = tm.attributes.except("id", "node_template_id", "created_at", "updated_at")
        cloned_template.template_modules.create!(attrs)
      end
    end
  end
end
