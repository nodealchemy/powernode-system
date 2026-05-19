# frozen_string_literal: true

module System
  module Ai
    module Skills
      # When an instance fails (transitions to error / drops heartbeat after
      # being healthy), this skill walks recent module assignment changes,
      # promotion events, and FleetEvents to compute *the most likely
      # blamed change*. Returns a ranked candidate list with confidence.
      #
      # Heuristic v0:
      #   - Score each NodeModuleAssignment touched in last 24h
      #   - Score each NodeModuleVersion promoted in last 24h
      #   - Boost weight by fleet-event severity recently associated with the module
      #   - Use ModuleDiffService to compute the *blast radius* of each candidate change
      #
      # M-D2-2 telemetry data layered in later: per-instance error metrics,
      # crash signatures from boot replay events.
      #
      # Reference: Golden Eclipse plan F-track creative — fleet "blame" attribution.
      class AttributeFailureExecutor
        # Look-back window. Anything older is unlikely to be the cause
        # (cf. trading post-mortem heuristics).
        DEFAULT_LOOKBACK = 24.hours

        def self.descriptor
          {
            name: "attribute_failure",
            description: "Given a failed NodeInstance, rank recent module changes + promotions by likelihood of being the cause",
            category: "devops",
            inputs: {
              instance_id: { type: "string", required: true },
              lookback_hours: { type: "integer", required: false, default: 24 }
            },
            outputs: {
              candidates: [ :object ],
              top_candidate: :object,
              confidence: :decimal,
              reasoning: :string
            }
          }
        end

        def initialize(account:, agent: nil, user: nil)
          @account = account
          @agent = agent
          @user = user
        end

        def execute(instance_id:, lookback_hours: 24)
          instance = ::System::NodeInstance.joins(:node)
                       .where(system_nodes: { account_id: @account.id })
                       .find_by(id: instance_id)
          return failure("instance not found in this account") unless instance

          lookback = (lookback_hours.to_i.clamp(1, 168)).hours
          since = Time.current - lookback

          candidates = []
          candidates.concat(score_assignment_changes(instance, since))
          candidates.concat(score_promotion_changes(instance, since))
          candidates.concat(score_event_correlations(instance, since))

          # Deduplicate by (kind, module_id) — the same module surfacing in
          # multiple paths gets its scores summed.
          merged = candidates.group_by { |c| [ c[:kind], c[:module_id] ] }.map do |_key, group|
            base = group.first.dup
            base[:score] = group.sum { |c| c[:score] }
            base[:reasons] = group.flat_map { |c| Array(c[:reasons]) }.uniq
            base
          end

          # Apply attribution feedback boosts: past confirmed attributions
          # for the same (kind, module_id) raise score; past rejections
          # downweight. Closes the feedback loop with AttributionFeedbackService.
          merged = apply_attribution_feedback(merged)
          merged = merged.sort_by { |c| -c[:score] }

          top = merged.first
          confidence = top.nil? ? 0.0 : (top[:score] / [ merged.sum { |c| c[:score] }.to_f, 1.0 ].max).round(3)

          success(
            candidates: merged.first(10),
            top_candidate: top,
            confidence: confidence,
            reasoning: build_reasoning(instance, merged, top, since)
          )
        rescue StandardError => e
          Rails.logger.error("[AttributeFailureExecutor] #{e.class}: #{e.message}")
          failure(e.message)
        end

        private

        def apply_attribution_feedback(candidates)
          return candidates unless defined?(::Ai::CompoundLearning)

          # Pull recent attribution learnings for this account.
          learnings = ::Ai::CompoundLearning
                      .where(account_id: @account.id, status: "active")
                      .where("tags @> ?", [ "fleet" ].to_json)
                      .where("tags @> ?", [ "attribution" ].to_json)
                      .limit(200)
          return candidates if learnings.empty?

          confirmed_keys = Set.new
          rejected_keys = Set.new
          learnings.each do |l|
            tags = Array(l.tags)
            kind_tag = tags.find { |t| t.start_with?("kind:") }&.sub("kind:", "")
            mod_tag  = tags.find { |t| t.start_with?("module:") }&.sub("module:", "")
            next if kind_tag.blank? || mod_tag.blank?
            key = [ kind_tag, mod_tag ]
            confirmed_keys << key if tags.include?("outcome:confirmed")
            rejected_keys  << key if tags.include?("outcome:rejected")
          end

          candidates.map do |c|
            key = [ c[:kind], c[:module_id] ]
            if confirmed_keys.include?(key)
              c.merge(score: (c[:score] * 1.5).round, feedback: "boosted_by_prior_confirmation")
            elsif rejected_keys.include?(key)
              c.merge(score: (c[:score] * 0.7).round, feedback: "downweighted_by_prior_rejection")
            else
              c
            end
          end
        end

        def score_assignment_changes(instance, since)
          ::System::NodeModuleAssignment
            .where(node_id: instance.node_id)
            .where("updated_at >= ?", since)
            .map do |asgn|
              {
                kind: "assignment_change",
                module_id: asgn.node_module_id,
                module_name: asgn.node_module&.name,
                score: 5,
                reasons: [ "assignment touched #{asgn.updated_at.iso8601}" ],
                changed_at: asgn.updated_at.iso8601
              }
            end
        end

        def score_promotion_changes(instance, since)
          # A promotion of a module assigned to this node within the window
          # is suspect; live promotion is the most-suspect (highest score).
          assigned_module_ids = instance.node.node_modules.pluck(:id)

          ::System::NodeModuleVersion
            .where(node_module_id: assigned_module_ids)
            .where("live_at >= ? OR blessed_at >= ? OR retired_at >= ?", since, since, since)
            .map do |v|
              score = 0
              reasons = []
              if v.live_at && v.live_at >= since
                score += 12
                reasons << "promoted to live #{v.live_at.iso8601}"
              end
              if v.blessed_at && v.blessed_at >= since
                score += 6
                reasons << "promoted to blessed #{v.blessed_at.iso8601}"
              end
              if v.retired_at && v.retired_at >= since
                score += 4
                reasons << "retired #{v.retired_at.iso8601}"
              end
              {
                kind: "promotion",
                module_id: v.node_module_id,
                module_version_id: v.id,
                module_name: v.node_module&.name,
                score: score,
                reasons: reasons,
                changed_at: (v.live_at || v.blessed_at || v.retired_at)&.iso8601
              }
            end
        end

        def score_event_correlations(instance, since)
          return [] unless defined?(::System::FleetEvent)

          # Events touching the same instance within the window contribute
          # severity-weighted score. Recent high-severity events from the
          # same module raise that module as a candidate.
          events = ::System::FleetEvent
                   .where(account: @account)
                   .where("emitted_at >= ?", since)
                   .where("node_instance_id = ? OR node_id = ?", instance.id, instance.node_id)

          events.group_by(&:node_module_id).filter_map do |module_id, ev_group|
            next if module_id.nil?
            severity_sum = ev_group.sum { |e| e.severity_weight.to_i }
            high_severity = ev_group.any? { |e| %w[high critical].include?(e.severity) }
            {
              kind: "event_correlation",
              module_id: module_id,
              module_name: ::System::NodeModule.where(account: @account).find_by(id: module_id)&.name,
              score: severity_sum + (high_severity ? 5 : 0),
              reasons: ev_group.first(3).map { |e| "event #{e.kind} (#{e.severity})" }
            }
          end
        end

        def build_reasoning(instance, candidates, top, since)
          if candidates.empty?
            "No suspect changes found in the last #{((Time.current - since) / 3600.0).round(1)}h. " \
            "The failure may pre-date the lookback window — try with a larger lookback_hours."
          else
            top_name = top[:module_name] || top[:module_id]
            "Most-likely cause: #{top_name} (kind=#{top[:kind]}, score=#{top[:score]}). " \
            "Rationale: #{Array(top[:reasons]).first(3).join('; ')}. " \
            "Considered #{candidates.size} candidates touching modules assigned to instance #{instance.id}."
          end
        end

        def success(payload)
          { success: true, data: payload }
        end

        def failure(msg)
          { success: false, error: msg }
        end
      end
    end
  end
end

# P3.3 discovery-based skill binding (dual-mode with existing seeds).
System::Ai::Skills::SkillBindings.register(
  System::Ai::Skills::AttributeFailureExecutor,
  agents: ["System Concierge", "Fleet Autonomy"]
)
