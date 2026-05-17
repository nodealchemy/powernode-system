# frozen_string_literal: true

module System
  module Federation
    # Sweeps platform federation peers whose last_heartbeat_at has gone
    # stale (default 5 minutes). Active peers transition to degraded;
    # degraded peers stay degraded (no auto-suspend — that's an operator
    # decision via the dashboard or governance scanner).
    #
    # Designed to run every 60s via a Sidekiq worker job. Outbound
    # heartbeat initiation (this platform calling peer.heartbeat_url) is
    # a separate concern; this service only updates state derived from
    # the INBOUND heartbeats recorded by HeartbeatController.
    #
    # Plan reference: Decentralized Federation §C + P3.5.
    class HeartbeatSweepService
      Result = Struct.new(:swept, :degraded_ids, :ran_at, keyword_init: true)

      DEFAULT_THRESHOLD = ::System::FederationPeer::HEARTBEAT_STALE_AFTER

      class << self
        def run!(threshold: DEFAULT_THRESHOLD)
          new.run!(threshold: threshold)
        end
      end

      def run!(threshold: DEFAULT_THRESHOLD)
        cutoff = Time.current - threshold
        degraded_ids = []

        # Only active peers transition; enrolled peers that never heartbeat
        # remain enrolled (a different governance finding flags them as
        # `peer_capability_drift`).
        ::System::FederationPeer
          .where(peer_kind: "platform", status: "active")
          .where("last_heartbeat_at IS NULL OR last_heartbeat_at < ?", cutoff)
          .find_each(batch_size: 100) do |peer|
            next unless peer.mark_degraded!(reason: "heartbeat stale (>#{threshold.inspect})")
            degraded_ids << peer.id
            emit_event!(peer)
          end

        Result.new(
          swept: degraded_ids.size,
          degraded_ids: degraded_ids,
          ran_at: Time.current
        )
      end

      private

      def emit_event!(peer)
        return unless defined?(::System::Fleet::EventBroadcaster)

        ::System::Fleet::EventBroadcaster.emit!(
          account: peer.account,
          kind: "federation.peer.heartbeat_stale",
          severity: "medium",
          source: "federation_heartbeat_sweep",
          payload: {
            peer_id: peer.id,
            last_heartbeat_at: peer.last_heartbeat_at&.iso8601,
            previous_status: "active",
            new_status: peer.status
          }
        )
      rescue StandardError => e
        Rails.logger.warn("[HeartbeatSweepService] event emit failed: #{e.message}")
      end
    end
  end
end
