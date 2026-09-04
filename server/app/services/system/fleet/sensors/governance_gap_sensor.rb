# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # SENSE arm of the Platform Architect's sense → propose → materialise →
      # verify loop (HIER-P3, proposal §2 Phase 3 step 1).
      #
      # Every gap kind below is one the 2026-09-03 hierarchy audit found BY
      # HAND, reproduced here on every fleet tick so the platform reports its
      # own governance drift instead of waiting for the next audit:
      #
      #   category_unowned           a registered `system.` / `sdwan.` category
      #                              no PolicyDeclarations set declares (the
      #                              sdwan_federation_compose precedent: registered,
      #                              tunable, never reconciled)
      #   agent_without_skills       a declared identity whose canonical carries
      #                              a policy set and binds no skill
      #   binding_without_skill      a SIGNAL_BINDINGS lane bound to `skill: nil`
      #                              that nothing DECLARES deliberate — no
      #                              REMEDIATION_APPLIERS entry, not `advisory`,
      #                              not in either RemediationValidator
      #                              non-remediating list (declared-never-inferred,
      #                              the validator's own rule)
      #   executor_without_skill_row an executor the registry binds with no
      #                              GLOBAL Ai::Skill catalog row (the strict seed
      #                              would abort on it)
      #   binding_agent_unknown      an executor whose binds_to names no global
      #                              agent (a typo binds to nobody)
      #   skill_binding_missing      a registry-declared (agent, skill) pair with
      #                              no Ai::AgentSkill row — runtime-materialisable
      #   lineage_edge_missing       a canonical with no active edge under the
      #                              root (HierarchyReconciler drift, plus the
      #                              Platform Architect's edge the extension seed
      #                              writes by hand and the reconciler does not
      #                              report) — runtime-materialisable
      #   delegation_policy_missing  a canonical with no delegation policy —
      #                              runtime-materialisable
      #   policy_owner_undeclared    an extension-owned declared category's
      #                              agent-shape row parked on an agent the
      #                              declarations do not know (PolicyReconciler
      #                              never touches such a row); a core static
      #                              category the extension co-declares is
      #                              excluded — core writes it on its own agents
      #   tool_family_unregistered   a canonical's tool_access.tool_families entry
      #                              matching no registry action, exact or by
      #                              `<family>_` prefix (the ToolAllowlist rule)
      #
      # Every signal is `system.governance_gap`, severity by kind, fingerprinted
      # `governance_gap:<kind>:<subject>` — stable across ticks so a standing
      # gap dedups at the engine and updates its one offer; distinct per subject
      # so two gaps of one kind are two offers. The payload carries the concrete
      # gap (subject, ids, the files a code fix touches) and, for a kind the
      # runtime can close, a `materialization` hash the propose executor hands
      # to System::Governance::GapMaterializer under the ruling-3 gates.
      #
      # READ-SIDE ONLY (BaseSensor rule): the reconcilers' `drift` readers are
      # consulted with minting OFF, nothing is written, and each detector is
      # fenced so one raising cannot take the pass — and every other
      # fingerprint's absence evidence — down with it.
      class GovernanceGapSensor < BaseSensor
        SIGNAL_KIND = "system.governance_gap"

        SEVERITY_BY_KIND = {
          "category_unowned"           => :high,
          "executor_without_skill_row" => :high,
          "agent_without_skills"       => :medium,
          "binding_without_skill"      => :medium,
          "binding_agent_unknown"      => :medium,
          "lineage_edge_missing"       => :medium,
          "delegation_policy_missing"  => :medium,
          "skill_binding_missing"      => :low,
          "policy_owner_undeclared"    => :low,
          "tool_family_unregistered"   => :low
        }.freeze

        # Ai::ImprovementRecommendation::RECOMMENDATION_TYPES member per kind —
        # the offer type the propose executor files.
        RECOMMENDATION_TYPE_BY_KIND = {
          "category_unowned"           => "capability_gap",
          "executor_without_skill_row" => "skill_creation",
          "agent_without_skills"       => "skill_creation",
          "binding_without_skill"      => "capability_gap",
          "binding_agent_unknown"      => "capability_gap",
          "lineage_edge_missing"       => "team_composition",
          "delegation_policy_missing"  => "team_composition",
          "skill_binding_missing"      => "skill_creation",
          "policy_owner_undeclared"    => "capability_gap",
          "tool_family_unregistered"   => "capability_gap"
        }.freeze

        EXT = "extensions/system/server"
        FILES_BY_KIND = {
          "category_unowned"           => [ "#{EXT}/app/services/system/governance/policy_declarations.rb" ],
          "executor_without_skill_row" => [ "#{EXT}/db/seeds/system_skills_seed.rb" ],
          "agent_without_skills"       => [ "#{EXT}/app/services/system/ai/skills/skill_bindings.rb",
                                            "#{EXT}/db/seeds/system_skills_seed.rb" ],
          "binding_without_skill"      => [ "#{EXT}/app/services/system/fleet/decision_engine.rb",
                                            "#{EXT}/app/services/system/fleet/remediation_validator.rb" ],
          "binding_agent_unknown"      => [ "#{EXT}/app/services/system/ai/skills/skill_bindings.rb" ],
          "lineage_edge_missing"       => [ "#{EXT}/app/services/system/governance/hierarchy_reconciler.rb" ],
          "delegation_policy_missing"  => [ "#{EXT}/app/services/system/governance/hierarchy_reconciler.rb" ],
          "skill_binding_missing"      => [ "#{EXT}/app/services/system/ai/skills/skill_bindings_reconciler.rb" ],
          "policy_owner_undeclared"    => [ "#{EXT}/app/services/system/governance/policy_reconciler.rb" ],
          "tool_family_unregistered"   => []
        }.freeze

        # The prefixes this extension REGISTERS (lib/powernode_system/engine.rb
        # derives them from PolicyDeclarations); a core or private-extension
        # category is not this sensor's to declare.
        OWNED_CATEGORY_PREFIXES = %w[system. sdwan.].freeze

        # Only the declared root/child forest is a lineage subject. The core
        # forest's root edge is the reconciler's (CORE_ROOT_KEY); the
        # Engineering root's edge is written by db/seeds/system_agent_hierarchy.rb.
        ROOT_KEY = ::System::Governance::HierarchyReconciler::ROOT_KEY

        def self.default_thresholds
          { "max_per_tick" => 25 }
        end

        def sense
          signals = []
          detect(signals, "categories")  { category_unowned }
          detect(signals, "skills")      { agent_without_skills }
          detect(signals, "bindings")    { binding_without_skill }
          detect(signals, "registry")    { registry_gaps }
          detect(signals, "hierarchy")   { hierarchy_gaps }
          detect(signals, "policies")    { policy_owner_undeclared }
          detect(signals, "tools")       { tool_family_unregistered }

          budget(signals.uniq(&:fingerprint))
        end

        private

        # The cap must never DROP a fingerprint the validator is still scoring.
        #
        # RemediationValidator#validate_due! reads a due pending outcome's
        # ABSENCE from the pass as "the gap cleared" (effective), and its only
        # guard (F3-11(a), `failed_sensors`) covers a CRASHED sensor. A
        # truncated pass is not a crash — this sensor ran, its provenance is
        # present — so a fingerprint the cap pushed out would be scored
        # remediated and this lane's whole VERIFY arm
        # (fleet.governance_gap_stuck) would never fire for it. The sort is
        # stable, so the same low-severity subjects would be starved on every
        # subsequent tick as well.
        #
        # So the budget is spent in two tranches:
        #   1. every fingerprint with a PENDING outcome is pinned into the pass,
        #      cap or no cap — correctness beats the cap, and this tranche is
        #      bounded by what the lane itself proceeded on;
        #   2. the remainder rotates (never-acted first, then least-recently
        #      validated) so no gap is starved out of detection for ever — the
        #      replica_lag_sensor precedent, whose due-stamp rotation exists for
        #      exactly this reason.
        def budget(signals)
          cap = threshold(:max_per_tick).to_i
          ordered = signals.sort_by { |s| [ -s.severity_weight, s.fingerprint ] }
          return ordered if cap <= 0 || ordered.size <= cap

          pinned, rest = ordered.partition { |s| pending_fingerprints.include?(s.fingerprint) }
          rotated = rest.sort_by { |s| [ last_validated_at(s.fingerprint) || ROTATION_EPOCH, -s.severity_weight, s.fingerprint ] }
          (pinned + rotated).first([ cap, pinned.size ].max)
        end

        # Never-acted subjects sort ahead of every validated one.
        ROTATION_EPOCH = Time.at(0).utc.freeze

        def outcome_scope
          return ::System::Fleet::RemediationOutcome.none if account.nil?

          ::System::Fleet::RemediationOutcome.where(account_id: account.id, signal_kind: SIGNAL_KIND)
        end

        def pending_fingerprints
          @pending_fingerprints ||= outcome_scope.pending.distinct.pluck(:fingerprint).to_set
        rescue StandardError => e
          ::Rails.logger.warn("[GovernanceGapSensor] pending-outcome pin unavailable: #{e.class}: #{e.message}")
          @pending_fingerprints = Set.new
        end

        def last_validated_at(fingerprint)
          validated_stamps[fingerprint]
        end

        def validated_stamps
          @validated_stamps ||= outcome_scope.where.not(validated_at: nil)
                                             .group(:fingerprint)
                                             .maximum(:validated_at)
        rescue StandardError => e
          ::Rails.logger.warn("[GovernanceGapSensor] rotation stamps unavailable: #{e.class}: #{e.message}")
          @validated_stamps = {}
        end

        # One detector raising must not drop every other signal from the pass:
        # RemediationValidator reads a fingerprint's absence as "effective".
        def detect(signals, label)
          signals.concat(Array(yield))
        rescue StandardError => e
          ::Rails.logger.warn("[GovernanceGapSensor] #{label} detector skipped this tick: #{e.class}: #{e.message}")
        end

        def declarations = ::System::Governance::PolicyDeclarations

        def gap(kind, subject, payload = {}, materialization: nil)
          signal(
            kind: SIGNAL_KIND,
            severity: SEVERITY_BY_KIND.fetch(kind),
            payload: {
              "gap_kind" => kind,
              "subject" => subject.to_s,
              "severity" => SEVERITY_BY_KIND.fetch(kind).to_s,
              "recommendation_type" => RECOMMENDATION_TYPE_BY_KIND.fetch(kind),
              "files" => FILES_BY_KIND.fetch(kind),
              "materialization" => materialization
            }.merge(payload),
            fingerprint: "governance_gap:#{kind}:#{subject}"
          )
        end

        # ---- category_unowned -------------------------------------------------

        def declared_categories
          sets = declarations::POLICY_SETS.flat_map { |set| set[:policies].keys }
          (sets + declarations::MANUAL_OPERATION_POLICIES.keys).to_set
        end

        def category_unowned
          declared = declared_categories
          ::Ai::InterventionPolicy.registered_categories
            .select { |c| OWNED_CATEGORY_PREFIXES.any? { |p| c.start_with?(p) } }
            .reject { |c| declared.include?(c) }
            .sort
            .map do |category|
              gap("category_unowned", category,
                  { "summary" => "#{category} is registered (tunable in the Autonomy panel) but no PolicyDeclarations " \
                                 "set declares it, so PolicyReconciler never writes its row and no agent owns it" })
            end
        end

        # ---- agent_without_skills -------------------------------------------

        def canonical_for(key)
          identity = declarations::AGENT_IDENTITIES.fetch(key)
          ::Ai::Agent.global.find_by(source_key: key) ||
            ::Ai::Agent.global.find_by(name: identity[:name], agent_type: identity[:agent_type])
        end

        def canonicals
          @canonicals ||= declarations::AGENT_IDENTITIES.keys.to_h { |key| [ key, canonical_for(key) ] }.compact
        end

        def declared_policy_count(key)
          declarations::POLICY_SETS.select { |s| s[:scope] == "agent" && s[:agent_key] == key }
                                   .sum { |s| s[:policies].size }
        end

        def agent_without_skills
          @agents_without_skills = []
          canonicals.filter_map do |key, agent|
            next if declared_policy_count(key).zero?
            next if ::Ai::AgentSkill.active.exists?(ai_agent_id: agent.id)

            @agents_without_skills << agent.id
            pairs = registry_drift.missing_pairs.select { |p| p["agent_id"] == agent.id }
            materialization = if pairs.any?
              { "kind" => "skill_binding",
                "bindings" => pairs.map { |p| p.slice("agent_id", "skill_id", "skill_slug") } }
            end
            gap("agent_without_skills", key,
                { "agent_id" => agent.id, "agent_name" => agent.name,
                  "declared_policies" => declared_policy_count(key),
                  "summary" => "#{agent.name} carries #{declared_policy_count(key)} declared policies and binds no skill" },
                materialization: materialization)
          end
        end

        # ---- binding_without_skill ------------------------------------------

        def binding_without_skill
          engine = ::System::Fleet::DecisionEngine
          validator = ::System::Fleet::RemediationValidator
          engine::SIGNAL_BINDINGS.filter_map do |kind, binding|
            next if binding[:skill]
            next if engine::REMEDIATION_APPLIERS.key?(kind)
            next if binding[:advisory] == true
            next if validator::NON_REMEDIATING_ACTION_CATEGORIES.include?(binding[:action_category].to_s)
            next if validator::NON_REMEDIATING_SIGNAL_KINDS.include?(kind)

            gap("binding_without_skill", kind,
                { "action_category" => binding[:action_category].to_s,
                  "owner" => engine.owner_for(binding),
                  "summary" => "#{kind} routes to #{binding[:action_category]} with skill: nil, no applier, and no " \
                               "declaration that the lane is notify-only — a proceed there actuates nothing" })
          end
        end

        # ---- registry (executor rows, unknown agents, missing pairs) --------

        def registry_drift
          @registry_drift ||= ::System::Ai::Skills::SkillBindingsReconciler.new(strict: false).drift
        end

        def registry_gaps
          drift = registry_drift
          signals = drift.missing_skills.sort.map do |slug|
            gap("executor_without_skill_row", slug,
                { "summary" => "#{slug} is registered by an executor's binds_to and has no GLOBAL Ai::Skill row — " \
                               "the strict bindings seed aborts and the router never sees the skill" })
          end
          signals += drift.unknown_agents.sort.map do |name|
            gap("binding_agent_unknown", name,
                { "summary" => "an executor binds_to #{name.inspect}, which names no global agent" })
          end
          reported = Array(@agents_without_skills)
          signals + drift.missing_pairs.reject { |p| reported.include?(p["agent_id"]) }.map do |pair|
            gap("skill_binding_missing", "#{pair['agent_id']}:#{pair['skill_slug']}",
                { "agent_id" => pair["agent_id"], "agent_name" => pair["agent_name"],
                  "skill_id" => pair["skill_id"], "skill_slug" => pair["skill_slug"],
                  "summary" => "the registry binds #{pair['skill_slug']} to #{pair['agent_name']} and no Ai::AgentSkill row exists" },
                materialization: { "kind" => "skill_binding",
                                   "bindings" => [ pair.slice("agent_id", "skill_id", "skill_slug") ] })
          end
        end

        # ---- hierarchy ------------------------------------------------------

        def reconciler
          @reconciler ||= ::System::Governance::HierarchyReconciler.new(account: account, logger: ::Rails.logger)
        end

        # The root is the reconciler's own identity, not an AGENT_IDENTITIES key.
        def root
          return @root if defined?(@root)

          identity = ::System::Governance::HierarchyReconciler::ROOT_IDENTITY
          @root = ::Ai::Agent.global.find_by(source_key: ROOT_KEY) ||
                  ::Ai::Agent.global.find_by(name: identity[:name], agent_type: identity[:agent_type])
        end

        def hierarchy_gaps
          report = reconciler.drift
          signals = report.missing_edges.map do |edge|
            key = edge.split("/", 2).last
            child = edge_child(key)
            gap("lineage_edge_missing", edge,
                { "child_agent_id" => child&.id, "parent_agent_id" => root&.id,
                  "summary" => "#{child&.name || key} has no active lineage edge under System Concierge" },
                materialization: edge_materialization(key, child))
          end
          signals += report.missing_policies.map do |key|
            agent = key == ROOT_KEY ? root : canonical_for(key)
            attrs = key == ROOT_KEY ? reconciler.class.root_delegation : reconciler.class.child_delegation(key)
            gap("delegation_policy_missing", key,
                { "agent_id" => agent&.id,
                  "summary" => "#{agent&.name || key} has no delegation policy on this account" },
                materialization: (agent && { "kind" => "delegation_policy", "agent_id" => agent.id,
                                             "attributes" => attrs.deep_stringify_keys }))
          end
          signals + core_canonical_edge_gaps
        end

        def edge_child(key)
          return ::Ai::Agent.global.find_by(slug: ::System::Governance::HierarchyReconciler::CORE_ROOT_SLUG) \
            if key == ::System::Governance::HierarchyReconciler::CORE_ROOT_KEY

          canonical_for(key) if declarations::AGENT_IDENTITIES.key?(key)
        end

        def edge_materialization(key, child)
          return nil unless child && root

          { "kind" => "lineage_edge", "child_agent_id" => child.id, "parent_agent_id" => root.id, "agent_key" => key }
        end

        # The Engineering root (a CORE canonical) is attached under System
        # Concierge by db/seeds/system_agent_hierarchy.rb, not by the
        # reconciler, whose drift report therefore cannot see this edge.
        def core_canonical_edge_gaps
          return [] unless root

          declarations::CORE_CANONICAL_KEYS.filter_map do |key|
            child = canonical_for(key)
            next unless child
            next if ::Ai::AgentLineage.for_child(child.id).active.exists?(parent_agent_id: root.id)

            gap("lineage_edge_missing", "#{ROOT_KEY}/#{key}",
                { "child_agent_id" => child.id, "parent_agent_id" => root.id,
                  "summary" => "#{child.name} (a core canonical) has no active lineage edge under System Concierge" },
                materialization: edge_materialization(key, child))
          end
        end

        # ---- policy_owner_undeclared ----------------------------------------

        # Every id a declared identity can legitimately hold rows under: the
        # canonical, the account's override/clone (resolve_for, override-first,
        # NO minting — a sensor never writes) and any account row carrying the
        # declared source_key.
        def declared_agent_ids
          @declared_agent_ids ||= begin
            ids = canonicals.values.map(&:id)
            declarations::AGENT_IDENTITIES.each do |key, identity|
              resolved = ::Ai::Agent.resolve_for(account.id, name: identity[:name], agent_type: identity[:agent_type])
              ids << resolved.id if resolved
            end
            ids.concat(::Ai::Agent.owned_by_account(account.id).where(source_key: declarations::AGENT_IDENTITIES.keys).pluck(:id))
            ids.uniq.to_set
          end
        end

        # Only the categories this EXTENSION owns. A core static category the
        # extension co-declares (dev.campaign_propose, declared on the Platform
        # Architect for the routed lane) is legitimately written by core's own
        # seeds on OTHER core agents — the Platform Developer carries it too —
        # and those rows are core's, not a misplaced copy of ours.
        def extension_owned_categories
          declarations::AGENT_SET_OWNERS.keys.reject { |c| ::Ai::InterventionPolicy::STATIC_CATEGORIES.include?(c) }
        end

        def policy_owner_undeclared
          owners = declarations::AGENT_SET_OWNERS
          known = declared_agent_ids
          ::Ai::InterventionPolicy
            .where(account: account, scope: "agent", user_id: nil, action_category: extension_owned_categories)
            .where.not(ai_agent_id: nil)
            .includes(:agent)
            .reject { |row| known.include?(row.ai_agent_id) }
            .map do |row|
              gap("policy_owner_undeclared", "#{row.action_category}:#{row.ai_agent_id}",
                  { "action_category" => row.action_category, "agent_id" => row.ai_agent_id,
                    "agent_name" => row.agent&.name, "policy" => row.policy, "policy_id" => row.id,
                    "declared_owner" => owners[row.action_category],
                    "summary" => "#{row.action_category} (declared on #{owners[row.action_category]}) has an agent-shape row " \
                                 "on #{row.agent&.name || row.ai_agent_id}, which no declared identity resolves to" })
            end
        end

        # ---- tool_family_unregistered ---------------------------------------

        def registry_action_names
          @registry_action_names ||= ::Ai::ClaudeExport::ToolAllowlist::Registry.snapshot.action_names
        end

        def tool_family_unregistered
          canonicals.flat_map do |key, agent|
            families = Array(agent.mcp_metadata&.dig("tool_access", "tool_families")).map(&:to_s)
            next [] if families.empty?

            names = registry_action_names
            families.reject { |family| names.any? { |n| n == family || n.start_with?("#{family}_") } }.map do |family|
              gap("tool_family_unregistered", "#{key}:#{family}",
                  { "agent_id" => agent.id, "agent_name" => agent.name, "family" => family,
                    "files" => [ seed_file_for(key) ].compact,
                    "summary" => "#{agent.name}'s tool_access.tool_families names #{family.inspect}, which matches no " \
                                 "registered platform action (exact or `#{family}_` prefix)" })
            end
          end
        end

        def seed_file_for(key)
          if declarations::CORE_CANONICAL_KEYS.include?(key)
            "server/db/seeds/ai_engineering_agents_seed.rb"
          elsif key == "fleet-autonomy"
            "#{EXT}/db/seeds/fleet_autonomy_agent.rb"
          else
            "#{EXT}/db/seeds/system_#{key.tr('-', '_')}_agent.rb"
          end
        end
      end
    end
  end
end
