# frozen_string_literal: true

module System
  # IMP-f1f96c292991 (2026-09-13 operator ruling) — idempotent removal of
  # sample/demo content already seeded on an established install.
  #
  # `rails db:seed` is FIRST BOOT ONLY on a deployed install, so gating
  # Powernode::SampleContentGate only stops FUTURE deployments from getting
  # sample content — an install that already seeded it keeps those rows
  # forever unless something explicitly removes them. This is that verb.
  #
  # DEFAULT DRY RUN. Apply mode is DESTRUCTIVE and requires `confirm: true`
  # — the constructor refuses apply mode without it. NEVER run apply mode
  # against anything but an isolated test database; an operator runs it
  # against a real install with explicit confirmation, never autonomously.
  #
  # SKIP-IF-REFERENCED is a safety property, not a nicety: a template with a
  # real node (node_count > 0), a module with a real assignment
  # (assignment_count > 0) or a real remaining template reference, or a
  # provider with real infrastructure behind it is skipped and reported,
  # never removed — even though its name matches the sample-content list.
  # This is proven necessary on THIS deployment: `nodejs-runtime` (excluded
  # from SAMPLE_MODULE_NAMES below for exactly this reason) carries 14 real
  # System::NodeModuleAssignment rows via the live "powernode-ops-cell"
  # NodeTemplate (verified 2026-09-18). A module or template that were
  # naively removed by name alone, without this check, could take a real
  # dependency down with it.
  #
  # Idempotent: a second `call` (in either mode) finds no remaining
  # candidates among what a previous apply already removed, so it reports
  # zero removals.
  class SampleContentRemovalService
    SAMPLE_AGENT_NAMES = [
      "Legal & Compliance Analyst",
      "Life Sciences Research Analyst",
      "Finance Operations Analyst",
      "Sales Operations Specialist",
      "Customer Success Agent"
    ].freeze

    # rpi4-base/rpi4-hardened/web-apache/web-nginx and the modules only they
    # use. `nodejs-runtime` is DELIBERATELY ABSENT from SAMPLE_MODULE_NAMES —
    # see the class comment.
    SAMPLE_TEMPLATE_NAMES = %w[rpi4-base rpi4-hardened web-apache web-nginx].freeze
    SAMPLE_MODULE_NAMES   = %w[apache nginx rpi4-firmware docker-runtime python-runtime postgres-server redis-cache].freeze
    SAMPLE_PROVIDER_TYPE  = "local_qemu"

    Report = Struct.new(:dry_run, :counted, :removed, :skipped, keyword_init: true) do
      def total_candidates
        counted.values.sum
      end

      def total_removed
        removed.values.sum(&:size)
      end

      def total_skipped
        skipped.values.sum(&:size)
      end
    end

    def initialize(dry_run: true, confirm: false)
      @dry_run = dry_run
      @confirm = confirm
      return if @dry_run || @confirm

      raise ArgumentError, "apply mode (dry_run: false) requires confirm: true — never invoke autonomously"
    end

    def call
      candidates = classify_candidates
      counted = candidates.transform_values(&:size)

      removed = { agents: [], templates: [], modules: [], providers: [] }
      skipped = { agents: [], templates: [], modules: [], providers: [] }

      candidates[:agents].each { |agent| process_agent(agent, removed, skipped) }

      # Templates BEFORE modules: a module's "still referenced" check below
      # excludes TemplateModule rows belonging to templates we are removing
      # in THIS SAME run — otherwise a dry-run would report a module as
      # referenced solely by a template the dry-run itself would also
      # remove, which is not what apply mode actually does (apply destroys
      # the template's TemplateModule rows first, then checks the module).
      # Computing removed_template_ids up front makes dry-run and apply
      # agree on the classification — the property that makes the report
      # trustworthy as a preview.
      candidates[:templates].each { |t| process_template(t, removed, skipped) }
      removed_template_ids = removed[:templates].map { |r| r[:id] }

      candidates[:modules].each { |m| process_module(m, removed, skipped, removed_template_ids: removed_template_ids) }
      candidates[:providers].each { |p| process_provider(p, removed, skipped) }

      Report.new(dry_run: @dry_run, counted: counted, removed: removed, skipped: skipped)
    end

    private

    def classify_candidates
      {
        agents:    ::Ai::Agent.where(name: SAMPLE_AGENT_NAMES).to_a,
        templates: ::System::NodeTemplate.where(name: SAMPLE_TEMPLATE_NAMES).to_a,
        modules:   ::System::NodeModule.where(name: SAMPLE_MODULE_NAMES).to_a,
        providers: ::System::Provider.where(provider_type: SAMPLE_PROVIDER_TYPE).to_a
      }
    end

    def process_agent(agent, removed, skipped)
      if agent.is_concierge? || agent.executions.exists? || agent.conversations.exists?
        skipped[:agents] << describe(agent, reason: "has real executions/conversations, or is concierge")
        return
      end

      removed[:agents] << describe(agent)
      return if @dry_run

      agent.destroy!
    end

    def process_template(template, removed, skipped)
      node_count = template.nodes.count
      if node_count.positive?
        skipped[:templates] << describe(template, reason: "node_count=#{node_count}")
        return
      end

      removed[:templates] << describe(template)
      return if @dry_run

      template.template_modules.destroy_all
      template.destroy!
    end

    def process_module(node_module, removed, skipped, removed_template_ids:)
      assignment_count = node_module.assignment_count
      remaining_template_refs = node_module.template_modules
                                            .where.not(node_template_id: removed_template_ids)
                                            .count
      if assignment_count.positive? || remaining_template_refs.positive?
        skipped[:modules] << describe(
          node_module,
          reason: "assignment_count=#{assignment_count} remaining_template_refs=#{remaining_template_refs}"
        )
        return
      end

      removed[:modules] << describe(node_module)
      return if @dry_run

      node_module.template_modules.destroy_all
      node_module.versions.destroy_all
      node_module.destroy!
    end

    def process_provider(provider, removed, skipped)
      in_use = ::System::NodeInstance.where(provider_region_id: provider.provider_regions.select(:id)).exists? ||
               ::System::NodeInstance.where(provider_instance_type_id: provider.provider_instance_types.select(:id)).exists?
      if in_use
        skipped[:providers] << describe(provider, reason: "real node instances reference this provider")
        return
      end

      removed[:providers] << describe(provider)
      return if @dry_run

      provider.destroy!
    end

    def describe(record, reason: nil)
      { id: record.id, class: record.class.name, name: (record.name if record.respond_to?(:name)), reason: reason }.compact
    end
  end
end
