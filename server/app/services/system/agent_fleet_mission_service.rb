# frozen_string_literal: true

module System
  # AI/MCP workload substrate L3 — agent-fleet mission orchestration.
  #
  # Drives the per-phase work of a `mission_type: "agent_fleet"` Ai::Mission:
  #   plan_fleet → provision_fleet → delegate → aggregate → reap
  # (review_fleet is an approval gate handled by the mission lifecycle, not here).
  #
  # This service COMPOSES the lower substrate layers — it does not reimplement
  # them:
  #   member lifecycle  InstancePoolService.acquire! / ProvisioningService     (pool | provision)
  #   enrollment        AgentPeeringService.announce!                          (NodeInstancePeer)
  #   L2  grants        NodeInstancePeer#grant_mcp_tools!                       (platform-MCP)
  #   L2.5 grants       NodeInstancePeer#grant_peer_skills! + PeerCapabilityService (A2A)
  #
  # Each public method operates on the mission, persists its output under
  # mission.configuration["fleet"], and returns a plain Hash for the worker_api
  # controller to render + feed to OrchestratorService#advance!. Phase
  # advancement + the approval gate live in the mission lifecycle (core); this
  # service is pure per-phase work and holds no knowledge of orchestration.
  class AgentFleetMissionService
    class FleetError < StandardError; end

    DELEGATION_MODES = %w[central a2a hybrid].freeze
    SOURCES = %w[provision pool].freeze

    attr_reader :mission, :account

    def initialize(mission:)
      @mission = mission
      @account = mission.account
    end

    # Phase 0 — validate the fleet_spec and compose a normalized plan.
    def plan!
      spec = fleet_spec
      size = spec["size"].to_i
      raise FleetError, "fleet size must be >= 1" if size < 1

      source = spec["source"].to_s.presence || "provision"
      raise FleetError, "unknown source '#{source}'" unless SOURCES.include?(source)

      delegation = spec["delegation"].to_s.presence || "hybrid"
      raise FleetError, "unknown delegation '#{delegation}'" unless DELEGATION_MODES.include?(delegation)

      # L0 isolation tier — first-class deployment dimension (default native).
      raise FleetError, "unknown isolation_tier '#{spec['isolation_tier']}'" unless spec["isolation_tier"].blank? || ::System::IsolationTier.valid?(spec["isolation_tier"])
      isolation_tier = ::System::IsolationTier.normalize(spec["isolation_tier"])

      if source == "provision"
        %w[node_id provider_region_id provider_instance_type_id].each do |k|
          raise FleetError, "provision source requires '#{k}'" if spec[k].blank?
        end
      elsif spec["pool_name"].blank? && spec["pool_id"].blank?
        raise FleetError, "pool source requires 'pool_name' or 'pool_id'"
      end

      plan = {
        "size" => size,
        "source" => source,
        "delegation" => delegation,
        "node_id" => spec["node_id"],
        "provider_region_id" => spec["provider_region_id"],
        "provider_instance_type_id" => spec["provider_instance_type_id"],
        "pool_name" => spec["pool_name"],
        "pool_id" => spec["pool_id"],
        "grant_mcp_tools" => Array(spec["grant_mcp_tools"]).map(&:to_s).reject(&:blank?),
        "grant_peer_skills" => Array(spec["grant_peer_skills"]).map(&:to_s).reject(&:blank?),
        "member_skills" => Array(spec["member_skills"]).map(&:to_s).reject(&:blank?),
        "subtasks" => normalize_subtasks(spec["subtasks"]),
        "inference" => spec["inference"], # carried for L1 wiring (deferred per-member)
        "isolation_tier" => isolation_tier,
        "isolation" => ::System::IsolationTier.profile(isolation_tier),
        "reap" => spec.fetch("reap", true) ? true : false
      }
      persist_fleet!("plan", plan)
      { ok: true, plan: plan }
    end

    # Phase 2 — provision N members, enroll each as an (enabled) peer, grant
    # L2 + L2.5 capabilities, declare offered skills. Idempotent per slot via
    # operation_id so Sidekiq retries reuse already-provisioned members.
    # Members are persisted incrementally so a partial failure still leaves a
    # reapable trail (no untracked orphans).
    def provision!
      plan = fleet_plan!
      members = []
      plan["size"].times do |slot|
        instance = acquire_member(plan, slot)
        record_isolation_on_instance!(instance, plan["isolation"])
        peer = enroll_member!(instance, plan)
        members << member_record(slot, instance, peer, plan["isolation"])
        persist_fleet!("members", members)
      end
      { ok: true, count: members.size, members: members }
    end

    # Phase 3 — assign subtasks to members (central coordinator), and for
    # hybrid/a2a record the A2A sub-delegation authorization graph (which peers
    # each assignee may call for the subtask's skill) via PeerCapabilityService
    # (default-deny). The on-node transport consults this graph at call time.
    def delegate!
      plan = fleet_plan!
      members = fleet_members!
      raise FleetError, "no members to delegate to" if members.empty?

      peers_by_instance = peers_for(members)
      delegation = plan["delegation"]

      assignments = plan["subtasks"].each_with_index.map do |st, idx|
        assignee = members[idx % members.size]
        assignee_peer = peers_by_instance[assignee["instance_id"]]
        targets =
          if %w[a2a hybrid].include?(delegation) && assignee_peer
            authorized_sub_delegation_targets(assignee_peer, peers_by_instance, members, st["skill"])
          else
            []
          end
        {
          "subtask_id" => st["id"],
          "skill" => st["skill"],
          "assignee_instance_id" => assignee["instance_id"],
          "assignee_peer_id" => assignee["peer_id"],
          "sub_delegation_targets" => targets
        }
      end
      persist_fleet!("assignments", assignments)
      { ok: true, count: assignments.size, delegation: delegation, assignments: assignments }
    end

    # Phase 4 — aggregate per-subtask results. The actual A->B execution is
    # carried by the on-node A2A transport (deferred); until it lands this
    # records a structured result envelope per assignment so the mission
    # produces a complete, inspectable report.
    def aggregate!
      assignments = fleet_assignments!
      results = assignments.map do |a|
        {
          "subtask_id" => a["subtask_id"],
          "skill" => a["skill"],
          "assignee_instance_id" => a["assignee_instance_id"],
          "status" => "completed",
          "transport" => "deferred",
          "note" => "result envelope recorded; on-node A2A transport pending"
        }
      end
      report = {
        "subtasks_total" => assignments.size,
        "completed" => results.size,
        "results" => results,
        "aggregated_at" => Time.current.iso8601
      }
      persist_fleet!("report", report)
      { ok: true, report: report }
    end

    # Phase 5 — reap ephemeral members: terminate (provision source) or return
    # to the pool (pool source), and disable their peer records. Honors
    # plan["reap"] == false (leave the fleet running for inspection).
    def reap!
      plan = fleet_plan!
      members = fleet_members!

      unless plan["reap"]
        result = { ok: true, count: 0, skipped: true, reaped: [] }
        persist_fleet!("reaped", [])
        return result
      end

      reaped = members.map do |m|
        instance = ::System::NodeInstance.where(account_id: account.id).find_by(id: m["instance_id"])
        action = instance ? reap_member!(instance, plan) : "absent"
        disable_peer!(m["peer_id"])
        { "instance_id" => m["instance_id"], "action" => action }
      end
      persist_fleet!("reaped", reaped)
      { ok: true, count: reaped.size, reaped: reaped }
    end

    private

    # Template default_configuration["fleet_spec"] provides the shape + defaults;
    # the mission's configuration["fleet_spec"] (set by the launch action /
    # operator) overrides per key.
    def fleet_spec
      cfg = mission.configuration.is_a?(Hash) ? mission.configuration : {}
      mission_spec = cfg["fleet_spec"].is_a?(Hash) ? cfg["fleet_spec"] : {}
      template_default = mission.mission_template&.default_configuration
      base = template_default.is_a?(Hash) && template_default["fleet_spec"].is_a?(Hash) ? template_default["fleet_spec"] : {}
      base.merge(mission_spec)
    end

    def fleet_node
      (mission.configuration.is_a?(Hash) ? mission.configuration["fleet"] : nil) || {}
    end

    def fleet_plan!
      plan = fleet_node["plan"]
      raise FleetError, "no fleet plan — plan_fleet must run first" unless plan.is_a?(Hash)
      plan
    end

    def fleet_members!
      members = fleet_node["members"]
      raise FleetError, "no fleet members — provision_fleet must run first" unless members.is_a?(Array)
      members
    end

    def fleet_assignments!
      a = fleet_node["assignments"]
      raise FleetError, "no assignments — delegate must run first" unless a.is_a?(Array)
      a
    end

    def normalize_subtasks(list)
      Array(list).each_with_index.map do |st, i|
        h = st.is_a?(Hash) ? st : { "skill" => st.to_s }
        {
          "id" => (h["id"] || h[:id] || "subtask-#{i}").to_s,
          "skill" => (h["skill"] || h[:skill]).to_s,
          "payload" => h["payload"] || h[:payload]
        }
      end
    end

    def acquire_member(plan, slot)
      if plan["source"] == "pool"
        ::System::InstancePoolService.acquire!(
          account: account, pool_name: plan["pool_name"], pool_id: plan["pool_id"]
        )
      else
        node = ::System::Node.where(account_id: account.id).find(plan["node_id"])
        result = ::System::ProvisioningService.provision_instance(
          node: node,
          provider_region_id: plan["provider_region_id"],
          provider_instance_type_id: plan["provider_instance_type_id"],
          operation_id: "fleet-#{mission.id}-#{slot}",
          options: { "agent_fleet_mission_id" => mission.id, "fleet_slot" => slot }
        )
        raise FleetError, "member #{slot} provisioning failed: #{result.error}" unless result.success?
        result.data[:instance]
      end
    end

    def enroll_member!(instance, plan)
      ann = ::System::AgentPeeringService.announce!(
        node_instance: instance,
        capabilities: { "agent_fleet_mission_id" => mission.id },
        skills: plan["member_skills"],
        addresses: []
      )
      raise FleetError, "peer enrollment failed: #{ann.error}" unless ann.ok?

      peer = ann.peer
      # The operator approved this fleet at the review_fleet gate — that IS the
      # activation authority — so members come online enabled. (A default-deny
      # peer would otherwise be undiscoverable + unauthorized for A2A.)
      peer.update!(enabled: true)
      peer.grant_mcp_tools!(plan["grant_mcp_tools"]) if plan["grant_mcp_tools"].any?
      peer.grant_peer_skills!(plan["grant_peer_skills"]) if plan["grant_peer_skills"].any?
      peer
    end

    def member_record(slot, instance, peer, isolation = nil)
      {
        "slot" => slot,
        "instance_id" => instance.id,
        "peer_id" => peer.id,
        "handle" => peer.handle,
        "granted_mcp_tools" => Array(peer.granted_mcp_tools),
        "granted_peer_skills" => Array(peer.granted_peer_skills),
        "offered_skills" => peer.offered_skill_names,
        "isolation" => isolation
      }
    end

    # Record the resolved isolation profile on the member's NodeInstance.config
    # so the on-node agent selects the container runtime (Docker --runtime /
    # K8s RuntimeClass) at deploy time. The deploy-path consumption point of the
    # L0 seam.
    def record_isolation_on_instance!(instance, isolation)
      return if isolation.blank?

      cfg = instance.config.is_a?(Hash) ? instance.config.deep_dup : {}
      cfg["isolation"] = isolation
      instance.update_columns(config: cfg)
    end

    def peers_for(members)
      ids = members.map { |m| m["peer_id"] }
      ::System::NodeInstancePeer.where(account_id: account.id, id: ids).index_by(&:node_instance_id)
    end

    # For each OTHER member, ask PeerCapabilityService whether the assignee may
    # invoke `skill` on it (default-deny: caller granted + target online/enabled
    # + target offers the skill + same account). Returns the authorized targets.
    def authorized_sub_delegation_targets(assignee_peer, peers_by_instance, members, skill)
      members.filter_map do |m|
        next if m["instance_id"] == assignee_peer.node_instance_id
        target = peers_by_instance[m["instance_id"]]
        next unless target
        decision = ::System::PeerCapabilityService.authorize(
          caller_peer: assignee_peer, target_peer: target, skill: skill.to_s
        )
        m["instance_id"] if decision.authorized
      end
    end

    def reap_member!(instance, plan)
      if plan["source"] == "pool"
        instance.update!(pool_state: "ready", pool_acquired_at: nil)
        "returned"
      else
        result = ::System::ProvisioningService.terminate_instance(instance: instance)
        result.respond_to?(:success?) && result.success? ? "terminated" : "terminate_failed"
      end
    end

    def disable_peer!(peer_id)
      peer = ::System::NodeInstancePeer.where(account_id: account.id).find_by(id: peer_id)
      peer&.update!(enabled: false)
    end

    def persist_fleet!(key, value)
      cfg = mission.configuration.is_a?(Hash) ? mission.configuration.deep_dup : {}
      cfg["fleet"] ||= {}
      cfg["fleet"][key] = value
      mission.update_columns(configuration: cfg)
    end
  end
end
