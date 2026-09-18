# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # IMP-10c9b9634d4e — instances nobody has heard from past the abandonment
      # window: machines that no longer exist, still carried as live rows.
      #
      # WHY A SENSOR OF ITS OWN
      #
      # On 2026-09-08 an ops-cell instance created 2026-07-29 sat in `starting`
      # with its last heartbeat on 2026-08-10, and six more ops-cell rows sat in
      # error/stopped since 2026-08-09. The fleet treated them as live:
      # InstanceStatusSensor raised system.instance_silent (critical) with a
      # reprovision plan that would update three modules, and
      # TemplateClosureDriftSensor held a standing closure-apply card, re-detected
      # 1416 times, whose blast radius counted the dead rows as provisioned nodes.
      # Operators were asked to approve work on machines that were gone. Nothing
      # classified "silent for weeks" as different from "silent for minutes".
      #
      # THIS CLASS IS THE ONE AUTHORITY on "abandoned". The reap lane re-checks a
      # row with .abandoned? at execution. The relation and the predicate are two
      # spellings of that rule and a spec pins them to agree arm by arm.
      #
      # WHAT COUNTS
      #
      #   * not a pool member — a pool's own reaper owns its dead members;
      #   * a `cloud` instance — a physical machine is not a provider guest to
      #     reap, and a dynamic one has its own lifecycle;
      #   * in a status where the platform acts as if the machine exists but no
      #     provision or teardown is in flight: starting, running, stopped, error.
      #     pending/provisioning have owners of their own (provisioning and
      #     fulfillment sweeps), stopping/rebooting are transitions, and a
      #     terminated row has nothing left to reap;
      #   * no operator hold — a hold is an explicit "leave this alone";
      #   * last sign of life older than the window. The last sign of life is
      #     COALESCE(last_heartbeat_at, created_at): a row that never enrolled has
      #     no heartbeat to age, and its creation is the only honest clock. It is
      #     never updated_at, which any observer (a provider sync) bumps;
      #   * something terminate can act on: a provider id, or a lost provider
      #     guest (which terminate finalizes). A row with neither can only be
      #     refused, and would sit on this lane forever;
      #   * not the platform's own hosting node, which the self-management fence
      #     refuses for the same reason;
      #   * not the failed side of a DR replace that already holds a replacement:
      #     that replace is waiting on its own system.instance_reap decision.
      #
      # DATA AT STAKE
      #
      # A provider terminate destroys every disk in the guest's config, and agent
      # silence is not the provider's view of the guest. The signal therefore
      # carries requires_approval with its approval_reasons, and the
      # DecisionEngine forces the gate to require_approval in ANY plane, when the
      # guest:
      #   * is `running` — the platform last saw it powered on, and it may be a
      #     live VM whose agent broke;
      #   * is `stopped` — no heartbeat is expected from a powered-off guest, and
      #     an operator may have powered it off on purpose;
      #   * has a ProviderVolume attached — the applier detaches it first, but
      #     that is a person's call to make;
      #   * is the ACTIVE holder of a virtual IP through one of its peers
      #     (`virtual_ip_active_holder`). A terminate destroys the peer but not
      #     its id in the VIP's holder list, and this lane does not move
      #     addresses: the card says so, and the applier refuses even when
      #     approved — approval cannot fix a moved address — until the address
      #     has been moved off the guest.
      # A guest that is only a FAILOVER STANDBY for a virtual IP (never the
      # active holder) is not an approval reason: VirtualIp#failover! would
      # otherwise promote a dead peer into the holder seat, so the applier
      # prunes the guest's peer ids from every failover_holder_peer_ids list
      # itself, through the ordinary VIP update path, before terminating — the
      # same way it detaches an attached volume, with no operator gate of its
      # own.
      # So only `starting`/`error` guests holding nothing (or only standing by
      # for a VIP) reap on the tick, and only in a plane that does not escalate
      # the category.
      #
      # WHAT IS BOUNDED, AND WHAT THE OTHER SENSORS STOP REPORTING
      #
      # Two bounds, oldest first. max_per_tick bounds the reaps that would
      # PROCEED on the tick, because each is a provider terminate.
      # max_parked_per_tick bounds the reaps that will park (a reason above, or a
      # plane that escalates the category): those terminate nothing, so they must
      # not use up the terminate bound, but each still re-emits every tick.
      #
      # instance_status, template_closure_drift and instance_unrecoverable
      # exclude .claimed_relation — the rows this sensor signals on a tick — not
      # every abandoned row. A row past either bound keeps its old cards until it
      # reaches the reap lane, so no row is on neither lane.
      #
      # The sensor only DETECTS: the signal routes to
      # system.abandoned_instance_reap, whose policy row proceeds and whose plane
      # placement (the instance's own environment) parks it in a protected plane.
      class AbandonedInstanceSensor < BaseSensor
        # Never speak for an instance another control plane owns: this signal can
        # become a terminate on the same tick.
        include ::System::Autonomy::ControlPlaneFence

        SIGNAL_KIND = "system.instance_abandoned"
        ACTION_CATEGORY = "system.abandoned_instance_reap"

        # Fallback; overridable per account as "abandon_after_seconds". A week
        # is far past every liveness window the fleet uses (silence at 3 minutes,
        # presumed dead at 30, the task janitor's unrunnable sweep at 48 hours),
        # and matches the pool reaper's dead-record retention
        # (InstancePoolService::DEAD_RECORD_RETENTION_DAYS), so a machine this
        # quiet is not recovering on its own.
        ABANDON_AFTER_SECONDS = 7 * 86_400

        # Fallbacks; overridable per account. See WHAT IS BOUNDED.
        MAX_PER_TICK = 10
        MAX_PARKED_PER_TICK = 50

        ABANDONABLE_STATUSES = %w[starting running stopped error].freeze
        ABANDONABLE_VARIETIES = %w[cloud].freeze

        # IMP-675374d30971 — a `dynamic` row that already lost its provider
        # identity (NodeInstance#mark_provider_guest_lost!, written by
        # CloudSyncService on a recycled/renamed provider id — IMP-8225624f46b1)
        # was invisible to every sensor: InstanceStateDriftSensor skips it (no
        # cloud_instance_id to poll) and this sensor excluded the whole variety
        # regardless of age. Eligible ONLY once guest-lost, deliberately NOT a
        # blanket widen of ABANDONABLE_VARIETIES: a LIVE dynamic guest (a
        # cloud_instance_id still present) would satisfy TERMINATABLE_SQL too,
        # and this sensor's applier (DecisionEngine#reap_abandoned_instance →
        # ProvisioningService#terminate_instance) really does call the provider
        # and destroy the guest for that shape — auto_approve in an unprotected
        # plane, no human in the loop. Widening unconditionally would hand this
        # sensor's existing destructive reap a NEW class of live target nobody
        # asked for. The guest-lost sub-case carries no such risk: that same
        # applier never reaches the provider for a provider_guest_lost row (see
        # ProvisioningService#terminate_instance's `guest_lost` short-circuit) —
        # it only finalizes a row that has already lost its provider identity,
        # exact parity with what `cloud` already gets today.
        GUEST_LOST_ONLY_VARIETIES = %w[dynamic].freeze

        # Statuses whose reap waits for a person, as approval reasons.
        APPROVAL_STATUSES = %w[running stopped].freeze

        LAST_SIGN_OF_LIFE_SQL =
          "COALESCE(system_node_instances.last_heartbeat_at, system_node_instances.created_at)"

        # Oldest first; the id breaks ties, so the three sensors that re-run this
        # query on the tick draw the same slice.
        ORDER_SQL = "#{LAST_SIGN_OF_LIFE_SQL} ASC, system_node_instances.id ASC"

        GUEST_LOST_SQL = "NULLIF(system_node_instances.config->>'provider_guest_lost_at', '') IS NOT NULL"

        TERMINATABLE_SQL =
          "(NULLIF(system_node_instances.config->>'cloud_instance_id', '') IS NOT NULL " \
          "OR #{GUEST_LOST_SQL})"

        # See GUEST_LOST_ONLY_VARIETIES above: unconditional for ABANDONABLE_VARIETIES
        # (`cloud`), conditional on guest-lost for GUEST_LOST_ONLY_VARIETIES (`dynamic`).
        VARIETY_SQL =
          "(system_node_instances.variety IN ('#{ABANDONABLE_VARIETIES.join("','")}') " \
          "OR (system_node_instances.variety IN ('#{GUEST_LOST_ONLY_VARIETIES.join("','")}') " \
          "AND #{GUEST_LOST_SQL}))"

        REPLACE_ACQUIRED_KIND =
          "#{::System::Ai::Skills::InstanceReplacementLedger::EVENT_PREFIX}.acquire_replacement"

        def self.default_thresholds
          { "abandon_after_seconds" => ABANDON_AFTER_SECONDS, "max_per_tick" => MAX_PER_TICK,
            "max_parked_per_tick" => MAX_PARKED_PER_TICK }
        end

        def self.window_seconds(account)
          resolved_threshold("abandon_after_seconds", account: account)
        end

        # The account's abandoned instances, unfenced and unbounded.
        def self.abandoned_relation(account:, now: Time.current, window_seconds: nil)
          window = window_seconds || self.window_seconds(account)
          events = ::System::FleetEvent.table_name

          relation = ::System::NodeInstance
            .joins(:node)
            .where(system_nodes: { account_id: account.id })
            .where(instance_pool_id: nil, ops_hold_at: nil)
            .where(status: ABANDONABLE_STATUSES)
            .where(VARIETY_SQL)
            .where("#{LAST_SIGN_OF_LIFE_SQL} < ?", now - window.seconds)
            .where(TERMINATABLE_SQL)
            .where("NOT EXISTS (SELECT 1 FROM #{events} WHERE #{events}.account_id = ? " \
                   "AND #{events}.kind = ? " \
                   "AND #{events}.payload->>'failed_instance_id' = system_node_instances.id::text)",
                   account.id, REPLACE_ACQUIRED_KIND)

          self_id = self_hosting_node_id
          self_id ? relation.where.not(node_id: self_id) : relation
        end

        # The rows #sense signals on this tick — what the other sensors exclude.
        def self.claimed_relation(account:)
          new(account: account).claimed
        end

        def self.last_sign_of_life(instance)
          instance.last_heartbeat_at || instance.created_at
        end

        # The row-level spelling of .abandoned_relation.
        def self.abandoned?(instance, account:, now: Time.current, window_seconds: nil)
          return false if instance.nil? || instance.node&.account_id != account.id

          window = window_seconds || self.window_seconds(account)
          sign = last_sign_of_life(instance)

          variety_eligible = ABANDONABLE_VARIETIES.include?(instance.variety) ||
            (GUEST_LOST_ONLY_VARIETIES.include?(instance.variety) && instance.provider_guest_lost?)

          instance.instance_pool_id.nil? &&
            instance.ops_hold_at.nil? &&
            ABANDONABLE_STATUSES.include?(instance.status) &&
            variety_eligible &&
            sign.present? && sign < now - window.seconds &&
            (instance.cloud_instance_id.present? || instance.provider_guest_lost?) &&
            instance.node_id != self_hosting_node_id &&
            !replace_in_flight?(instance, account)
        end

        # Why a reap of this instance must wait for a person, in any plane. The
        # batched sets are what #claimed already loaded; omitted, they are read.
        #
        # A failover-standby-only membership is deliberately NOT a reason: it is
        # pruned by the applier itself before terminating (see
        # DecisionEngine#reap_abandoned_instance and .virtual_ip_holdings below),
        # the same way an attached volume is detached rather than parked forever.
        # Only being the ACTIVE holder blocks — approval cannot move an address.
        def self.approval_reasons(instance, account:, attached_volume_ids: nil, active_virtual_ip_holder_ids: nil)
          attached = attached_volume_ids ? attached_volume_ids.include?(instance.id) : attached_volume_instance_ids([ instance.id ]).any?
          active_holder = active_virtual_ip_holder_ids ? active_virtual_ip_holder_ids.include?(instance.id) : active_holder_instance_ids([ instance.id ], account: account).any?

          reasons = []
          reasons << instance.status if APPROVAL_STATUSES.include?(instance.status)
          reasons << "attached_volumes" if attached
          reasons << "virtual_ip_active_holder" if active_holder
          reasons
        end

        def self.attached_volume_instance_ids(instance_ids)
          return Set.new if instance_ids.empty?

          ::System::ProviderVolume.attached.where(node_instance_id: instance_ids)
            .distinct.pluck(:node_instance_id).to_set
        end

        # Instances with a peer that is the ACTIVE holder of a virtual IP —
        # never merely a failover candidate. See .virtual_ip_holdings for the
        # per-VIP split the applier uses to prune failover-only membership.
        #
        # IMP-10c9b9634d4e review D4/D5 — scoped to `account`, the SAME array-
        # overlap predicate .virtual_ip_holdings uses below (one spelling of
        # "does this peer id sit in this VIP's holder list", not two), FILTERED
        # IN POSTGRES rather than an EXISTS-per-peer subquery. The account
        # filter matters here more than it looks: instance_ids is already
        # account-scoped by the caller, but a VirtualIp is a separate table
        # joined only through an array of peer ids, so nothing before this
        # filter stops it matching a VIP row in a DIFFERENT account. Unscoped,
        # this method (the approval CARD's source) could name a foreign VIP as
        # an active-holder reason that .virtual_ip_holdings (the APPLIER,
        # already account-scoped) would never see — the card would say
        # "approval will not help" for a holding the applier doesn't believe
        # exists. Scoped the same way here, the two cannot disagree.
        def self.active_holder_instance_ids(instance_ids, account:)
          return Set.new if instance_ids.empty?

          peers = ::Sdwan::Peer.where(node_instance_id: instance_ids).pluck(:id, :node_instance_id)
          return Set.new if peers.empty?

          peer_ids = peers.map(&:first)
          matched_peer_ids = ::Sdwan::VirtualIp.where(account_id: account.id)
            .where("holder_peer_ids && ARRAY[:ids]::uuid[]", ids: peer_ids)
            .pluck(:holder_peer_ids).flatten & peer_ids

          peers.filter_map { |peer_id, instance_id| instance_id if matched_peer_ids.include?(peer_id) }.to_set
        end

        # The VIPs a peer of this instance appears in, split into ACTIVE (the
        # reap refuses outright — approval cannot fix a moved address) and
        # FAILOVER-ONLY (safe for the reap to prune before terminating: the
        # guest never served that address, only queued behind it). Re-read
        # fresh, not the sense-time batch #claimed built — the applier's reap
        # can run hours after the signal, and holder state may have moved.
        #
        # IMP-10c9b9634d4e review D4 — FILTERED IN POSTGRES by the same
        # array-overlap predicate PromoteReplicaExecutor#cutover_vips uses
        # (`&&` on the uuid[] holder columns), not `Enumerable#select` on an
        # unmaterialised relation: the earlier form loaded every VIP in the
        # account on every reap application to find the handful (usually
        # zero) this instance's peers touch. The partition below only walks
        # the already-matched, typically tiny result.
        def self.virtual_ip_holdings(instance, account:)
          peer_ids = ::Sdwan::Peer.where(node_instance_id: instance.id).pluck(:id)
          return { peer_ids: [], active: [], failover_only: [] } if peer_ids.empty?

          touching = ::Sdwan::VirtualIp.where(account_id: account.id)
            .where("holder_peer_ids && ARRAY[:ids]::uuid[] OR failover_holder_peer_ids && ARRAY[:ids]::uuid[]",
                   ids: peer_ids)
            .to_a
          active, failover_only = touching.partition { |vip| (Array(vip.holder_peer_ids) & peer_ids).any? }

          { peer_ids: peer_ids, active: active, failover_only: failover_only }
        end

        def self.replace_in_flight?(instance, account)
          ::System::FleetEvent
            .where(account_id: account.id, kind: REPLACE_ACQUIRED_KIND)
            .where("payload->>'failed_instance_id' = ?", instance.id.to_s)
            .exists?
        end

        def self.self_hosting_node_id
          ::SiteSetting.get(::System::Autonomy::SelfManagementFence::SELF_HOSTING_NODE_ID_KEY).presence
        end

        def claimed
          @claimed ||= begin
            window = threshold("abandon_after_seconds")
            rows = fence_to_control_plane(self.class.abandoned_relation(account: account, window_seconds: window))
              .order(Arel.sql(ORDER_SQL))
              .select(:id, :status, :environment_id)
              .to_a
            ids = rows.map(&:id)
            @attached_volume_ids = self.class.attached_volume_instance_ids(ids)
            @active_virtual_ip_holder_ids = self.class.active_holder_instance_ids(ids, account: account)
            environments = ::Ai::Environment.where(id: rows.filter_map(&:environment_id).uniq).index_by(&:id)
            escalates = Hash.new { |memo, env_id| memo[env_id] = plane_escalates?(environments[env_id]) }

            proceed_budget = threshold("max_per_tick")
            parked_budget = threshold("max_parked_per_tick")
            chosen = rows.filter_map do |row|
              parks = reasons_for(row).any? || escalates[row.environment_id]
              if parks
                next unless parked_budget.positive?

                parked_budget -= 1
              else
                next unless proceed_budget.positive?

                proceed_budget -= 1
              end
              row.id
            end

            ::System::NodeInstance.where(id: chosen).order(Arel.sql(ORDER_SQL))
          end
        end

        def sense
          window = threshold("abandon_after_seconds")

          claimed.map { |instance| signal_for(instance, window) }
        end

        private

        def reasons_for(instance)
          self.class.approval_reasons(instance, account: account, attached_volume_ids: @attached_volume_ids,
                                                active_virtual_ip_holder_ids: @active_virtual_ip_holder_ids)
        end

        # The same rule the gate applies (Ai::EnvironmentPolicyOverlay), asked of
        # this category, so a reap the plane will park does not spend the
        # terminate bound.
        def plane_escalates?(environment)
          environment.present? &&
            ::Ai::EnvironmentPolicyOverlay.escalation_reason(environment, ACTION_CATEGORY).present?
        end

        def signal_for(instance, window)
          reasons = reasons_for(instance)

          signal(
            kind: SIGNAL_KIND,
            severity: :medium,
            payload: {
              "instance_id" => instance.id,
              "node_id" => instance.node_id,
              "environment_id" => instance.environment_id,
              "status" => instance.status,
              "last_heartbeat_at" => instance.last_heartbeat_at&.iso8601,
              "last_sign_of_life_at" => self.class.last_sign_of_life(instance)&.iso8601,
              "abandon_after_seconds" => window,
              "requires_approval" => reasons.any?,
              "approval_reasons" => reasons
            },
            fingerprint: "#{SIGNAL_KIND.delete_prefix('system.')}:#{instance.id}"
          )
        end
      end
    end
  end
end
