# frozen_string_literal: true

module System
  module Governance
    # Reconciles DECLARED governance rows into the running database, creating
    # only what is ABSENT.
    #
    # WHY THIS EXISTS -----------------------------------------------------
    # `db:seed` runs on FIRST BOOT ONLY (rails-start.sh gates it behind a
    # durable `.db-initialized` marker; later boots run `db:migrate` alone), so
    # a policy row added to a seed after an install's first boot never reaches
    # that install. The gate then resolves the missing row through
    # Ai::InterventionPolicyService's require_approval default, or — for a
    # DecisionEngine-routed lane — blocks every signal with only a WARN. Both
    # look exactly like a deliberate operator decision.
    #
    # WHY IT IS NOT "JUST RUN THE SEED ON EVERY BOOT" ---------------------
    # The seed path is DESTRUCTIVE by design, and safe today only because it
    # never re-runs:
    #
    #   * `upsert_manual_policies!` and AgentSetupHelpers#upsert_policies! both
    #     `assign_attributes(policy: <declared verb>, ...)` and save when
    #     `changed?` — so re-running RESETS an operator's deliberately tuned
    #     verb back to the seeded default.
    #   * system_manual_operation_policies.rb then `destroy_all`s every
    #     `system.task.*` global row whose category is not in the seed's key
    #     list.
    #
    # On first boot there is no operator intent to destroy. On every boot
    # thereafter both behaviours are live regressions — an operator who set
    # `system.task.terminate` to "block" would find it silently back at
    # "require_approval" after a deploy. That is a WORSE governance failure
    # than the gap this class closes.
    #
    # THE RULE: reconcile ABSENCE ONLY. Create a declared row that does not
    # exist. Never update an existing row's verb, never delete. An existing row
    # is operator intent until an operator says otherwise, and this class has no
    # way to distinguish "operator tuned it" from "an older seed wrote it".
    #
    # WHAT RECONCILING COSTS: IT CAN WIDEN AUTONOMY -----------------------
    # Ai::InterventionPolicyService#default_policy returns require_approval
    # when it finds no row, so absence is the STRICTEST resolution short of
    # "block". Creating a declared row therefore does not merely fill a hole —
    # for any declared verb looser than require_approval it REPLACES a parked
    # write with one that proceeds.
    #
    # As declared today that is a MINORITY of the set: of the 20 rows in
    # PolicyDeclarations::MANUAL_OPERATION_POLICIES, 5 are auto_approve and 5
    # notify_and_proceed — 10 that proceed without an approval where absence
    # would have parked. The other 10 are require_approval and so are no-ops on
    # resolution. Note that notify_and_proceed counts as a widening here: it
    # proceeds.
    #
    # (That set is now DERIVED from System::Task::COMMANDS — IMP-944567d41689 —
    # so the split moves whenever a command lands or leaves. The counts are
    # pinned in spec/services/system/governance/policy_reconciler_spec.rb.)
    #
    # This is defensible, and is the intended behaviour: it converges an
    # established install onto what its own first boot would have written, and
    # the declared verbs are the operator defaults. But it is a WIDENING, so
    # reconciling an install for the first time is an operator-visible change
    # in what proceeds unattended, not a silent repair. Capture the before
    # state and state the count.
    #
    # What it still cannot do is override intent: absence-only means an
    # operator's tuned row is never touched, and nothing here deletes.
    #
    # THE ONE EXCEPTION TO "NEVER TOUCH AN EXISTING ROW": RE-HOMING ---------
    # (HIER-P2A.) A declared key can MOVE from agent A's set to agent B's — the
    # 14 SDWAN remediation rows moved from Fleet Autonomy to SDWAN Manager once
    # the fleet tick learned to gate each binding under its declared owner. On
    # an established install that leaves the row on A, possibly with an
    # operator-tuned verb, possibly deactivated. Absence-only would create a
    # fresh DEFAULT row on B (the operator's tuning lost on the agent that now
    # decides) and leave the tuned one stale on A (a decoy on the agent that no
    # longer reads it). So when B lacks a declared key and A — a DECLARED agent
    # whose sets no longer declare that key — has it, the row is RE-HOMED:
    # ai_agent_id updated in place, verb / is_active / conditions / priority
    # PRESERVED, an AuditLog row written. Still never a verb change, still
    # never a delete. Idempotent: once moved, the row is simply present on B.
    #
    # WHAT THIS PROTECTS, EXACTLY. Since HIER-P2DECL the candidate test is
    # the explicit FORMER_OWNERS map first: a key the map names is re-homed
    # only from the agent(s) the map records as its former owner. The P2A
    # STRUCTURAL rule — any DECLARED agent (one in AGENT_IDENTITIES) whose
    # sets no longer declare the category — is the FALLBACK for a key the
    # map does not record, and it WARNS when it fires, because that rule also
    # matches an operator's own row: System::AutonomyActions#update takes an
    # arbitrary agent_id and does not check that the agent declares the
    # category, so an operator CAN park an agent-shape row on a declared
    # agent, and the structural rule would move it if the declared owner
    # lacked the row. A row on an agent OUTSIDE AGENT_IDENTITIES is never
    # touched by either rule. The AuditLog row is the record of every move;
    # the warn line is the record of a move nobody declared — record it in
    # FORMER_OWNERS or leave the row alone, but do not let it stay silent.
    class PolicyReconciler
      # The audit action every re-home writes. Registered into the core
      # AuditActions seam by lib/powernode_system/engine.rb beside the
      # lifecycle and CA audit vocabularies; AuditLog#action validates against
      # that union, so an unregistered token would make every re-home raise —
      # and roll back — rather than land unrecorded.
      REHOME_AUDIT_ACTION = "system.intervention_policy.rehomed"
      AUDITED_ACTIONS = [ REHOME_AUDIT_ACTION ].freeze

      # action_category → the AGENT_IDENTITIES keys that DECLARED it before
      # its current owner did. The record of every ownership move, written
      # when the move is made; #rehomable_row prefers it over the structural
      # rule (see the class header). An entry is honoured only while the
      # declarations agree with it — the named former agent must be a
      # declared identity and must not be the current owner —
      # policy_reconciler_rehome_spec pins that consistency so a key moved
      # BACK cannot leave a stale entry that re-homes the wrong way.
      #
      # Keys that gained an agent row without ever having one are NOT moves
      # and are deliberately absent: the platform-scaling pair, the cordon and
      # snapshot-delete keys (operator-only until wave 1 gave them a twin) and
      # system.sdwan_federation_compose (registered, declared by no set until
      # wave 1). Nothing held them at the agent shape, so there is nothing to
      # re-home and a map entry would name a former owner that never existed.
      FORMER_OWNERS = {
        # ---- HIER-P2A (recorded retroactively; the reconciler ran these on
        # the structural rule before the map existed). The 14 SDWAN / federation
        # remediations → SDWAN Manager, gitops drift → GitOps Reconciler, the
        # publication streak → Disk Image Manager. All from Fleet Autonomy.
        "system.federation_peer_remediate"            => %w[fleet-autonomy],
        "system.sdwan_peer_remediate"                 => %w[fleet-autonomy],
        "system.sdwan_key_rotate"                     => %w[fleet-autonomy],
        "system.sdwan_failover"                       => %w[fleet-autonomy],
        "system.sdwan_user_device_revoke"             => %w[fleet-autonomy],
        "system.sdwan_bgp_session_remediate"          => %w[fleet-autonomy],
        "system.sdwan_vip_failover"                   => %w[fleet-autonomy],
        "system.sdwan_credential_refresh"             => %w[fleet-autonomy],
        "system.sdwan_service_health_investigate"     => %w[fleet-autonomy],
        "system.sdwan_ovn_deployment_investigate"     => %w[fleet-autonomy],
        "system.sdwan_bgp_observation_investigate"    => %w[fleet-autonomy],
        "system.sdwan_apply_investigate"              => %w[fleet-autonomy],
        "system.sdwan_user_device_config_investigate" => %w[fleet-autonomy],
        "system.federation_acceptance"                => %w[fleet-autonomy],
        "system.gitops_drift_remediate"               => %w[fleet-autonomy],
        "system.disk_image_publication_investigate"   => %w[fleet-autonomy],

        # ---- HIER-P2DECL wave 1: 35 keys off Fleet Autonomy.
        # → Capacity Manager: the capacity group (5), the instance-pool agent
        #   set (8, formerly the "instance-pool-agent" set keyed
        #   fleet-autonomy) and the provisioning set (6, formerly the
        #   "provisioning" set keyed fleet-autonomy).
        "system.instance_replace"            => %w[fleet-autonomy],
        "system.instance_reap"               => %w[fleet-autonomy],
        "system.region_expansion"            => %w[fleet-autonomy],
        "system.capacity_resize"             => %w[fleet-autonomy],
        "system.relocate_workload"           => %w[fleet-autonomy],
        "system.instance_pool_create"        => %w[fleet-autonomy],
        "system.instance_pool_update"        => %w[fleet-autonomy],
        "system.instance_pool_ceiling_raise" => %w[fleet-autonomy],
        "system.instance_pool_archive"       => %w[fleet-autonomy],
        "system.instance_pool_delete"        => %w[fleet-autonomy],
        "system.instance_pool_replenish"     => %w[fleet-autonomy],
        "system.instance_pool_drain"         => %w[fleet-autonomy],
        "system.instance_pool_acquire"       => %w[fleet-autonomy],
        "project.adapt"                      => %w[fleet-autonomy],
        "project.cost_control"               => %w[fleet-autonomy],
        "project.scale_horizontal"           => %w[fleet-autonomy],
        "project.relocate"                   => %w[fleet-autonomy],
        "project.schema_change"              => %w[fleet-autonomy],
        "project.security_change"            => %w[fleet-autonomy],
        # → Storage Manager: the storage group (2).
        "system.storage_assignment_reconcile" => %w[fleet-autonomy],
        "system.restore_volume"               => %w[fleet-autonomy],
        # → Ingress Manager: the ingress group (4) + service_backends_update.
        "system.acme_certificate_provision" => %w[fleet-autonomy],
        "system.expose_service_local"       => %w[fleet-autonomy],
        "system.expose_service_public_tcp"  => %w[fleet-autonomy],
        "system.expose_service_publicly"    => %w[fleet-autonomy],
        "system.service_backends_update"    => %w[fleet-autonomy],
        # → Supply Chain Manager: the supply-chain group (7).
        "system.package_repository.sync" => %w[fleet-autonomy],
        "system.package_module.create"   => %w[fleet-autonomy],
        "system.package_module.refresh"  => %w[fleet-autonomy],
        "system.architecture.propose"    => %w[fleet-autonomy],
        "system.architecture.create"     => %w[fleet-autonomy],
        "system.architecture.update"     => %w[fleet-autonomy],
        "system.architecture.delete"     => %w[fleet-autonomy],
        # → System Topology Designer: the two composer categories (2). THESE
        #   TWO RE-HOME ON WAVE 1, unlike the 33 above: that agent is already
        #   seeded, so its set is not skipped and the first reconcile after
        #   the declarations deploy moves them (policy_reconciler_rehome_spec
        #   pins it). See the wave-1 header in PolicyDeclarations.
        "system.multi_tenant_isolation"    => %w[fleet-autonomy],
        "system.service_discovery_compose" => %w[fleet-autonomy]
      }.freeze

      Result = Struct.new(:created, :already_present, :created_categories,
                          :skipped_sets, :shadowed, :rehomed, keyword_init: true) do
        def changed? = created.positive? || Array(rehomed).any?
      end

      DriftReport = Struct.new(:missing, :present, :skipped_sets, keyword_init: true) do
        # A SKIPPED set is drift, not a neutral outcome. An install that enables
        # this extension AFTER its first boot never seeds the agents (db:seed is
        # first-boot only — the whole argument this class exists for), so every
        # agent set skips — the eleven agent-keyed sets, which hold roughly
        # two-thirds of every row PolicyDeclarations declares. Counting only
        # `missing` reported that install as CLEAN: the skipped set contributes
        # no missing rows precisely because it was never examined. (No literal
        # counts here on purpose: they are sums over PolicyDeclarations and
        # moved four times in a week — "~168 of 195", "119 of 191", "136 of
        # 207", "133 of 206" — each revision leaving the previous one wrong;
        # sum `POLICY_SETS` when a figure is needed; nothing asserts it.)
        #
        # That is the flagship scenario the reconciler was built for, and it was
        # the one it stayed silent about.
        def drifted? = missing.any? || skipped_sets.any?

        # The subset of `missing` that reconcile! would satisfy by MOVING an
        # existing row from its former owner rather than creating one — named
        # so an operator reading the report before a deploy knows which of
        # their tuned rows are about to change agent.
        def rehomable = missing.select(&:rehome_from)
      end

      # One declared row that the database lacks. `to_s` is what the rake task
      # and the boot summary print, so it names the SET as well as the category
      # — the same category is declared by more than one set (instance-pool
      # declares eight at the agent shape and its gated four at the operator
      # shape) and "which one is missing" is the whole question. `rehome_from`
      # is the NAME of the former-owner agent still holding the row, when one
      # does.
      MissingRow = Struct.new(:set_key, :action_category, :policy, :rehome_from, keyword_init: true) do
        def to_s
          rehome_from ? "#{set_key}/#{action_category} (re-home from #{rehome_from})" : "#{set_key}/#{action_category}"
        end
      end

      def initialize(account:, logger: Rails.logger)
        @account = account
        @logger = logger
      end

      # Creates every declared row the account is missing. Returns a Result.
      # Idempotent: a second call on an unchanged database creates nothing.
      def reconcile!
        created = []
        shadowed = []
        rehomed = []
        present = 0
        skipped = []

        each_set do |set, agent, skip_reason|
          if skip_reason
            skipped << "#{set[:key]}(#{skip_reason})"
            next
          end

          existing = existing_categories(set, agent)
          set[:policies].each do |action_category, verb|
            if existing.include?(action_category)
              present += 1
              next
            end

            if (stale = rehomable_row(set, agent, action_category))
              # Name the FORMER owner before the move: rehome! rewrites
              # ai_agent_id, and every arm of stale_owner_name keys off that
              # column, so reading it afterwards reports the destination.
              former_owner = stale_owner_name(stale)

              if rehome!(stale, set, agent)
                rehomed << "#{set[:key]}/#{action_category} (from #{former_owner})"
                next
              end
            end

            ::Ai::InterventionPolicy.create!(
              account: @account,
              action_category: action_category,
              scope: set[:scope],
              ai_agent_id: agent&.id,
              user_id: nil,
              policy: verb,
              priority: set[:priority],
              is_active: true,
              conditions: conditions_for(set, action_category),
              preferred_channels: %w[notification]
            )
            created << "#{set[:key]}/#{action_category}"

            # An agent-scoped row OUT-RANKS a global one at any priority
            # (Ai::InterventionPolicy#specificity_key is lexicographic), so
            # creating this row can change what an agent caller resolves even
            # though we touched no existing row. Absence-only cannot tell
            # "never seeded" from "operator deleted the agent row to fall back
            # to their tuned global floor", and deleting a policy IS an
            # expressible operator action — so surface it rather than let the
            # change happen unremarked.
            shadowed << "#{set[:key]}/#{action_category}" if set[:scope] == "agent" && global_row?(action_category)
          end
        end

        unless created.empty?
          @logger.info(
            "[GovernanceReconciler] created #{created.size} missing policy row(s) " \
            "for account #{@account.id}: #{created.join(', ')}"
          )
        end
        unless rehomed.empty?
          @logger.info(
            "[GovernanceReconciler] re-homed #{rehomed.size} policy row(s) onto their declared owner " \
            "for account #{@account.id}: #{rehomed.join(', ')}"
          )
        end

        Result.new(
          created: created.size,
          already_present: present,
          created_categories: created,
          skipped_sets: skipped,
          shadowed: shadowed,
          rehomed: rehomed
        )
      end

      # Read-only: what the code declares that the database lacks. Safe to call
      # from a health check or a CI assertion — mutates nothing.
      #
      # NOTE it does NOT filter on is_active. A deactivated row is PRESENT: an
      # operator turning a control off must not have it silently recreated on
      # the next boot, so deactivate — not delete — is the durable off switch.
      # (On the FleetAutonomyService pre-gate, whose permitted_actions DOES
      # filter is_active, "off" means the lane hard-blocks. Off is off there,
      # not a fall-through to some looser row.)
      def drift
        missing = []
        present = []
        skipped = []

        each_set do |set, agent, skip_reason|
          if skip_reason
            skipped << "#{set[:key]}(#{skip_reason})"
            next
          end

          existing = existing_categories(set, agent)
          set[:policies].each do |action_category, verb|
            if existing.include?(action_category)
              present << "#{set[:key]}/#{action_category}"
            else
              stale = rehomable_row(set, agent, action_category)
              missing << MissingRow.new(set_key: set[:key], action_category: action_category, policy: verb,
                                        rehome_from: (stale_owner_name(stale) if stale))
            end
          end
        end

        DriftReport.new(missing: missing, present: present.sort, skipped_sets: skipped)
      end

      private

      # The manual operator set, expressed in the same record shape as the
      # declared agent sets so there is ONE iteration and no special case.
      def manual_set
        {
          key: "manual-operations",
          agent_key: nil,
          scope: PolicyDeclarations::MANUAL_OPERATION_SCOPE[:scope],
          priority: PolicyDeclarations::MANUAL_OPERATION_ATTRIBUTES[:priority],
          conditions: PolicyDeclarations::MANUAL_OPERATION_ATTRIBUTES[:conditions],
          policies: PolicyDeclarations::MANUAL_OPERATION_POLICIES
        }
      end

      def declared_sets = [ manual_set ] + PolicyDeclarations::POLICY_SETS

      # Yields (set, agent, skip_reason). skip_reason is non-nil when the set
      # cannot be reconciled — today only "agent absent". A set is SKIPPED, never
      # written at a different shape: declaring "whatever shape the database
      # happens to have" would make drift unfalsifiable.
      def each_set
        declared_sets.each do |set|
          if set[:agent_key].nil?
            yield set, nil, nil
            next
          end

          agent = resolve_agent(set[:agent_key])
          yield set, agent, (agent ? nil : "agent absent")
        end
      end

      # Resolve EXACTLY as the runtime does, or the rows land on an agent the
      # gate never reads. The rule lives in System::Governance::AgentResolver
      # and is shared with FleetAutonomyService#for_owner — the reader — so the
      # writer and the reader cannot drift apart (they did: a bare
      # `find_by(source_key:)` here wrote rows against the GLOBAL agent id while
      # the gate asked the account's OVERRIDE id, and the drift report said
      # "present" forever).
      #
      # Memoized per (account, key) — the same agent backs several sets.
      def resolve_agent(agent_key)
        @agents ||= {}
        return @agents[agent_key] if @agents.key?(agent_key)

        @agents[agent_key] = AgentResolver.resolve(account_id: @account.id, agent_key: agent_key)
      end

      # ---- re-homing ----------------------------------------------------------

      # The row a FORMER owner still holds for a key now declared on `agent`,
      # or nil. Only agent-shape rows (scope "agent", no user) qualify — an
      # operator-shape row is a different audience, not a former home.
      #
      # Two rules, in order (HIER-P2DECL):
      #   1. FORMER_OWNERS names the category → a candidate is a row on one of
      #      the agents it names (resolved the same way the sets are). A row
      #      on any other agent — declared or not — is left alone.
      #   2. Otherwise the P2A STRUCTURAL rule: a DECLARED agent (one of
      #      AGENT_IDENTITIES) whose agent-scoped sets no longer declare the
      #      category. Fires with a WARN naming the gap in the map, once per
      #      category per run.
      # A row on an agent outside AGENT_IDENTITIES is an operator's own and
      # is never a candidate under either rule.
      #
      # Deterministic: the oldest candidate wins. Two former owners holding the
      # same key is not a state the declarations can produce (a category is
      # declared on one agent), so a second candidate would be operator-made
      # and is left where it is.
      def rehomable_row(set, agent, action_category)
        return nil unless set[:scope] == "agent" && agent

        candidates = ::Ai::InterventionPolicy
          .where(account: @account, scope: "agent", user_id: nil, action_category: action_category)
          .where.not(ai_agent_id: [ nil, agent.id ])
          .order(:created_at, :id)

        if (recorded = FORMER_OWNERS[action_category])
          former_ids = recorded.filter_map { |key| resolve_agent(key)&.id }
          return candidates.detect { |row| former_ids.include?(row.ai_agent_id) }
        end

        stale = candidates.detect { |row| former_owner_key(row.ai_agent_id, action_category) }
        warn_unrecorded_move(set, action_category, stale) if stale
        stale
      end

      def warn_unrecorded_move(set, action_category, row)
        @warned_unrecorded ||= Set.new
        return unless @warned_unrecorded.add?(action_category)

        @logger.warn(
          "[GovernanceReconciler] #{set[:key]}/#{action_category} is re-homable from " \
          "#{stale_owner_name(row)} by the structural rule, but that move is not recorded in " \
          "PolicyReconciler::FORMER_OWNERS — record it, or the row is an operator's own and should stay"
        )
      end

      # The declared key of the agent holding `agent_id`, when that agent's own
      # sets do NOT declare `action_category` any more; nil otherwise.
      def former_owner_key(agent_id, action_category)
        key = declared_agent_ids[agent_id]
        return nil unless key
        return nil if declared_categories_for(key).include?(action_category)

        key
      end

      # ai_agent_id → agent_key for every declared agent that resolves on this
      # account. Built lazily from the same resolver the sets use.
      def declared_agent_ids
        @declared_agent_ids ||= PolicyDeclarations::AGENT_IDENTITIES.keys.each_with_object({}) do |key, ids|
          resolved = resolve_agent(key)
          ids[resolved.id] = key if resolved
        end
      end

      def declared_categories_for(agent_key)
        @declared_categories_for ||= Hash.new do |memo, key|
          memo[key] = PolicyDeclarations::POLICY_SETS
            .select { |s| s[:scope] == "agent" && s[:agent_key] == key }
            .flat_map { |s| s[:policies].keys }
            .to_set
        end
        @declared_categories_for[agent_key]
      end

      def stale_owner_name(row)
        return nil unless row

        row.agent&.name || declared_agent_ids[row.ai_agent_id] || row.ai_agent_id
      end

      # Move ONE row onto its declared owner, atomically with its audit row.
      # Returns true on success; false (logged at error level) when either
      # write fails, in which case the caller falls through to creating a
      # fresh row on the owner exactly as before — the stale row stays where
      # it was and the next drift report names it again. Preserves every
      # attribute except ai_agent_id: the verb, is_active, conditions and
      # priority are the operator's intent and travel with the row.
      def rehome!(row, set, agent)
        old_agent_id = row.ai_agent_id
        old_key = declared_agent_ids[old_agent_id]

        ::Ai::InterventionPolicy.transaction do
          row.update!(ai_agent_id: agent.id)
          write_rehome_audit!(row, set, old_agent_id, old_key, agent)
        end
        true
      rescue StandardError => e
        @logger.error(
          "[GovernanceReconciler] could not re-home #{set[:key]}/#{row.action_category} " \
          "from agent #{old_agent_id} to #{agent.id} for account #{@account.id}: #{e.class}: #{e.message}"
        )
        false
      end

      def write_rehome_audit!(row, set, old_agent_id, old_key, agent)
        return unless defined?(::AuditLog)

        ::AuditLog.log_action(
          action: REHOME_AUDIT_ACTION,
          resource: row,
          user: nil,
          account: @account,
          old_values: { "ai_agent_id" => old_agent_id, "agent_key" => old_key },
          new_values: { "ai_agent_id" => agent.id, "agent_key" => set[:agent_key] },
          source: "system",
          severity: "medium",
          risk_level: "medium",
          metadata: {
            "set_key" => set[:key],
            "action_category" => row.action_category,
            "policy" => row.policy,
            "is_active" => row.is_active,
            "reason" => "declared owner changed; row re-homed by PolicyReconciler"
          }
        )
      end

      def existing_categories(set, agent)
        ::Ai::InterventionPolicy
          .where(account: @account, scope: set[:scope], ai_agent_id: agent&.id, user_id: nil)
          .where(action_category: set[:policies].keys)
          .pluck(:action_category)
          .to_set
      end

      def global_row?(action_category)
        ::Ai::InterventionPolicy
          .exists?(account: @account, scope: "global", ai_agent_id: nil, action_category: action_category)
      end

      def conditions_for(set, action_category)
        (set[:condition_overrides] || {}).fetch(action_category, set[:conditions])
      end
    end
  end
end
