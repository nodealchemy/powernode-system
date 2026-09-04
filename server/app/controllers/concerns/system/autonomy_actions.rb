# frozen_string_literal: true

module System
  # Operator-facing CRUD over `Ai::InterventionPolicy` rows scoped to the
  # System extension's domains. Powers the System Settings → Autonomy modal
  # where operators configure per-action policy + approval chain assignment
  # for each of the system agents that carry intervention policies (see
  # SYSTEM_AGENT_NAMES) plus Manual Operations.
  #
  # This concern returns the full payload with three views: by_domain,
  # by_agent, by_action.
  #
  # `by_domain` is no longer a spare view. Since IMP-0874acd5b50c the Settings
  # modal builds its sections AND its per-action rows from it; it used to render
  # a list literal-ed into SystemSettingsPanel.tsx, which is how it came to omit
  # 28 of the 119 seeded categories and to show one control whose seed had been
  # deleted. So a SYSTEM category reaches an operator only through this payload:
  # add a prefix to DOMAIN_PREFIXES and it renders with no frontend change.
  #
  # This stays an ACCOUNT-WIDE view and must keep returning every row: `all_policies`
  # is deliberately unfiltered, so core's own rows (`approval`, `proposal`,
  # `escalation`, `status_update`, `issue_alert`, `feedback` from
  # server/db/seeds/autonomy_data_seed.rb, plus every `dev.*`) come back too and
  # land in the "other" catch-all, since no prefix here claims them. Do NOT
  # filter them out at this layer — hiding rows from an account-wide view is the
  # same defect class as by_agent silently dropping agents. The System modal
  # skips the "other" bucket on its own side, which it can do safely only
  # because autonomy_domain_pivot_spec.rb pins that no registered system./sdwan.
  # category ever reaches it.
  module AutonomyActions
    extend ActiveSupport::Concern

    # The system agents `by_agent_pivot` builds a bucket for, and the agents
    # `serialize_agents` ships. Membership is one question: does the extension
    # seed agent-scoped `Ai::InterventionPolicy` rows for it? A policy-carrying
    # agent left out has its rows DROPPED from the pivot; an agent with no
    # policies added in ships a permanently empty bucket.
    #
    # That is why this is eleven of the extension's twelve official agents:
    # every agent that keys an agent-scoped set in
    # System::Governance::PolicyDeclarations::POLICY_SETS. System Concierge
    # (`assistant`, chat router) carries no intervention policies — its seed
    # writes no policy row and no set declares it — so it is deliberately
    # absent rather than overlooked. GitOps Reconciler WAS overlooked: it
    # landed in the same wave as Topology Designer with three seeded
    # `system.gitops_*` policies and this list was not extended with it
    # (IMP-e3a30e2dd5ee). System Topology Designer used to be absent for the
    # Concierge's reason and is listed since HIER-P2DECL, when it took the
    # topology set (TOPOLOGY_DESIGNER_POLICIES); the four operations managers
    # were listed from the moment their sets were declared (wave 1), ahead of
    # their wave-2 seeds — the rows the reconciler writes for them the first
    # boot after the agent exists must have a bucket waiting, not be dropped
    # until someone remembers.
    #
    # ORDER IS NOT SIGNIFICANT here, unlike DOMAIN_PREFIXES immediately below.
    # That map resolves with `find` on a string PREFIX, so an entry extending
    # another's prefix must precede it; this list is matched on whole-name
    # equality through `Ai::Agent.resolve_for` and only sets the key order of
    # the emitted `by_agent` hash, which no client reads as a ranking. Append
    # freely — and do not copy the warning next door onto this constant.
    #
    # Kept as a literal rather than derived: a controller cannot read db/seeds
    # at request time, and deriving from the account's own policy rows would
    # make the pivot's shape a function of the data it pivots (a fresh account
    # would report no system agents; an operator's own agent holding one system
    # policy would be promoted into this list). The DERIVATION lives in the
    # oracle instead — spec/controllers/api/v1/system/autonomy_agent_pivot_spec.rb
    # derives the set from POLICY_SETS × AGENT_IDENTITIES (the population
    # PolicyReconciler writes agent-scoped rows for) and fails on drift in
    # either direction.
    SYSTEM_AGENT_NAMES = [
      "Fleet Autonomy",
      "SDWAN Manager",
      "CVE Responder",
      "Disk Image Manager",
      "Runtime Manager",
      "GitOps Reconciler",
      "Capacity Manager",
      "Storage Manager",
      "Ingress Manager",
      "Supply Chain Manager",
      "System Topology Designer",
      # HIER-P3: a CORE canonical carrying an extension-declared set
      # (PolicyDeclarations::PLATFORM_ARCHITECT_POLICIES) — the pivot derives
      # from POLICY_SETS × AGENT_IDENTITIES, and it is in both.
      "Platform Architect"
    ].freeze

    # ORDER IS SIGNIFICANT. `by_domain_pivot` resolves with `find`, so the FIRST
    # matching entry wins and any prefix that EXTENDS another entry's prefix has
    # to be declared before it. Three such pairs exist today:
    #
    #   system.instance_pool_           ⊂ system.instance_  (node_lifecycle)
    #   system.module_critical_upgrade_ ⊂ system.module_    (node_lifecycle)
    #   system.sdwan_federation_compose ⊂ system.sdwan_     (topology)
    #
    # The first two were mis-filed until this map was ordered specific-first:
    # the whole `instance_pool` domain was unreachable, and the CVE Responder's
    # `system.module_critical_upgrade_ready` landed under node_lifecycle. Note
    # that category is NOT prefixed `system.cve_`, so moving "cve" ahead of
    # "node_lifecycle" does not on its own file it correctly — the specific
    # prefix has to be listed too.
    #
    # Every category the extension REGISTERS (lib/powernode_system/engine.rb,
    # the same registry #update below admits) must match some entry here — not
    # just the seeded ones: a registered-but-unseeded category reaches this
    # pivot the moment an operator PATCHes a policy row for it. "other" is the
    # catch-all for rows whose category this extension does not own.
    # spec/controllers/api/v1/system/autonomy_domain_pivot_spec.rb pins both
    # properties (no registered system./sdwan. category reaches "other"; no
    # declared domain is left unreachable) so a new family or a reorder cannot
    # regress silently.
    DOMAIN_PREFIXES = {
      "instance_pool"     => %w[system.instance_pool_],
      "cve"               => %w[system.cve_ system.module_critical_upgrade_],
      # The System Topology Designer's composer trio — since HIER-P2DECL all
      # three are declared on that agent's own set
      # (PolicyDeclarations::TOPOLOGY_DESIGNER_POLICIES; sdwan_federation_
      # compose was registered-and-unseeded until then, the other two sat in
      # FLEET_AUTONOMY_POLICIES since IMP-4ba48fd088ce). Kept as a family
      # here regardless of ownership: the pivot is by FAMILY, not by owner.
      # Declared BEFORE "sdwan" because system.sdwan_federation_compose
      # extends system.sdwan_ and first match wins.
      "topology"          => %w[system.sdwan_federation_compose system.multi_tenant_isolation system.service_discovery_compose],
      "sdwan"             => %w[system.sdwan_ sdwan. system.federation_],
      "container_runtime" => %w[system.runtime_],
      "disk_image"        => %w[system.disk_image_],
      "gitops"            => %w[system.gitops_],
      # ONE spelling here too (IMP-2effedffc990): `system.package_module_` used
      # to pivot PackageModuleCreateExecutor's derived
      # system.package_module_create beside the seeded
      # system.package_module.create row — same interim, same fix as the
      # architecture family below.
      "packages"          => %w[system.package_module. system.package_repository.],
      # ONE spelling (IMP-51e5c6184ae4). `system.architecture_<verb>` — the
      # gated executors' derived categories under APO-1c — used to be listed
      # here alongside the seeded `system.architecture.<verb>` rows so the modal
      # at least filed both under one domain. The executors now DECLARE the
      # dotted category, the underscored rows are retired, and a second
      # spelling must not come back: it would render as a SECOND control over
      # the same action, which pivoting it into this domain hides rather than
      # fixes.
      "architecture"      => %w[system.architecture.],
      # system.volume_snapshot_ — the gated snapshot delete (IMP-e025722ef14e),
      # and the schedule family the snapshot sensor will route to.
      "storage"           => %w[system.storage_ system.restore_volume system.volume_snapshot_],
      # Service exposure + certificate issuance (APO-1c gated executors).
      # system.service_backends_ — the SystemIngressTool backend-set gate
      # (IMP-0c10b9fd5596). A UI BUCKET, and since HIER-P2DECL also where the
      # category is OWNED: it travels with the ingress group in
      # PolicyDeclarations::INGRESS_MANAGER_POLICIES (HIER-P2A had filed it
      # here while leaving ownership on Fleet Autonomy; the two axes agree
      # now).
      "ingress"           => %w[system.expose_service_ system.acme_certificate_ system.service_backends_],
      # Platform-deployment scaling (APO-3b): the hub-excluded replica reconciler.
      "platform"          => %w[system.platform.],
      # DELIBERATE: project.* is core-owned (Ai::InterventionPolicy::STATIC_CATEGORIES). Claiming it here is a
      # display choice for this account-wide view, not a core→extension dependency (that arrow points the
      # permitted way) — do NOT "fix" by filtering core rows out. Ruled 2026-08-23 (IMP-fa63f411633b).
      "project"           => %w[project.],
      "node_lifecycle"    => %w[system.cert_ system.acme_cert_ system.module_ system.instance_ system.fleet_ system.region_ system.capacity_ system.capability_gap_ system.observation system.task. system.task_ system.template_closure_ system.node_boot_image_ system.node_lkg_ system.fulfill_capability_ system.relocate_ system.replica_promote]
    }.freeze

    # GET /api/v1/system/autonomy
    def show
      payload = {
        agents: serialize_agents,
        chains: serialize_chains,
        policies: {
          by_action:  by_action_pivot,
          by_agent:   by_agent_pivot,
          by_domain:  by_domain_pivot
        }
      }
      render_success(data: payload)
    end

    # PATCH /api/v1/system/autonomy
    # body: { updates: [{action_category, policy, approval_chain_id, agent_id (or null), scope}, ...] }
    def update
      updates = Array(params[:updates] || params.dig(:autonomy, :updates))
      return render_error("updates array required", status: :bad_request) if updates.empty?

      changed_count = 0
      errors = []

      updates.each_with_index do |raw, idx|
        attrs = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h
        attrs = attrs.with_indifferent_access

        action_category = attrs[:action_category]
        next errors << "[#{idx}] action_category required" if action_category.blank?
        next errors << "[#{idx}] unknown category #{action_category}" unless ::Ai::InterventionPolicy.category_registered?(action_category)

        policy_value = attrs[:policy]
        next errors << "[#{idx}] policy required" if policy_value.blank?
        next errors << "[#{idx}] invalid policy #{policy_value}" unless ::Ai::InterventionPolicy::POLICIES.include?(policy_value)

        scope = attrs[:scope].presence || (attrs[:agent_id].present? ? "agent" : "global")

        policy = ::Ai::InterventionPolicy.find_or_initialize_by(
          account: current_account,
          action_category: action_category,
          scope: scope,
          ai_agent_id: attrs[:agent_id],
          user_id: nil
        )
        # An ABSENT key means "leave it alone", not "reset it".
        #
        # The Autonomy modal's save sends one entry per control the operator
        # touched, and a control edits the VERB only — `approval_chain_id`,
        # `priority`, `is_active` and `preferred_channels` are set elsewhere and
        # are simply not in that payload. Every line here except `conditions`
        # used to overwrite the stored value with a default when the key was
        # missing, so a verb toggle silently unassigned the row's approval chain
        # and reset an operator-tuned priority.
        #
        # That was inert only because the save itself never arrived: the panel
        # PATCHed a body this action does not parse, so the whole request 400'd
        # (IMP-bef43160636f). Making the save work makes these lines run, so
        # they have to stop clobbering first. The defaults below still apply to
        # a row being CREATED, where `policy.<attr>` is nil.
        #
        # `nil` remains meaningful when the key IS present: sending
        # `approval_chain_id: null` still unassigns the chain.
        #
        # Each branch tests `new_record?` rather than falling back through the
        # attribute's current value. These columns carry DB defaults — priority
        # 0, is_active true, preferred_channels [] — so an initialized-but-unsaved
        # row already answers with a non-nil value, and `attrs[:priority] ||
        # policy.priority` quietly created every new row at priority 0 instead of
        # the intended 10/5.
        policy.policy = policy_value
        policy.priority = attrs[:priority] || (policy.new_record? ? (scope == "agent" ? 10 : 5) : policy.priority)
        policy.is_active =
          if attrs[:is_active].nil?
            policy.new_record? ? true : policy.is_active
          else
            ActiveModel::Type::Boolean.new.cast(attrs[:is_active])
          end
        policy.preferred_channels =
          Array(attrs[:preferred_channels]).presence ||
          (policy.new_record? ? %w[notification] : policy.preferred_channels.presence || %w[notification])
        policy.conditions = attrs[:conditions].presence || policy.conditions || {}
        policy.approval_chain_id = attrs.key?(:approval_chain_id) ? attrs[:approval_chain_id] : policy.approval_chain_id

        if policy.save
          changed_count += 1
        else
          errors << "[#{idx}] #{policy.errors.full_messages.join(', ')}"
        end
      end

      if errors.any?
        render_error("Some updates failed", status: :unprocessable_content,
                     details: { errors: errors, changed: changed_count })
      else
        render_success(data: { changed: changed_count, message: "#{changed_count} policies updated" })
      end
    end

    private

    def system_agents
      # Override-aware: an account override wins over the global default per name.
      @system_agents ||= SYSTEM_AGENT_NAMES.filter_map { |n| a = ::Ai::Agent.resolve_for(current_account.id, name: n); [ n, a ] if a }.to_h
    end

    def serialize_agents
      system_agents.values.map do |agent|
        trust = ::Ai::AgentTrustScore.find_by(agent_id: agent.id)
        {
          id: agent.id, name: agent.name, status: agent.status,
          trust_tier: trust&.tier, overall_score: trust&.overall_score,
          autonomy_config: agent.autonomy_config
        }
      end
    end

    def serialize_chains
      # Ai::ApprovalChain lives in the business extension. In core mode the
      # admin UI surfaces the autonomy/policy machinery without the chain
      # configuration table — empty array is the right empty-state.
      return [] unless defined?(::Ai::ApprovalChain)
      ::Ai::ApprovalChain.where(account: current_account, status: "active").map do |c|
        { id: c.id, name: c.name, step_count: c.step_count, is_sequential: c.is_sequential }
      end
    end

    def all_policies
      ::Ai::InterventionPolicy.where(account: current_account).includes(:agent, :approval_chain)
    end

    # The by_agent bucket a row belongs to. Single authority: `by_agent_pivot`
    # groups by it, and `serialize_policy` ships it, so a client rendering from
    # ANY pivot can key a policy the same way the by_agent view did without
    # re-deriving the rule (scope + agent presence) in its own language. Note
    # `by_agent_pivot` then drops rows whose bucket is not a SYSTEM_AGENT_NAMES
    # entry — this value is still correct for those, which is what lets a
    # by_domain-driven client show them.
    def agent_bucket_for(policy)
      policy.scope == "agent" && policy.agent ? policy.agent.name : "Manual Operations"
    end

    def serialize_policy(p)
      {
        id: p.id,
        action_category: p.action_category,
        scope: p.scope,
        policy: p.policy,
        priority: p.priority,
        is_active: p.is_active,
        agent_id: p.ai_agent_id,
        agent_name: p.agent&.name,
        agent_bucket: agent_bucket_for(p),
        approval_chain_id: p.approval_chain_id,
        approval_chain_name: p.approval_chain&.name,
        conditions: p.conditions,
        preferred_channels: p.preferred_channels
      }
    end

    def by_action_pivot
      all_policies.each_with_object({}) do |p, hash|
        (hash[p.action_category] ||= []) << serialize_policy(p)
      end
    end

    def by_agent_pivot
      result = system_agents.each_value.with_object({}) { |a, h| h[a.name] = [] }
      result["Manual Operations"] = []

      all_policies.each do |p|
        bucket = agent_bucket_for(p)
        next unless result.key?(bucket)
        result[bucket] << serialize_policy(p)
      end
      result
    end

    def by_domain_pivot
      result = DOMAIN_PREFIXES.keys.index_with { [] }
      result["other"] = []

      all_policies.each do |p|
        domain = DOMAIN_PREFIXES.find { |_d, prefixes| prefixes.any? { |pre| p.action_category.start_with?(pre) } }&.first || "other"
        result[domain] << serialize_policy(p)
      end
      result
    end
  end
end
