# frozen_string_literal: true

module System
  module Fleet
    # Consulted by the MANUAL promotion paths — the operator REST promote
    # (Api::V1::System::NodeModuleVersionsController#promote) and its MCP twin
    # (Ai::Tools::SystemFleetTool#promote_module_version). Both call
    # NodeModuleVersion#promote_to! directly rather than going through
    # ModulePromotionService, so before IMP-d6826c872d88 neither one ever
    # evaluated PromotionCriteria: a human — or an agent over MCP — could bless
    # a version no instance had run for the dwell, and nothing in the response
    # or the audit log said the automated lane would have refused it.
    #
    # This does NOT refuse. Operator ruling D17 (2026-09-02): consult and WARN.
    # The manual paths exist precisely to act when the evidence is not there
    # (a two-instance fleet, an incident, a rollback), so taking the authority
    # away would break the escape hatch. What they were missing is the record —
    # a verdict in the result the caller reads, and a FleetEvent an auditor can
    # find later.
    #
    # Best-effort by construction: an audit sink that is down must never turn
    # into a failed promotion, so #record! rescues and logs. The emit itself
    # goes through EventBroadcaster (persist + broadcast), which already
    # swallows its own persistence failures.
    class ManualPromotionAdvisory
      EVENT_KIND = "system.module_promotion_criteria_override"

      # medium, not high: unlike system.module_promotion_withheld (a build
      # produced nothing usable and wants a human), this event records a human
      # who has ALREADY decided. It wants to be findable in an audit, not to
      # page anyone.
      SEVERITY = :medium

      REST_SOURCE = "rest_promote"
      MCP_SOURCE  = "mcp_promote_module_version"

      # Evaluate BEFORE the transition, so the verdict describes the state the
      # operator actually decided against, and so a promote_to! that raises
      # never leaves an override event behind (the caller only calls #record!
      # once the promotion landed).
      def self.evaluate(version:, target_state:)
        new(version: version, target_state: target_state,
            criteria: ::System::Fleet::PromotionCriteria.advisory(
              version: version, target_state: target_state
            ))
      end

      attr_reader :version, :target_state, :criteria

      def initialize(version:, target_state:, criteria:)
        @version      = version
        @target_state = target_state.to_s
        @criteria     = criteria
      end

      # Were the criteria relevant to this target state at all?
      def consulted?
        !criteria.nil?
      end

      # Did the promotion go ahead against an ineligible verdict?
      def warned?
        consulted? && !criteria[:eligible]
      end

      # Emits the audit event for an override and returns the fields the caller
      # merges into its result payload. Returns {} for an ungated target state,
      # so an untouched response shape stays untouched.
      #
      # `actor_type` is REQUIRED alongside `actor_id` because a User id and an
      # Ai::Agent id are both bare UUIDs — an auditor reading the event cannot
      # tell a human override from an agent one, and `source` does not settle it
      # either (a human over MCP and an agent over MCP share MCP_SOURCE). The
      # producer knows which principal it holds, so it declares it rather than
      # leaving the auditor to infer. Both keys stay PRESENT even when the
      # principal is anonymous (an `internal:`/instance-authorized MCP caller
      # carries neither a user nor an agent): an override with an unknown actor
      # is a fact worth recording, not a key worth dropping.
      def record!(source:, actor_id: nil, actor_type: nil)
        return {} unless consulted?

        emit_override_event!(source: source, actor_id: actor_id, actor_type: actor_type) if warned?
        result_fields
      end

      # The four principal kinds that can reach a manual promote. UNKNOWN_ACTOR
      # is written literally rather than omitted so an absent actor is visibly
      # absent instead of looking like a payload that predates the field.
      ACTOR_TYPES   = %w[user agent instance internal unknown].freeze
      UNKNOWN_ACTOR = "unknown"

      private

      def result_fields
        fields = { promotion_criteria: criteria }
        return fields unless warned?

        fields.merge(
          promotion_criteria_warning:
            "promoted to #{target_state} despite unmet promotion criteria: #{criteria[:reason]}"
        )
      end

      def emit_override_event!(source:, actor_id:, actor_type:)
        node_module = version.node_module

        ::System::Fleet::EventBroadcaster.emit!(
          account: node_module&.account,
          kind: EVENT_KIND,
          severity: SEVERITY,
          source: source,
          node_module_id: node_module&.id,
          node_module_version_id: version.id,
          # The criteria fields are compacted (a nil threshold is noise); the
          # actor pair is merged AFTER, so neither key can be compacted away.
          payload: {
            module_name:    node_module&.name,
            version_number: version.version_number,
            target_state:   target_state,
            reason:         criteria[:reason],
            running_count:  criteria[:running_count],
            required_count: criteria[:required_count],
            dwell_time_minutes: criteria[:dwell_time_minutes]
          }.compact.merge(
            actor_id:   actor_id,
            actor_type: normalize_actor_type(actor_type)
          )
        )
      rescue StandardError => e
        # The promotion has already happened; refusing to return here would
        # turn an observability failure into a 500 on a completed write.
        Rails.logger.warn(
          "[ManualPromotionAdvisory] override event emit failed for version " \
          "#{version.id}: #{e.class}: #{e.message}"
        )
        nil
      end

      def normalize_actor_type(actor_type)
        candidate = actor_type.to_s
        ACTOR_TYPES.include?(candidate) ? candidate : UNKNOWN_ACTOR
      end
    end
  end
end
