# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # Detects NodeInstance rows whose model `status` disagrees with what
      # the underlying provider actually reports — typically `status='running'`
      # in the DB while the libvirt domain is `shut off`, or vice versa.
      #
      # Distinct from `InstanceStatusSensor`: that one watches *heartbeats*
      # (the agent stopped phoning home), this one watches *provider state*
      # (the VM itself stopped). Heartbeat-silent + provider-running = an
      # agent crash; heartbeat-silent + provider-shut-off = a libvirt-side
      # stop. Both signals are useful diagnostics for the autonomy
      # DecisionEngine to route to the right remediation.
      #
      # Emits `system.instance_state_drifted` signals which the
      # DecisionEngine routes to the `system.instance_reboot` action
      # category (notify_and_proceed in the fleet_autonomy_agent.rb seed)
      # — gating it through the same approval pipeline as every other
      # fleet action.
      class InstanceStateDriftSensor < BaseSensor
        # Cap how many instances we poll per tick. Each sync_status call
        # is one virsh subprocess (~50ms for local_qemu), so a tick of
        # 100 instances = ~5s. Conservative bound; raise if needed.
        MAX_PER_TICK = 50

        def sense
          # Least-recently-ATTEMPTED first (IMP-bcadb1ecd52d, refining
          # IMP-e26d76041d9a): the original rotation ordered by the
          # success-only last_synced_at, so never-stampable rows (no adapter,
          # no cloud id, persistently failing reads) kept NULL forever, pinned
          # the front of the window, and MAX_PER_TICK of them starved every
          # other instance of drift checks. signal_for stamps
          # last_sync_attempted_at on EVERY row that enters the window, so
          # unstampable rows rotate to the back like everyone else — while
          # last_synced_at keeps its success-only convention for its readers.
          # NULLS FIRST so never-attempted instances are checked before any
          # re-check.
          ::System::NodeInstance
            .joins(:node)
            .where(system_nodes: { account_id: account.id })
            .where(status: "running")
            .order(Arel.sql("system_node_instances.last_sync_attempted_at ASC NULLS FIRST"))
            .limit(MAX_PER_TICK)
            .filter_map { |inst| signal_for(inst) }
        end

        private

        def signal_for(instance)
          # Stamped BEFORE every bail-out below — the rotation invariant is
          # "each window slot advances", not "each successful read advances",
          # or unstampable rows would pin the window (IMP-bcadb1ecd52d).
          instance.update_column(:last_sync_attempted_at, Time.current)

          adapter = ::System::Providers::Registry.for_instance(instance)
          return nil unless adapter.respond_to?(:sync_status)

          cloud_id = instance.config&.dig("cloud_instance_id")
          return nil if cloud_id.blank?

          result = adapter.sync_status(cloud_id)
          return nil unless result[:success]

          # A successful sync_status IS a provider sync — stamp it so the
          # sense window above rotates past this instance next tick.
          instance.update_column(:last_synced_at, Time.current)

          provider_status = result[:status].to_s
          return nil if provider_status.empty?
          return nil if provider_status == instance.status

          # Only flag drift when the provider says the instance is in a
          # terminal-stopped or terminated state. A provider reporting
          # `pending` or another transitional value while the model says
          # `running` is normal during boot/reboot windows and shouldn't
          # trigger the drift signal.
          return nil unless %w[stopped terminated error].include?(provider_status)

          # provider_status is always one of stopped/terminated/error here
          # (filtered above) — it can never be "running", so this is always
          # :high.
          signal(
            kind: "system.instance_state_drifted",
            severity: :high,
            payload: {
              instance_id: instance.id,
              node_id: instance.node_id,
              expected_status: instance.status,
              actual_status: provider_status,
              cloud_instance_id: cloud_id,
              provider_type: instance.provider_region&.provider&.provider_type
            },
            fingerprint: "instance_state_drifted:#{instance.id}:#{provider_status}"
          )
        rescue StandardError => e
          Rails.logger.warn("[InstanceStateDriftSensor] sync_status failed for #{instance.id}: #{e.class}: #{e.message}")
          nil
        end
      end
    end
  end
end
