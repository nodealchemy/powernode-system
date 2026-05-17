# frozen_string_literal: true

module Federation
  # P9 — Auto-policy capability sync.
  #
  # Walks every FederationCapability whose `policy` is in the auto-flow
  # set (auto_periodic, auto_on_change, on_match_filter) and dispatches
  # the appropriate sync action per policy + direction:
  #
  #   auto_periodic   — periodic full scan since last_synced_at
  #   on_match_filter — periodic scan filtered by `filter` jsonb
  #   auto_on_change  — opt-in callback path (not driven by this worker —
  #                     resource models with after_commit hooks publish
  #                     events; this service is a no-op for them but
  #                     stamps the cursor so dashboards can see the
  #                     last opportunity)
  #
  # Each capability gets its own per-row transaction so a failure on
  # one (e.g. peer offline, capability filter invalid) doesn't poison
  # the rest of the sweep.
  #
  # The actual record transport is delegated to
  # `Federation::ResourceSyncTransport`, which knows how to push/pull
  # the resource_kind via the peer's `/federation_api/resources`
  # endpoint with the right grant. Today the transport stamps
  # sync_cursor with a watermark + last_synced_at; per-kind serializers
  # are added incrementally as kinds opt in.
  #
  # Plan reference: P9 — auto-policy capabilities; closes the
  # operator-burden gap that motivated Architectural Fix 1 (FederationManager
  # AI Skill in P4).
  class CapabilityAutoSyncService
    Result = ::Struct.new(:swept, :synced, :failed, :failures, keyword_init: true)

    class << self
      def run!(account: nil, peer: nil, now: ::Time.current)
        new(account: account, peer: peer, now: now).run!
      end
    end

    def initialize(account:, peer:, now:)
      @account = account
      @peer    = peer
      @now     = now
    end

    def run!
      scope = base_scope
      swept     = 0
      synced    = 0
      failed    = 0
      failures  = []

      scope.includes(:federation_peer).find_each do |capability|
        swept += 1
        next if capability.federation_peer.nil?
        # Only sync against peers in good standing — degraded / suspended
        # peers shouldn't get pushed at since the operator may be
        # actively intervening. The peer must be in `active` state.
        next unless capability.federation_peer.status == "active"

        begin
          dispatch!(capability)
          synced += 1
        rescue ::StandardError => e
          failed += 1
          failures << { capability_id: capability.id, error: "#{e.class}: #{e.message}" }
          ::Rails.logger.warn("[CapabilityAutoSyncService] cap=#{capability.id} #{e.class}: #{e.message}")
        end
      end

      Result.new(swept: swept, synced: synced, failed: failed, failures: failures)
    end

    private

    attr_reader :account, :peer, :now

    def base_scope
      scope = ::System::FederationCapability.auto_flow
      scope = scope.where(federation_peer: { account_id: account.id })
                   .joins(:federation_peer) if account
      scope = scope.where(federation_peer_id: peer.id) if peer
      scope
    end

    def dispatch!(capability)
      case capability.policy
      when "auto_periodic"
        sync_periodic!(capability)
      when "on_match_filter"
        sync_filtered!(capability)
      when "auto_on_change"
        # No-op: model-side after_commit hooks own this policy's
        # transport. We still bump the cursor so dashboards can show
        # "last considered" timestamps.
        stamp_cursor!(capability, mode: "on_change_passthrough")
      else
        raise ::ArgumentError, "Unknown auto policy: #{capability.policy.inspect}"
      end
    end

    # Periodic sync: walk every record of the capability's resource_kind
    # since last_synced_at, push/pull per direction. The transport
    # encapsulates the per-kind serialization + HTTP call.
    def sync_periodic!(capability)
      since = capability.last_synced_at || @now - 1.hour
      transport = build_transport(capability)
      result = transport.sweep_since!(since: since, now: @now)

      capability.update!(
        last_synced_at: @now,
        sync_cursor: capability.sync_cursor.merge(
          "last_sweep_at"    => @now.iso8601,
          "last_sweep_count" => result.count,
          "watermark"        => result.watermark&.iso8601,
          "mode"             => "auto_periodic"
        )
      )
    end

    # Filtered sync: same as periodic but the transport applies the
    # capability's `filter` jsonb as a predicate before transferring.
    def sync_filtered!(capability)
      since = capability.last_synced_at || @now - 1.hour
      transport = build_transport(capability)
      result = transport.sweep_since!(
        since:  since,
        now:    @now,
        filter: capability.filter
      )

      capability.update!(
        last_synced_at: @now,
        sync_cursor: capability.sync_cursor.merge(
          "last_sweep_at"    => @now.iso8601,
          "last_sweep_count" => result.count,
          "watermark"        => result.watermark&.iso8601,
          "mode"             => "on_match_filter",
          "filter_used"      => capability.filter
        )
      )
    end

    def stamp_cursor!(capability, mode:)
      capability.update!(
        last_synced_at: @now,
        sync_cursor: capability.sync_cursor.merge(
          "last_sweep_at" => @now.iso8601,
          "mode"          => mode
        )
      )
    end

    def build_transport(capability)
      ::Federation::ResourceSyncTransport.new(capability: capability)
    end
  end
end
