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
    # F1-12: when aggregate! re-runs (the F1-03 wait/monitor loop polls past
    # the original delegation), any sub-delegation token within this window of
    # expiry is re-minted. We re-mint rather than extend: PeerCapabilityTokenSigner
    # hard-caps TTL at MAX_TTL_SECONDS (3600, the F2-04 clamp), so a long mission
    # gets a fresh ≤3600s token each cycle instead of one unbounded token.
    TOKEN_REFRESH_WINDOW_SECONDS = 300
    # Execution wait between delegate and reap: aggregate! keeps reporting
    # waiting (and the worker_api controller re-enqueues a delayed re-check)
    # until every dispatched task is terminal or the timeout elapses. Both
    # knobs are overridable per fleet_spec. The poll floor must exceed the
    # on-node agent's 20s task-lease interval or the fleet gets reaped before
    # a member could ever lease its work.
    DEFAULT_EXECUTION_TIMEOUT_SECONDS = 600
    DEFAULT_AGGREGATE_POLL_SECONDS = 30

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
        "reap" => spec.fetch("reap", true) ? true : false,
        "execution_timeout_seconds" => positive_int(spec["execution_timeout_seconds"], DEFAULT_EXECUTION_TIMEOUT_SECONDS),
        "aggregate_poll_seconds" => positive_int(spec["aggregate_poll_seconds"], DEFAULT_AGGREGATE_POLL_SECONDS)
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
      # F1-12: re-mint near-expiry delegation tokens before reading state, so a
      # mission whose execution outlives the 3600s token TTL keeps presenting
      # valid tokens on subsequent wait/monitor re-checks.
      refresh_expiring_delegation_tokens!

      assignments = fleet_assignments!
      peers_by_id = ::System::NodeInstancePeer.where(account_id: account.id)
                                              .where(id: assignments.filter_map { |a| a["assignee_peer_id"] })
                                              .index_by(&:id)
      # F1-12: assignee liveness — a member whose instance died mid-mission
      # (error/terminated) loses any non-terminal subtask to "member_lost".
      instances_by_id = ::System::NodeInstance
                          .where(account_id: account.id)
                          .where(id: assignments.filter_map { |a| a["assignee_instance_id"] })
                          .index_by(&:id)
      tasks_by_subtask = dispatched_tasks_by_subtask
      results = assignments.map do |a|
        targets = Array(a["sub_delegation_targets"])
        tokenized = targets.count { |t| t.is_a?(::Hash) && t["capability_token"].present? }
        peer = peers_by_id[a["assignee_peer_id"]]
        executions = peer&.execution_count.to_i
        tasks = Array(tasks_by_subtask[a["subtask_id"]])
        by_status = tasks.group_by(&:status).transform_values(&:size)
        status = subtask_status(tasks, executions, tokenized)
        # A dead member only loses work that hasn't already executed — tasks
        # that completed before the member died still count as delivered.
        if status != "executed" && member_lost?(instances_by_id[a["assignee_instance_id"]])
          status = "member_lost"
        end
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
          "status" => status
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

      started_at = aggregate_started_at!
      timeout_seconds = positive_int(fleet_plan!["execution_timeout_seconds"], DEFAULT_EXECUTION_TIMEOUT_SECONDS)
      timed_out = Time.current - started_at >= timeout_seconds

      if execution_settled?(results) || timed_out
        report["execution_outcome"] = execution_outcome(results, report, timed_out)
        persist_fleet!("report", report)
        # F1-09: ok only when every subtask actually executed — a mission
        # that delivered nothing (or only part) must not aggregate as ok.
        { ok: report["execution_outcome"] == "complete",
          report: report, waiting: false, execution_outcome: report["execution_outcome"] }
      else
        persist_fleet!("report", report)
        { ok: true, report: report, waiting: true,
          waited_seconds: (Time.current - started_at).round, timeout_seconds: timeout_seconds }
      end
    end

    # Reserve the next aggregate re-check slot. Returns the delay in seconds
    # when the caller should enqueue a delayed re-check, or nil when one is
    # already pending — a stale Sidekiq retry hitting aggregate again must not
    # multiply the re-check chain.
    def reserve_aggregate_recheck!
      pending = fleet_node["aggregate_next_check_at"]
      if pending.present?
        remaining = Time.zone.parse(pending) - Time.current
        return nil if remaining.positive?
      end

      poll = positive_int(fleet_plan!["aggregate_poll_seconds"], DEFAULT_AGGREGATE_POLL_SECONDS)
      persist_fleet!("aggregate_next_check_at", (Time.current + poll).iso8601)
      poll
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
    # Terminal-first ordering (F1-09): a mixed complete+failed set is FAILED, not
    # forever-"executing"; zero tasks with zero minted tokens is "not_dispatched"
    # (nothing will ever execute), not "dispatched".
    def subtask_status(tasks, peer_executions, tokenized = 0)
      if tasks.empty?
        return "executed" if peer_executions.positive?
        return tokenized.positive? ? "dispatched" : "not_dispatched"
      end

      statuses = tasks.map(&:status)
      return "executed"  if statuses.all?("complete")
      return "executing" if statuses.include?("running")
      return "failed"    if statuses.any? { |s| %w[failed aborted cancelled].include?(s) }
      return "executing" if statuses.include?("complete") # some done, rest pending

      "dispatched"
    end

    # Phase 5 — reap ephemeral members: terminate (provision source) or return
    # to the pool (pool source), and disable their peer records. Honors
    # plan["reap"] == false (leave the fleet running for inspection).
    # force: reap even when the plan disabled it — the lifecycle lever for
    # failed/stuck fleets (system_reap_agent_fleet MCP action).
    def reap!(force: false)
      plan = fleet_plan!
      members = fleet_members!

      unless plan["reap"] || force
        result = { ok: true, count: 0, skipped: true, reaped: [] }
        persist_fleet!("reaped", [])
        return result
      end

      # Idempotency memo (F1-11): reap re-runs are the norm (Sidekiq retries,
      # cancel-cleanup). A member with a recorded terminal action keeps it —
      # re-running must never touch a pool slot a later consumer re-claimed.
      # terminate_failed is NOT terminal: a re-run retries the termination.
      prior = Array(fleet_node["reaped"]).index_by { |r| r["instance_id"] }

      reaped = members.map do |m|
        done = prior[m["instance_id"]]
        next done if done && done["action"] != "terminate_failed"

        instance = ::System::NodeInstance.where(account_id: account.id).find_by(id: m["instance_id"])
        action = instance ? reap_member!(instance, plan) : "absent"
        disable_peer!(m["peer_id"])
        { "instance_id" => m["instance_id"], "action" => action }
      end
      persist_fleet!("reaped", reaped)

      # A terminate_failed member is a leaked, still-running instance — the
      # phase stays best-effort (no stuck missions) but the failure must be
      # visible, not counted as a clean reap (F1-08).
      failed = reaped.count { |r| r["action"] == "terminate_failed" }
      if failed.positive?
        mission.update_columns(error_message: "reap incomplete: #{failed} member(s) failed to terminate")
        { ok: false, count: reaped.size, reaped: reaped, reap_incomplete: true, failed_count: failed }
      else
        { ok: true, count: reaped.size, reaped: reaped }
      end
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

    def positive_int(value, default)
      v = value.to_i
      v.positive? ? v : default
    end

    # First aggregate! run stamps the execution-wait window start; re-checks
    # reuse it so the timeout measures total wait, not per-check wait.
    def aggregate_started_at!
      existing = fleet_node["aggregate_started_at"]
      return Time.zone.parse(existing) if existing.present?

      Time.current.tap { |now| persist_fleet!("aggregate_started_at", now.iso8601) }
    end

    # Settled when every subtask is terminal (executed, failed, never
    # dispatched, or lost with its member) — nothing left for the on-node
    # agents to deliver. F1-12: member_lost is terminal — a dead member will
    # not resume, so the mission must settle instead of polling to timeout.
    def execution_settled?(results)
      results.all? { |r| %w[executed failed not_dispatched member_lost].include?(r["status"]) }
    end

    # F1-12: a member is lost when its NodeInstance is gone or in a terminal
    # bad state. Keyed on status (not heartbeat staleness): the on-node agent
    # is the only heartbeat source, and a simulated/just-launched fleet has no
    # heartbeat yet — so status is the reliable liveness signal. The
    # DecisionEngine's presumed-dead fail-safe is what transitions a genuinely
    # silent instance to error; this reads that verdict.
    def member_lost?(instance)
      return true if instance.nil?

      %w[error terminated].include?(instance.status)
    end

    def execution_outcome(results, report, timed_out)
      statuses = results.map { |r| r["status"] }
      return "complete" if statuses.all?("executed")
      return "partial"  if report["tasks_complete"].to_i.positive? || statuses.include?("executed")

      timed_out ? "timeout" : "failed"
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

    # F1-12: re-mint any persisted sub-delegation token sitting within
    # TOKEN_REFRESH_WINDOW_SECONDS of expiry. mint_delegation_token already
    # caps each token at the signer's MAX_TTL, so a long-running mission gets a
    # rolling sequence of fresh ≤3600s tokens rather than one extended past the
    # F2-04 security ceiling. Only token-bearing edges with a resolvable
    # assignee+target peer are refreshed; everything else is left verbatim.
    # Persists (and returns true) only when something actually changed.
    def refresh_expiring_delegation_tokens!
      assignments = fleet_node["assignments"]
      return false unless assignments.is_a?(::Array) && assignments.any?

      peer_ids = assignments.flat_map do |a|
        [ a["assignee_peer_id"] ] + Array(a["sub_delegation_targets"]).map { |t| t.is_a?(::Hash) ? t["target_peer_id"] : nil }
      end.compact.uniq
      peers_by_id = ::System::NodeInstancePeer.where(account_id: account.id, id: peer_ids).index_by(&:id)

      changed = false
      refreshed = assignments.map do |a|
        assignee_peer = peers_by_id[a["assignee_peer_id"]]
        targets = Array(a["sub_delegation_targets"]).map do |t|
          next t unless assignee_peer && t.is_a?(::Hash)
          token = t["capability_token"]
          next t unless token.is_a?(::Hash) && token_near_expiry?(token["expires_at"])
          target_peer = peers_by_id[t["target_peer_id"]]
          next t unless target_peer

          minted = mint_delegation_token(assignee_peer, target_peer, t["skill"])
          # Keep the old descriptor if the re-mint failed (no token) so we don't
          # drop a still-usable edge — the next cycle retries.
          next t if minted["capability_token"].nil?

          changed = true
          minted
        end
        a.merge("sub_delegation_targets" => targets)
      end

      persist_fleet!("assignments", refreshed) if changed
      changed
    end

    def token_near_expiry?(expires_at)
      return true if expires_at.blank? # missing expiry — treat as needing a fresh token

      Time.zone.parse(expires_at.to_s) <= Time.current + TOKEN_REFRESH_WINDOW_SECONDS
    rescue ArgumentError, TypeError
      true
    end

    def reap_member!(instance, plan)
      if plan["source"] == "pool"
        # Guarded return (F1-11): only a live claim is returnable — mirrors
        # the canonical system_return_pooled_instance guard. Anything else
        # (already returned, never pool-tracked) is reported, not re-flipped.
        unless instance.pool_state == "claimed" && instance.pool_acquired_at.present?
          return "already_returned"
        end

        # F2-05: restart the ready-TTL anchor (recycle_stale_members! keys
        # stale_ready off pool_warming_started_at) so the returned member is
        # reused instead of stale-recycled on the next reaper tick.
        instance.update!(pool_state: "ready", pool_acquired_at: nil,
                         pool_warming_started_at: Time.current)
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
