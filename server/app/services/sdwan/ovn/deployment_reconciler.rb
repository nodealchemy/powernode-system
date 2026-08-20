# frozen_string_literal: true

module Sdwan
  module Ovn
    # IMP-57e9a90598ee — the driver that gives Sdwan::OvnDeployment's AASM
    # events their first production caller. Runs inside the node heartbeat
    # (StatusController#heartbeat), per heavyweight chassis, and moves the
    # account's deployment strictly on MEASURED evidence:
    #
    #   pending → bootstrapping   endpoints are asserted on the row. This is
    #                             the one transition that is a CONFIG fact,
    #                             not a health claim — "bootstrapping" means
    #                             exactly "endpoints set, chassis are being
    #                             served config" (see the model's lifecycle
    #                             comment), and both halves of that are now
    #                             true by construction.
    #
    #   → active                  a positive observation of the NB DB itself:
    #                             either a chassis replayed the FULL compiled
    #                             plan against it and said so (the agent's
    #                             ObservedOvnNbState off the heartbeat), or
    #                             the control-plane NbProbe got a list_dbs
    #                             reply naming OVN_Northbound. Never because a
    #                             row exists, a create succeeded, or time
    #                             passed.
    #
    #   active → degraded         a MEASURED negative: a chassis reported a
    #                             failed/partial replay, or the probe got a
    #                             refusal/garbage where it previously
    #                             confirmed.
    #
    #   degraded → active         the failing source recovered. Failures are
    #                             tracked per source (chassis instance id or
    #                             "nb_probe") in nb_observed["failing"], and
    #                             an entry clears only when ITS source next
    #                             succeeds — the agent's own per-subsystem
    #                             rule ("another subsystem's success never
    #                             clears it"), transplanted. One exception,
    #                             deliberate: an EXECUTED full chassis replay
    #                             also clears the probe's entry, because both
    #                             observe the same subject (the NB DB) and a
    #                             direct positive from the consumer supersedes
    #                             an indirect negative from the control plane.
    #
    # ABSENCE IS "NOT MEASURED": a missing observation, an empty-plan replay
    # (the applier executed nothing), and a probe that could not speak the
    # endpoint's scheme all leave the state exactly where it was.
    #
    # A CACHE HIT IS NOT A MEASUREMENT: the agent's ShellOvnNbApplier
    # short-circuits byte-identical replays from a local cache, fabricating a
    # fully-applied observation with a fresh timestamp having EXECUTED NOTHING
    # — its own contract says a consumer must not read that as evidence the NB
    # DB is reachable now (ovn_nb_applier.go, CacheHit). So a cache-hit
    # observation here clears no failing entry and never readopts. The cache
    # is only ever seeded by a completed successful replay in the same agent
    # process, so it IS accepted as the historical positive that opens a first
    # bootstrapping → active (nothing failing, nothing contradicted). Because
    # a cache-hitting chassis gives no fresh coverage, the probe runs on
    # cache-hit heartbeats exactly as on observation-less ones — that is what
    # catches a NB DB that dies while the plan is unchanged. An ssl:/unix:
    # endpoint the probe cannot speak remains the stated blind spot: the
    # deployment holds its last measured state and the health sensor surfaces
    # the staleness rather than anyone guessing.
    class DeploymentReconciler
      PROBE_SOURCE = "nb_probe"

      class << self
        # Never raises: this runs inside the heartbeat request and telemetry
        # ingest must not bounce on a reconcile bug. Transitions and stamps
        # are best-effort; the next heartbeat retries with fresh evidence.
        def reconcile!(instance:, nb_observation: nil)
          return if instance.nil? || instance.network_profile != "heavyweight"

          deployment = ::Sdwan::OvnDeployment.for_account(instance.account).first
          return if deployment.nil?

          observed  = normalize_observation(nb_observation, deployment)
          cache_hit = observed ? observed["cache_hit"].present? : false

          # The probe covers the two windows in which the chassis measured
          # nothing this tick: no meaningful observation at all, and a
          # cache-hit replay (which executed nothing). It does socket I/O, up
          # to its timeout, so it runs OUTSIDE the row lock below.
          probe_result = (observed.nil? || cache_hit) ? probe_safely(deployment) : nil

          # Concurrent heartbeats read-modify-write nb_observed["failing"];
          # the lock keeps one chassis's entry from clobbering another's.
          deployment.with_lock do
            begin_bootstrap(deployment)

            failing = (deployment.nb_observed || {}).fetch("failing", {}).deep_dup
            last    = (deployment.nb_observed || {})["last"]

            sweep_dead_chassis!(failing)

            # fresh_positive: the NB DB was positively MEASURED this pass (an
            # executed full replay, or a probe confirmation). historical_
            # positive: a cache-hit full success — proof of an executed replay
            # earlier in the agent process, not of reachability now.
            fresh_positive      = false
            historical_positive = false

            if observed
              last = observed.merge("instance_id" => instance.id,
                                    "observed_at" => Time.current.utc.iso8601)
              if cache_hit
                # Executed nothing: clears no failing entry, decides nothing
                # beyond the first activation. The probe (above) owns the
                # "is it reachable NOW" question this tick.
                historical_positive = full_success?(observed)
              elsif full_success?(observed)
                fresh_positive = true
                failing.delete(instance.id)
                # Direct positive from the consumer supersedes the control-plane
                # probe's indirect negative — same subject, better vantage.
                failing.delete(PROBE_SOURCE)
              else
                failing[instance.id] = {
                  "error"       => observed["last_error"].presence || partial_replay_error(observed),
                  "source"      => "chassis_replay",
                  "observed_at" => Time.current.utc.iso8601
                }
              end
            end

            if probe_result
              fresh_positive = true if apply_probe_verdict(probe_result, failing)
            end

            persist_observation!(deployment, last: last, failing: failing)
            transition!(deployment, fresh_positive: fresh_positive,
                                    historical_positive: historical_positive,
                                    failing: failing)
          end
        rescue StandardError => e
          Rails.logger.warn(
            "[Sdwan::Ovn::DeploymentReconciler] reconcile failed for instance #{instance&.id}: " \
            "#{e.class}: #{e.message}"
          )
          nil
        end

        private

        # pending → bootstrapping the moment both endpoints are asserted.
        # Model validations require the endpoints to leave pending, so a
        # blank-endpoint row simply stays pending (and the health sensor
        # says so).
        def begin_bootstrap(deployment)
          return unless deployment.pending?
          return if deployment.nb_db_endpoint.blank? || deployment.sb_db_endpoint.blank?

          deployment.start_bootstrap!
        end

        # A meaningful observation is one where the applier EXECUTED against
        # this deployment: plan_commands > 0 and the ids match. The agent's
        # empty-plan branch returns a populated-but-hollow struct having run
        # nothing — see Manager.Reconcile's forget() — and an id mismatch is
        # a stale agent talking about a row that no longer exists.
        def normalize_observation(raw, deployment)
          return nil unless raw.is_a?(Hash)

          obs = raw.stringify_keys
          return nil unless obs["deployment_id"].to_s == deployment.id.to_s
          return nil unless obs["plan_commands"].to_i.positive?

          obs.slice("deployment_id", "nb_db_endpoint", "plan_commands",
                    "applied_commands", "compiled_at", "last_replay_at",
                    "last_error", "cache_hit")
        end

        def full_success?(obs)
          obs["applied_commands"].to_i == obs["plan_commands"].to_i &&
            obs["last_error"].blank?
        end

        def partial_replay_error(obs)
          "partial replay: #{obs['applied_commands'].to_i}/#{obs['plan_commands'].to_i} commands applied"
        end

        # The probe runs only on heartbeats where the chassis measured nothing
        # (no meaningful observation, or a cache-hit replay) — when a chassis
        # EXECUTED, its verdict decides and a probe disagreement would just
        # flap against it. Returns nil when the probe itself broke: a broken
        # probe is NOT a measured failure of the deployment.
        def probe_safely(deployment)
          ::Sdwan::Ovn::NbProbe.probe_cached(deployment)
        rescue StandardError => e
          Rails.logger.warn(
            "[Sdwan::Ovn::DeploymentReconciler] NB probe errored for deployment #{deployment.id}: " \
            "#{e.class}: #{e.message}"
          )
          nil
        end

        # Folds a probe verdict into the failing map. Returns true only on a
        # confirmed verdict (a positive observation).
        def apply_probe_verdict(result, failing)
          if result.confirmed?
            failing.delete(PROBE_SOURCE)
            return true
          end

          if result.failed?
            failing[PROBE_SOURCE] = {
              "error"       => result.error,
              "source"      => PROBE_SOURCE,
              "observed_at" => result.probed_at.utc.iso8601
            }
          end
          # :not_measured — we could not look; touch nothing.
          false
        end

        # A failing entry whose chassis row was DELETED is swept: its subject
        # is positively gone (mirrors the agent's forget()). Sweeping is not
        # an observation — the deployment readopts only when a positive
        # observation later finds nothing failing.
        def sweep_dead_chassis!(failing)
          chassis_ids = failing.keys - [ PROBE_SOURCE ]
          return if chassis_ids.empty?

          live = ::System::NodeInstance.where(id: chassis_ids).pluck(:id).map(&:to_s)
          (chassis_ids - live).each { |gone| failing.delete(gone) }
        end

        # Observation stamps go through update_columns, deliberately skipping
        # updated_at: TopologyCompiler.ovn_nb_plan_cache_key folds
        # deployment.updated_at, so a per-heartbeat stamp would recompile the
        # NB plan for the whole account every 30 seconds. Transitions (below)
        # use the AASM events and DO bump updated_at — going active must
        # invalidate the served plan.
        def persist_observation!(deployment, last:, failing:)
          nb_observed = {}
          nb_observed["last"]    = last if last.present?
          nb_observed["failing"] = failing if failing.present?

          return if deployment.nb_observed == nb_observed

          deployment.update_columns(nb_observed: nb_observed)
        end

        def transition!(deployment, fresh_positive:, historical_positive:, failing:)
          if failing.present?
            deployment.mark_degraded! if deployment.active?
            return
          end

          case deployment.status
          when "bootstrapping"
            # A first activation accepts the historical positive: the applier's
            # cache is only ever seeded by an executed full replay, and with
            # nothing failing there is no fresh negative it could override.
            deployment.mark_active! if fresh_positive || historical_positive
          when "degraded"
            # Leaving degraded demands a FRESH measurement — a cache-hit
            # re-assertion predates whatever caused the degradation.
            deployment.readopt! if fresh_positive
          end
        end
      end
    end
  end
end
