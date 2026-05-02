# frozen_string_literal: true

module System
  module Fleet
    # Computes current fleet pressure (capacity, error rate, drift saturation)
    # and emits stigmergic signals so trading + other subsystems can perceive
    # the fleet's current state and defer their own non-critical actions
    # when fleet is busy.
    #
    # Called from FleetAutonomyService.tick! after sensors run, so the
    # signal value is always fresh. Decay is handled by the platform's
    # StigmergicSignalService — old signals fade automatically.
    #
    # Reference: Golden Eclipse plan stigmergic coordination — fleet emits
    # `system.capacity_pressure` so trading can throttle session creation.
    class PressureEmitter
      def self.emit_for_account!(account:)
        new.emit_for_account!(account: account)
      end

      def emit_for_account!(account:)
        return unless defined?(::Ai::Coordination::StigmergicSignalService)

        capacity = compute_capacity_pressure(account)
        error_pressure = compute_error_pressure(account)

        emitted = []
        emitted << emit_signal(account: account, type: "system.capacity_pressure",
                                key: account.id, strength: capacity[:strength],
                                payload: capacity)
        emitted << emit_signal(account: account, type: "system.fleet_error_pressure",
                                key: account.id, strength: error_pressure[:strength],
                                payload: error_pressure)

        # Per-region pressure when ≥1 region is loaded (used by
        # trading.region_expansion, system.region_expansion gates).
        per_region = compute_region_pressure(account)
        per_region.each do |region_id, observation|
          emitted << emit_signal(account: account, type: "system.region_busy",
                                  key: region_id, strength: observation[:strength],
                                  payload: observation)
        end

        emitted.compact.size
      rescue StandardError => e
        Rails.logger.warn("[PressureEmitter] failed: #{e.message}")
        0
      end

      private

      def emit_signal(account:, type:, key:, strength:, payload:)
        return nil if strength <= 0

        service = ::Ai::Coordination::StigmergicSignalService.new(account: account)
        service.emit!(
          signal_type: type,
          signal_key: key.to_s,
          agent: nil,
          strength: strength.to_f.clamp(0.0, 5.0),
          decay_rate: 0.05,
          payload: payload.deep_stringify_keys,
          ttl: 30.minutes
        )
      end

      def compute_capacity_pressure(account)
        instances = ::System::NodeInstance.joins(:node)
                                          .where(system_nodes: { account_id: account.id })
        total = instances.count
        return { strength: 0, ratio: 0, total: 0 } if total.zero?

        running = instances.where(status: "running").count
        # If <50% running, capacity is *more* pressured (instances need provisioning).
        # If >90% running, also pressured (no slack).
        utilization = running.to_f / total
        strength = if utilization < 0.5
                     1.0 * (1.0 - utilization * 2) # 0.5 underutilized = 0; 0% = 1.0
                   elsif utilization > 0.9
                     1.0 * (utilization - 0.9) * 10  # 90% = 0; 100% = 1.0
                   else
                     0
                   end
        { strength: strength.round(3), ratio: utilization.round(3), running: running, total: total }
      end

      def compute_error_pressure(account)
        return { strength: 0 } unless defined?(::System::FleetEvent)

        cutoff = 15.minutes.ago
        recent = ::System::FleetEvent
                  .where(account: account)
                  .where("emitted_at >= ?", cutoff)

        total = recent.count
        return { strength: 0, total: 0 } if total.zero?

        critical = recent.where(severity: %w[high critical]).count
        ratio = critical.to_f / total
        # Strength scales with critical-event ratio; cap at 1.0
        { strength: (ratio * 1.0).round(3), total: total, critical: critical, ratio: ratio.round(3) }
      end

      def compute_region_pressure(account)
        return {} unless defined?(::System::ProviderRegion)

        ::System::NodeInstance
          .joins(:node)
          .where(system_nodes: { account_id: account.id })
          .where(status: "running")
          .group(:provider_region_id)
          .count
          .filter_map do |region_id, count|
            next if region_id.nil? || count < 5
            # Saturation proxy: each region's instance count relative to
            # account median. Until M-D2-2 ships per-region capacity hints,
            # we use raw count.
            [region_id, { strength: [count.to_f / 20.0, 1.0].min.round(3),
                          instance_count: count }]
          end
          .to_h
      end
    end
  end
end
