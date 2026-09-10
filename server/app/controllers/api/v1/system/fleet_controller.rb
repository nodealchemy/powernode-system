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
          # system.fleet.read, not system.fleet.autonomy. This reads FleetEvents
          # for the operator's own account; it makes no autonomy decision, and
          # the catalog scopes system.fleet.autonomy to the system_worker role
          # (powernode_system/engine.rb:190-191). Gating an operator dashboard
          # on a worker permission meant only super_admin reached it — via the
          # system.admin grant-all rule, not because the gate was right.
          # system.fleet.read ("View fleet / concierge state", grant: admin) is
          # the operator-facing fleet permission that already exists for
          # exactly this, and is what the sibling operator endpoint
          # concierge_controller.rb:27 already uses. (IMP-27a8654e7c04)
          require_permission("system.fleet.read")

          unless params[:instance_id].present?
            return render_error("instance_id required", status: :unprocessable_content)
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
          # `reorder` (not `order`) so we replace .recent's DESC order
          # rather than chain it. The Boot Replay timeline must read
          # earliest-first to render the boot phases correctly.
          events = scope.reorder(emitted_at: :asc).limit(limit)

          render_success(
            events: events.map(&:as_broadcast),
            instance_id: instance.id,
            phase_summary: phase_summary_for(events)
          )
        end

        # POST /api/v1/system/fleet/signals
        # Body: { limit?, kind?, correlation_id?, since? }
        def signals
          # Same reclassification as #boot_replay above: reads this account's
          # FleetEvents, decides nothing. (IMP-27a8654e7c04)
          require_permission("system.fleet.read")

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
            render_error(result[:error], status: :unprocessable_content)
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
            render_error(result[:error], status: :unprocessable_content)
          end
        end

        # GET /api/v1/system/fleet/remediation_outcomes
        # Params: { window_days? } — 1..90, default 7.
        #
        # IMP-01a05ae8 — the operator read surface for RemediationOutcome, the
        # ground truth for whether an autonomous remediation actually cleared its
        # signal. Until this it was read only by the autonomy internals.
        #
        # Per signal_kind over the window: counts by status, and an effectiveness
        # rate = mean RemediationOutcome#effectiveness_score over SETTLED rows.
        # Pending and inconclusive rows carry no score, so a kind with nothing
        # settled reports nil rather than a misleading 0%.
        #
        # `stuck` is the set of fingerprints the DecisionEngine is escalating as
        # stuck right now, computed with the engine's own ineffective_streak and
        # STUCK_STREAK_THRESHOLD so it cannot become a rival definition. It is
        # not windowed, because the engine's streak is not.
        def remediation_outcomes
          require_permission("system.fleet.read")

          account = current_user.account
          window_days = (params[:window_days] || 7).to_i.clamp(1, 90)
          since = window_days.days.ago
          windowed = ::System::Fleet::RemediationOutcome.where(account: account, acted_at: since..)

          counts = windowed.group(:signal_kind, :status).count
          scores = Hash.new { |h, k| h[k] = [] }
          windowed.where(status: %w[effective ineffective]).select(:id, :signal_kind, :status)
                  .find_each { |outcome| scores[outcome.signal_kind] << outcome.effectiveness_score }

          kinds = counts.keys.map(&:first).uniq.sort.map do |kind|
            by_status = counts.each_with_object({}) { |((k, status), n), acc| acc[status] = n if k == kind }
            outcome_summary(by_status, scores[kind]).merge(signal_kind: kind)
          end
          total_by_status = counts.each_with_object(Hash.new(0)) { |((_, status), n), acc| acc[status] += n }

          render_success(
            window_days: window_days,
            since: since.iso8601,
            kinds: kinds,
            totals: outcome_summary(total_by_status, scores.values.flatten),
            stuck: stuck_remediations(account)
          )
        end

        private

        STUCK_CANDIDATE_LIMIT = 200
        private_constant :STUCK_CANDIDATE_LIMIT

        def outcome_summary(by_status, scores)
          ::System::Fleet::RemediationOutcome::STATUSES.index_with { |s| by_status.fetch(s, 0) }.merge(
            settled: scores.size,
            effectiveness_rate: scores.empty? ? nil : (scores.sum / scores.size).round(4)
          )
        end

        # Only a fingerprint with at least `threshold` ineffective rows can have
        # a streak that long, so that is the cheap pre-filter; the verdict is
        # the engine's own RemediationOutcome.ineffective_streak.
        def stuck_remediations(account)
          threshold = ::System::Fleet::DecisionEngine::STUCK_STREAK_THRESHOLD
          candidates = ::System::Fleet::RemediationOutcome
            .where(account: account, status: "ineffective")
            .group(:fingerprint)
            .having("COUNT(*) >= ?", threshold)
            .order(Arel.sql("MAX(validated_at) DESC NULLS LAST"))
            .limit(STUCK_CANDIDATE_LIMIT)
            .pluck(:fingerprint, Arel.sql("MAX(signal_kind)"), Arel.sql("MAX(validated_at)"))

          fingerprints = candidates.filter_map do |fingerprint, signal_kind, last_validated_at|
            streak = ::System::Fleet::RemediationOutcome.ineffective_streak(account: account, fingerprint: fingerprint)
            next if streak < threshold

            { fingerprint: fingerprint, signal_kind: signal_kind, streak: streak,
              last_validated_at: last_validated_at&.iso8601 }
          end

          { threshold: threshold, fingerprints: fingerprints }
        end

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
