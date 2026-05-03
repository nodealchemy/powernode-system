# frozen_string_literal: true

module Api
  module V1
    module System
      # Operator-facing fleet observability + attribution endpoints.
      # Distinct from `worker_api/fleet_controller` (which is worker-token
      # auth and runs the reconcile tick). This is JWT-authenticated and
      # backs the M-FE-3 Fleet Dashboard.
      class FleetController < BaseController
        before_action :authenticate_request

        BOOT_PHASE_KEYWORDS = {
          "firmware"   => %w[boot.firmware boot.bios],
          "bootloader" => %w[boot.bootloader boot.grub boot.uboot boot.ipxe],
          "kernel"     => %w[boot.kernel],
          "initramfs"  => %w[boot.initramfs boot.dracut],
          "systemd"    => %w[boot.systemd boot.userspace],
          "enrollment" => %w[instance.enroll instance.csr_signed instance.cert_received],
          "heartbeat"  => %w[instance.first_heartbeat instance.online]
        }.freeze
        private_constant :BOOT_PHASE_KEYWORDS

        # GET /api/v1/system/fleet/boot_replay
        # Returns FleetEvents for one node_instance ordered by emission time,
        # filtered to boot.* kinds plus any events sharing the boot's
        # correlation_id (mTLS handshake, agent enroll, first heartbeat).
        # Used by the M-FE-3 Boot Replay viewer.
        # Comprehensive stabilization sweep P7.1.
        #
        # Params: { instance_id, correlation_id?, limit? }
        def boot_replay
          require_permission("system.fleet.autonomy")

          unless params[:instance_id].present?
            return render_error("instance_id required", status: :unprocessable_entity)
          end

          # Per-tenant guard: only return events for instances owned by the
          # operator's account (mirrors nodes_controller scoping).
          instance = ::System::NodeInstance
            .joins(:node)
            .where(system_nodes: { account_id: current_user.account.id })
            .find_by(id: params[:instance_id])
          return render_not_found("Node Instance") unless instance

          scope = ::System::FleetEvent
            .where(account: current_user.account, node_instance_id: instance.id)
            .recent

          # Filter to boot.* kinds OR shared correlation_id (so non-boot
          # events that happened in the same boot session appear too).
          if params[:correlation_id].present?
            scope = scope.where("kind LIKE ? OR correlation_id = ?", "boot.%", params[:correlation_id])
          else
            scope = scope.where("kind LIKE ?", "boot.%")
          end

          limit = (params[:limit] || 200).to_i.clamp(1, 500)
          events = scope.order(emitted_at: :asc).limit(limit)

          render_success(
            events: events.map(&:as_broadcast),
            instance_id: instance.id,
            phase_summary: phase_summary_for(events)
          )
        end

        # POST /api/v1/system/fleet/signals
        # Body: { limit?, kind?, correlation_id?, since? }
        def signals
          require_permission("system.fleet.autonomy")

          scope = ::System::FleetEvent.where(account: current_user.account).recent
          scope = scope.by_correlation(params[:correlation_id]) if params[:correlation_id].present?
          scope = scope.by_kind(params[:kind]) if params[:kind].present?
          if (since = parse_iso(params[:since]))
            scope = scope.since(since)
          end
          limit = (params[:limit] || 50).to_i.clamp(1, 200)
          events = scope.limit(limit)

          render_success(
            events: events.map(&:as_broadcast),
            count: events.size,
            channel: "system_fleet:#{current_user.account.id}"
          )
        end

        # POST /api/v1/system/fleet/attribute_failure
        # Body: { instance_id, lookback_hours? }
        def attribute_failure
          require_permission("system.node_instances.read")

          executor = ::System::Ai::Skills::AttributeFailureExecutor.new(account: current_user.account)
          result = executor.execute(
            instance_id: params[:instance_id],
            lookback_hours: params[:lookback_hours] || 24
          )

          if result[:success]
            render_success(result[:data])
          else
            render_error(result[:error], status: :unprocessable_entity)
          end
        end

        # POST /api/v1/system/fleet/attribution_feedback
        # Body: { instance_id, candidate_id, confirmed: true|false, note? }
        # Persists operator's confirm/reject of an attribution as a Learning
        # so future calls can boost the candidate's pattern recognition.
        def attribution_feedback
          require_permission("system.node_instances.read")

          service = ::System::Fleet::AttributionFeedbackService.new(account: current_user.account)
          result = service.record!(
            instance_id: params[:instance_id],
            candidate_module_id: params[:candidate_module_id],
            candidate_kind: params[:candidate_kind],
            confirmed: params[:confirmed],
            note: params[:note]
          )

          if result[:ok]
            render_success(learning_id: result[:learning_id])
          else
            render_error(result[:error], status: :unprocessable_entity)
          end
        end

        private

        # Group boot events into phases for the Boot Replay timeline.
        # Returns a Hash<phase_label, {first_at, last_at, count}>.
        def phase_summary_for(events)
          BOOT_PHASE_KEYWORDS.each_with_object({}) do |(phase, prefixes), acc|
            matched = events.select { |e| prefixes.any? { |p| e.kind.start_with?(p) } }
            next if matched.empty?
            acc[phase] = {
              first_at: matched.first.emitted_at,
              last_at: matched.last.emitted_at,
              count: matched.size
            }
          end
        end

        def parse_iso(str)
          return nil if str.blank?
          Time.iso8601(str)
        rescue ArgumentError
          nil
        end
      end
    end
  end
end
