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
      class AttributeFailureExecutor < BaseSkillExecutor
        # Look-back window. Anything older is unlikely to be the cause
        # (cf. trading post-mortem heuristics).
        DEFAULT_LOOKBACK = 24.hours

        skill_descriptor(
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
            confidence_state: :string,
            confidence_detail: :object,
            reasoning: :string
          }
        )

        binds_to "concierge"

        protected

        def perform(instance_id:, lookback_hours: 24)
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

          # The shared confidence rule, not a share of the total: a lone
          # candidate always holds 100% of the total, so share alone reported
          # certainty for every failure where only one place was looked at.
          # A candidate's evidence class is its kind (the path that surfaced
          # it). `confidence` is nil when nothing was measured — never 0.0,
          # which would claim "looked and found nothing".
          scored = ::Platform::Investigation::Confidence.for(
            merged.map { |c| { score: c[:score], evidence_classes: Array(c[:evidence_classes]).presence || [ c[:kind] ] } }
          )

          success(
            candidates: merged.first(10),
            top_candidate: top,
            confidence: scored[:value],
            confidence_state: scored[:state],
            confidence_detail: scored,
            reasoning: build_reasoning(instance, merged, top, since)
          )
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

        # A change to what THIS INSTANCE'S PLANE serves, inside the window, is
        # suspect. Increment 4b deleted the per-version ladder timestamps this
        # used to read (live_at / blessed_at / retired_at): they recorded a
        # label moving, which no node ever saw, so they could name a "change"
        # nothing experienced and miss every change something did.
        #
        # What actually changes a plane's served version depends on the KIND of
        # plane, so both are scored — reading only one would go silent for half
        # the fleet:
        #   PINNED plane   — a pin was written (ModuleEnvironmentPin#promoted_at)
        #   FOLLOWING plane — a publish moved current_version_id onto a version
        #                     created inside the window
        def score_promotion_changes(instance, since)
          environment = instance.environment
          assigned_module_ids = instance.node.node_modules.pluck(:id)
          return [] if assigned_module_ids.empty?

          if environment && !environment.follows_publish?
            pin_candidates(environment, assigned_module_ids, since)
          else
            publish_candidates(assigned_module_ids, since, environment)
          end
        end

        def pin_candidates(environment, module_ids, since)
          ::System::ModuleEnvironmentPin
            .where(environment_id: environment.id, node_module_id: module_ids)
            .where(promoted_at: since..)
            .includes(:node_module, :node_module_version)
            .map do |pin|
              promotion_candidate(
                module_id: pin.node_module_id, version: pin.node_module_version,
                module_name: pin.node_module&.name, at: pin.promoted_at,
                reason: "v#{pin.node_module_version&.version_number} promoted into #{environment.slug} " \
                        "#{pin.promoted_at.iso8601}"
              )
            end
        end

        # A following plane serves current_version, so the change it felt is a
        # PUBLISH. There is no timestamp on the pointer itself; the version's
        # own created_at is the honest proxy — a version that is current AND was
        # created inside the window is one the plane started running inside it.
        def publish_candidates(module_ids, since, environment)
          ::System::NodeModule
            .where(id: module_ids).where.not(current_version_id: nil)
            .includes(:current_version)
            .filter_map do |mod|
              version = mod.current_version
              next if version.nil? || version.created_at < since

              promotion_candidate(
                module_id: mod.id, version: version, module_name: mod.name, at: version.created_at,
                reason: "v#{version.version_number} published and served by " \
                        "#{environment&.slug || 'this plane'} #{version.created_at.iso8601}"
              )
            end
        end

        def promotion_candidate(module_id:, version:, module_name:, at:, reason:)
          {
            kind: "promotion",
            module_id: module_id,
            module_version_id: version&.id,
            module_name: module_name,
            score: 12,
            reasons: [ reason ],
            changed_at: at.iso8601
          }
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
      end
    end
  end
end
