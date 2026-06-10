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
    # TTL for the capability tokens minted at delegate! time — long enough for
    # the fleet to execute its sub-delegations, short enough to bound exposure.
    DELEGATION_TOKEN_TTL = 3600

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
      # Seed from the persisted list so a retry resumes instead of
      # rebuilding — rebuilding from [] overwrote earlier slots and
      # orphaned their already-claimed instances (F1-06).
      members = persisted_members
      plan["size"].times do |slot|
        existing = members.find { |m| m["slot"] == slot }
        next if existing && existing["peer_id"].present?

        instance = acquire_member(plan, slot)
        record_isolation_on_instance!(instance, plan["isolation"])
        # Persist the claim BEFORE enrollment — an instance whose
        # enrollment fails must still be on the mission record so
        # reap! can find it.
        members = upsert_member(members, partial_member_record(slot, instance, plan["isolation"]))
        persist_fleet!("members", members)

        peer = enroll_member!(instance, plan)
        members = upsert_member(members, member_record(slot, instance, peer, plan["isolation"]))
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
      dispatched = dispatch_a2a_tasks!(assignments, plan)
      { ok: true, count: assignments.size, delegation: delegation,
        assignments: assignments, dispatched_tasks: dispatched }
    end

    # Turn the minted sub-delegations into on-node work: one a2a_call System::Task
    # per (assignee -> target) edge, addressed to the assignee's NodeInstance so
    # its agent task loop executes the A2A call (presenting the capability token)
    # and reports via execute_result — the on-node half of the delegation. Only
    # token-bearing edges are dispatchable. Returns the task count.
    def dispatch_a2a_tasks!(assignments, plan)
      payload_by_subtask = Array(plan["subtasks"]).to_h { |st| [st["id"], st["payload"]] }
      task_ids = []
      assignments.each do |a|
        assignee = ::System::NodeInstance.where(account_id: account.id).find_by(id: a["assignee_instance_id"])
        next unless assignee
        Array(a["sub_delegation_targets"]).each do |t|
          next unless t.is_a?(::Hash) && t["capability_token"].present?
          task = ::System::Task.create!(
            account: account, operable: assignee, command: "a2a_call", status: "pending",
            options: {
              "target_instance_id" => t["target_instance_id"],
              "target_addresses" => t["target_addresses"],
              "skill" => t["skill"],
              "args" => payload_by_subtask[a["subtask_id"]] || {},
              "capability_token" => t["capability_token"].slice("envelope", "signature"),
              "fleet_mission_id" => mission.id,
              "subtask_id" => a["subtask_id"]
            }
          )
          task_ids << task.id
        end
      end
      persist_fleet!("dispatched_task_ids", task_ids)
      task_ids.size
    end

    # Phase 4 — aggregate per-subtask delegation state. delegate! mints the
    # capability tokens; the assignee's on-node A2A client executes the
    # sub-delegations over the mesh and reports back via node_api/peer/execute_result
    # (peer.record_execution!). This reads that real state: how many
    # sub-delegations carry an actionable token (dispatched) and what the
    # assignee peer has actually executed.
    def aggregate!
      assignments = fleet_assignments!
      peers_by_id = ::System::NodeInstancePeer.where(account_id: account.id)
                                              .where(id: assignments.filter_map { |a| a["assignee_peer_id"] })
                                              .index_by(&:id)
      tasks_by_subtask = dispatched_tasks_by_subtask
      results = assignments.map do |a|
        targets = Array(a["sub_delegation_targets"])
        tokenized = targets.count { |t| t.is_a?(::Hash) && t["capability_token"].present? }
        peer = peers_by_id[a["assignee_peer_id"]]
        executions = peer&.execution_count.to_i
        tasks = Array(tasks_by_subtask[a["subtask_id"]])
        by_status = tasks.group_by(&:status).transform_values(&:size)
        {
          "subtask_id" => a["subtask_id"],
          "skill" => a["skill"],
          "assignee_instance_id" => a["assignee_instance_id"],
          "sub_delegations" => targets.size,
          "sub_delegations_tokenized" => tokenized,
          "dispatched_tasks" => tasks.size,
          "tasks_complete" => by_status["complete"].to_i,
          "tasks_failed" => %w[failed aborted cancelled].sum { |s| by_status[s].to_i },
          "assignee_executions" => executions,
          "assignee_last_executed_at" => peer&.last_executed_at&.iso8601,
          "status" => subtask_status(tasks, executions)
        }
      end
      report = {
        "subtasks_total" => assignments.size,
        "delegation_tokens_minted" => results.sum { |r| r["sub_delegations_tokenized"] },
        "tasks_dispatched" => results.sum { |r| r["dispatched_tasks"] },
        "tasks_complete" => results.sum { |r| r["tasks_complete"] },
        "results" => results,
        "aggregated_at" => Time.current.iso8601
      }
      persist_fleet!("report", report)
      { ok: true, report: report }
    end

    # The a2a_call tasks delegate! dispatched, grouped by the subtask they serve.
    # Read each aggregate! so a re-run reflects current on-node progress.
    def dispatched_tasks_by_subtask
      ids = Array(mission.configuration.is_a?(Hash) ? mission.configuration.dig("fleet", "dispatched_task_ids") : nil)
      return {} if ids.empty?

      ::System::Task.where(account_id: account.id, id: ids)
                    .to_a.group_by { |t| t.options.is_a?(Hash) ? t.options["subtask_id"] : nil }
    end

    # Honest subtask status from the dispatched tasks' real states (falls back to
    # the peer execution signal when no tasks were dispatched, e.g. central mode).
    def subtask_status(tasks, peer_executions)
      return peer_executions.positive? ? "executed" : "dispatched" if tasks.empty?

      statuses = tasks.map(&:status)
      return "executed"  if statuses.all?("complete")
      return "executing" if statuses.include?("running") || statuses.include?("complete")
      return "failed"    if statuses.any? { |s| %w[failed aborted cancelled].include?(s) }

      "dispatched"
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
        # Idempotency parity with the provision branch: stamp the claim so a
        # retry reuses the member instead of draining a fresh one from the
        # pool while the first leaks in pool_state "claimed" (F1-06).
        claim_key = "fleet-#{mission.id}-#{slot}"
        existing = ::System::NodeInstance
                     .where(account_id: account.id)
                     .where("config->>'fleet_operation_id' = ?", claim_key)
                     .where.not(status: %w[terminated error])
                     .first
        return existing if existing

        instance = ::System::InstancePoolService.acquire!(
          account: account, pool_name: plan["pool_name"], pool_id: plan["pool_id"]
        )
        instance.update!(config: (instance.config || {}).merge("fleet_operation_id" => claim_key))
        instance
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

    # Claim-only record persisted before enrollment so the instance is
    # reapable even when enroll_member! raises (F1-06).
    def partial_member_record(slot, instance, isolation = nil)
      {
        "slot" => slot,
        "instance_id" => instance.id,
        "peer_id" => nil,
        "isolation" => isolation
      }
    end

    def persisted_members
      list = fleet_node["members"]
      list.is_a?(Array) ? list.map { |m| m.deep_dup } : []
    end

    def upsert_member(members, record)
      idx = members.index { |m| m["slot"] == record["slot"] }
      return members + [record] unless idx

      members[0...idx] + [record] + members[(idx + 1)..]
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
    # + target offers the skill + same account). For each authorized edge, MINT
    # the Ed25519 capability token the assignee's on-node A2A client presents to
    # the target — turning the authorization graph into an actionable delegation
    # the agent can execute over the mesh without a round-trip to the platform.
    def authorized_sub_delegation_targets(assignee_peer, peers_by_instance, members, skill)
      members.filter_map do |m|
        next if m["instance_id"] == assignee_peer.node_instance_id
        target = peers_by_instance[m["instance_id"]]
        next unless target
        decision = ::System::PeerCapabilityService.authorize(
          caller_peer: assignee_peer, target_peer: target, skill: skill.to_s
        )
        next unless decision.authorized
        mint_delegation_token(assignee_peer, target, skill)
      end
    end

    # Mint the capability token authorizing assignee -> target for `skill` and
    # package it with the target's reachable addresses into a self-contained
    # delegation descriptor. Authorize already passed for this edge, so a mint
    # failure here is exceptional (e.g. a missing signing key) — record the
    # target without a token so the mission report surfaces the gap rather than
    # silently dropping the delegation.
    def mint_delegation_token(assignee_peer, target_peer, skill)
      token = ::System::PeerCapabilityTokenSigner.mint!(
        caller_instance: ::System::NodeInstance.find(assignee_peer.node_instance_id),
        target_instance: ::System::NodeInstance.find(target_peer.node_instance_id),
        skill: skill.to_s, ttl_seconds: DELEGATION_TOKEN_TTL
      )
      {
        "target_instance_id" => target_peer.node_instance_id,
        "target_peer_id" => target_peer.id,
        "target_addresses" => target_peer.addresses_array,
        "skill" => skill.to_s,
        "capability_token" => {
          "envelope" => token.envelope_json,
          "signature" => token.signature_b64,
          "handle" => token.handle,
          "expires_at" => Time.at(token.claims["exp"]).utc.iso8601,
          "jti" => token.claims["jti"]
        }
      }
    rescue ::System::PeerCapabilityTokenSigner::SigningError,
           ::System::PeerCapabilityTokenSigner::NotAuthorizedError => e
      Rails.logger.warn("[AgentFleetMission #{mission.id}] delegation token mint failed " \
                        "(#{assignee_peer.node_instance_id} -> #{target_peer.node_instance_id}/#{skill}): #{e.message}")
      {
        "target_instance_id" => target_peer.node_instance_id,
        "target_peer_id" => target_peer.id,
        "skill" => skill.to_s,
        "capability_token" => nil,
        "error" => e.message
      }
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
