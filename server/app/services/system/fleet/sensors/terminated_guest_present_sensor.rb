# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # IMP-ff6d46f2c3e1 — gap (1) of IMP-8225624f46b1 reaches an operator.
      #
      # WHY A SENSOR OF ITS OWN
      #
      # Every other fleet sensor treats a `terminated` NodeInstance as terminal
      # and stops looking at it — InstanceStatusSensor's HEARTBEAT_EXPECTED_STATUSES
      # and AbandonedInstanceSensor's ABANDONABLE_STATUSES both exclude it, on the
      # reasonable assumption that a terminated row has nothing left to reap. That
      # assumption breaks exactly when InstanceControlService commits terminate!
      # before the provider call and the process crashes between the two: the row
      # reads terminated, but the provider never received the destroy, so the VM
      # keeps running — and billing — with no platform surface watching it. If
      # this sensor does not look at a terminated row, no sensor does.
      #
      # WHERE THE DATA COMES FROM
      #
      # The condition can only be observed against a LIVE cloud listing — the
      # provider's inventory is not persisted anywhere — so this sensor does not
      # query the provider itself (that would double the hourly provider-list
      # cost the scheduled CloudSyncService tick already pays, the same reasoning
      # OrphanPoolGuestSensor's own doc rejects for a different signal). Instead
      # it reads the System::FleetEvent audit trail
      # CloudSyncService#sync_region_instances writes on every SUCCESSFUL region
      # sync (TERMINATED_GUEST_CHECK_EVENT_KIND — not literally every tick: four
      # early-return arms and a rescue in that method produce no event at all),
      # never only when it finds something: the event's own presence is what
      # tells this sensor a measurement happened, distinct from a clean fleet.
      #
      # TWO ARMS, because "a check ran and found nothing" and "no check ran" are
      # different failure surfaces and were conflated in the first version of
      # this sensor (caught in review):
      #
      #   1. PRESENCE — #presence_signals. A check WITHIN the lookback window
      #      named a terminated row whose guest the provider still lists.
      #   2. STALENESS — #staleness_signals. A region this account has EVER
      #      synced has gone quiet: its own latest check event (regardless of
      #      how long ago — the query is a SQL MAX aggregate over the full
      #      retained history, not a Ruby scan bounded by the lookback window)
      #      is older than the same lookback threshold. A stalled measurement
      #      path is itself the thing gap (1) needs someone to notice — a
      #      dead sync reports nothing wrong not because nothing is wrong, but
      #      because nothing is looking.
      #
      # ONE SHARED THRESHOLD on purpose, not two: "how old can the last check
      # be before we stop trusting it as current" is the same question from
      # both directions — below the line, presence data is fresh; at or above
      # it, the region's silence is itself the signal. A second, separately
      # tuned constant would let the two arms disagree about where "current"
      # ends, which is exactly the kind of drift a single value forecloses.
      #
      # WHAT STALENESS DECLINES TO COVER, STATED RATHER THAN LEFT IMPLICIT: a
      # region that has NEVER had a single check event (a brand-new region, or
      # one whose provider connection was never enabled) is invisible to
      # #staleness_signals — "known region" is derived entirely from this
      # account's own check-event history, so a region with zero history has
      # no baseline to go stale FROM. Catching a region that should exist but
      # has never synced even once needs an independent census (querying
      # System::ProviderRegion directly) that this sensor deliberately does not
      # do, to avoid re-deriving CloudSyncController#scope_accounts /
      # #sync_account's own region-eligibility logic a second place it could
      # drift from. A region that WAS syncing and stops is fully covered; a
      # region that was never wired up in the first place is a provisioning
      # question, not a staleness one.
      #
      # A region that goes stale because it was deliberately DISABLED (or
      # deleted) is not alarmed forever: #staleness_signals re-checks
      # System::ProviderRegion and only signals for a region still `enabled`
      # today. Without that, a decommissioned region's last check event would
      # cross the lookback line exactly once and then re-fire the same
      # fingerprint on every tick forever, with no way for the condition to
      # ever clear itself.
      #
      # WHAT IT DECLINES
      #
      #   * No applier exists, or could exist, for EITHER arm: the honest
      #     remediation is a person checking the provider console (presence),
      #     or checking why the hourly job/API stopped succeeding (staleness).
      #     Modeled on system.capability_gap / system.node_lkg_* (skill: nil,
      #     an `_investigate` action category each, both listed in
      #     RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES) — an
      #     ordinary notify_and_proceed category with no applier would hand
      #     RemediationValidator a pending outcome that can only clear when a
      #     human acts out of band, manufacturing a false
      #     fleet.remediation_stuck escalation the moment the streak threshold
      #     crosses. Two categories, not one, so an operator's queue keeps
      #     "there's a specific leaked instance" separate from "the detector
      #     itself may be dead" — the same reasoning BootLkgArmSensor gives for
      #     keeping node_lkg_unarmed and node_lkg_stale distinct kinds, except
      #     here the two also need distinct categories because, unlike LKG's
      #     pair, they can be true independently and an operator resolving one
      #     must not dismiss the other by association.
      #   * A resolved presence case does not need clearing by hand: the
      #     FleetEvent this sensor reads is a CHECK RESULT, not the fact
      #     itself, so once a later tick's check no longer names the instance
      #     (guest confirmed gone, or genuinely reprovisioned), this sensor
      #     simply stops re-emitting for it — fingerprint dedup does the rest.
      #     A resolved staleness case clears the same way the moment a fresh
      #     check event lands.
      class TerminatedGuestPresentSensor < BaseSensor
        SIGNAL_KIND = "system.cloud_sync_terminated_guest_present"
        ACTION_CATEGORY = "system.cloud_sync_terminated_guest_investigate"

        STALE_SIGNAL_KIND = "system.cloud_sync_check_stale"
        STALE_ACTION_CATEGORY = "system.cloud_sync_check_stale_investigate"

        # Wide enough to absorb one missed hourly tick (SystemCloudSyncJob's
        # single-flight lock plus its own `retry: 1` can skip a run) without
        # itself going so stale that a genuinely-resolved presence case is
        # re-reported from a check event several cycles old. Shared by both
        # arms — see the class doc for why that is one threshold, not two.
        LOOKBACK_SECONDS = 3.hours.to_i

        # Each matched row is a `decide` pass plus (at least) one more
        # FleetEvent on top of the check trail itself; bounded like every
        # sibling sensor (AbandonedInstanceSensor 10, InstanceUnrecoverableSensor
        # 25, OrphanPoolGuestSensor 10) so a botched bulk terminate cannot mint
        # an unbounded burst of PRESENCE signals in one tick.
        MAX_PER_TICK = 25

        # A SEPARATE budget for staleness, on purpose (review F1): a single
        # shared cap let a large presence burst silently crowd out the
        # staleness arm this whole round exists to add — "there are leaked
        # instances" starving "the detector that finds leaked instances may be
        # dead", which is the more urgent of the two precisely because the
        # first is unreliable without the second. A region count is normally
        # tiny next to an instance count, so this budget is deliberately
        # smaller — matching OrphanPoolGuestSensor's per-tick cap for the same
        # reason (its matched population is regions/pools, not instances).
        MAX_STALE_PER_TICK = 10

        def self.default_thresholds
          { "lookback_seconds" => LOOKBACK_SECONDS, "max_per_tick" => MAX_PER_TICK,
            "max_stale_per_tick" => MAX_STALE_PER_TICK }
        end

        def sense
          cutoff = Time.current - threshold("lookback_seconds").seconds

          presence_signals(cutoff).first(threshold("max_per_tick")) +
            staleness_signals(cutoff).first(threshold("max_stale_per_tick"))
        end

        private

        def presence_signals(cutoff)
          checks = ::System::FleetEvent
            .where(account_id: account.id, kind: ::System::CloudSyncService::TERMINATED_GUEST_CHECK_EVENT_KIND)
            .since(cutoff)
            .order(emitted_at: :desc)
            .to_a

          # The latest check PER REGION — an older check a fresher one has
          # already superseded says nothing the fresher one didn't, and would
          # otherwise resurrect an instance the fresher check no longer names.
          latest_per_region = checks.group_by { |event| event.payload["provider_region_id"] }
                                     .transform_values(&:first)

          instance_ids = latest_per_region.values.flat_map { |event|
            Array(event.payload["terminated_guest_present"])
          }.uniq
          return [] if instance_ids.empty?

          ::System::NodeInstance.where(id: instance_ids, status: "terminated")
                                 .filter_map { |instance| signal_for(instance) }
        end

        # Every region this account's check-event history knows about, and
        # when its LATEST one landed — a single GROUP BY MAX aggregate pushed
        # to SQL, not a Ruby-side scan of every retained row (which would load
        # up to ~90-365 days of history per region, per fleet_controller's
        # retention_sweep). A region silent for the entire retention window
        # still resolves correctly: MAX() reflects its true last event
        # regardless of how far outside any LIMIT window that event sits.
        def latest_check_at_by_region
          ::System::FleetEvent
            .where(account_id: account.id, kind: ::System::CloudSyncService::TERMINATED_GUEST_CHECK_EVENT_KIND)
            .group(Arel.sql("payload->>'provider_region_id'"))
            .maximum(:emitted_at)
        end

        def staleness_signals(cutoff)
          candidates = latest_check_at_by_region.reject do |region_id, last_checked_at|
            region_id.blank? || last_checked_at.nil? || last_checked_at >= cutoff
          end
          return [] if candidates.empty?

          # A region deliberately disabled (or deleted) since its last check
          # will never check in again BY DESIGN — alarming on it forever would
          # be a permanent false positive with no way to self-clear. Only a
          # region still enabled today is a genuine staleness signal.
          #
          # account_id: account.id (review F2): the ids come from this
          # account's OWN FleetEvent history, so an unscoped lookup cannot
          # leak another account's region today — but IMP-b9f4b900f00b scoped
          # exactly this class of provider-catalog read account-wide for a
          # reason, and a lookup that HAPPENS to be safe by construction is
          # not the same guarantee as one that is safe by scope. Same column
          # the controller's own #sync_account query filters on.
          live_region_ids = ::System::ProviderRegion.where(id: candidates.keys, account_id: account.id, enabled: true)
                                                     .pluck(:id).map(&:to_s).to_set
          return [] if live_region_ids.empty?

          candidates.filter_map do |region_id, last_checked_at|
            next unless live_region_ids.include?(region_id)

            stale_signal_for(region_id, last_checked_at)
          end
        end

        def signal_for(instance)
          signal(
            kind: SIGNAL_KIND,
            severity: :high,
            payload: {
              "instance_id" => instance.id,
              "node_id" => instance.node_id,
              "cloud_instance_id" => instance.cloud_instance_id,
              "provider_guest_name" => instance.provider_guest_name
            },
            fingerprint: "#{SIGNAL_KIND.delete_prefix('system.')}:#{instance.id}"
          )
        end

        def stale_signal_for(region_id, last_checked_at)
          signal(
            kind: STALE_SIGNAL_KIND,
            severity: :high,
            payload: {
              "provider_region_id" => region_id,
              "last_checked_at" => last_checked_at.utc.iso8601,
              "staleness_threshold_seconds" => threshold("lookback_seconds")
            },
            fingerprint: "#{STALE_SIGNAL_KIND.delete_prefix('system.')}:#{region_id}"
          )
        end
      end
    end
  end
end
