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
  class TemplateCloneService
    class CloneError < StandardError; end

    attr_reader :source_template

    def initialize(source_template)
      @source_template = source_template
    end

    # Returns the new NodeTemplate.
    #
    # new_name — optional override; defaults to "<source name>-copy".
    # account  — optional destination account; defaults to source.account.
    def clone!(new_name: nil, account: nil)
      account ||= source_template.account
      new_name ||= "#{source_template.name}-copy"

      ActiveRecord::Base.transaction do
        cloned = build_template_clone(account, new_name)
        cloned.save!
        copy_template_modules!(cloned)
        cloned
      end
    rescue ActiveRecord::RecordInvalid => e
      raise CloneError, e.message
    end

    private

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
