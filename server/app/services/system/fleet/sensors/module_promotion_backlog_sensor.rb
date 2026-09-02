# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # Asserts STATE CONVERGENCE between what a module has built and what the
      # fleet actually runs, and alarms when they diverge for longer than a lag
      # budget.
      #
      # WHY THIS ASSERTS STATE AND NOT EVENTS. The failure this exists to catch
      # is SILENCE. On 2026-08-25 the core-drift promote gate withheld several
      # versions with a (bogus) provenance mismatch, then stopped emitting
      # `system.module_promotion_withheld` entirely — and promotion still did
      # not happen. An operator checking "was anything declined?" saw nothing
      # and concluded all was well. So the natural detector is precisely the one
      # that already failed: absence of a refusal is not evidence of a pass (see
      # the same lesson in ModuleVerifyFailedSensor's unmeasured accounting).
      #
      # Therefore: withheld/deferred events may ANNOTATE this signal, but they
      # can never CLEAR it. The only thing that clears this alarm is
      # `NodeModule#current_version_id` actually moving.
      #
      # WHAT "RUNS" MEANS. `NodeModuleVersion#promotion_state` is NOT read here
      # and must not be. Actuation is `NodeModule#current_version_id`, whose
      # SANCTIONED writer is `NodeModule#promote_to_version!` — sanctioned, not
      # sole: this comment used to quote that method's own "the platform's ONLY
      # choke point" claim, which was false. Six sites write the column; see
      # spec/lint/node_module_current_version_write_seam_spec.rb. That does not
      # weaken this sensor — it reads the COLUMN, so it sees every writer — but
      # it does mean a backlog can be cleared by something that ran no promotion
      # guard at all. The
      # built -> staging -> blessed -> live ladder is a separate track that
      # writes nothing the agents materialize; a version can sit at ladder-live
      # while the fleet runs something else entirely, and several versions of
      # one module can be ladder-live at once. Reading promotion_state here
      # would reproduce exactly the misreading this sensor exists to prevent.
      #
      # SCOPE. Only versions NEWER than current can constitute a backlog, so the
      # scan is bounded by the backlog itself rather than by version history —
      # a module whose newest build is current does one indexed comparison.
      class ModulePromotionBacklogSensor < BaseSensor
        # How long a newer usable version may exist without becoming current
        # before that counts as a stall rather than normal in-flight delay.
        # A publish-to-current transition is ordinarily seconds; an hour is
        # generous enough that a slow build/publish/notify chain cannot alarm.
        DEFAULT_LAG_SECONDS = 3600

        SETTING_PREFIX         = "system.module_promotion_backlog"
        ACCOUNT_SETTING_PREFIX = "module_promotion_backlog"

        def sense
          ::System::NodeModule
            .where(account_id: account.id)
            .includes(:current_version)
            .find_each
            .filter_map { |node_module| evaluate(node_module) }
        end

        private

        def evaluate(node_module)
          candidate = newest_usable_ahead_of_current(node_module)
          return nil if candidate.nil?

          lag = Time.current - candidate.created_at
          return nil if lag < lag_seconds

          signal(
            kind: "system.module_promotion_stalled",
            severity: :high,
            payload: stalled_payload(node_module, candidate, lag),
            # Keyed on the CANDIDATE, not just the module: a newer stalled build
            # is a new fact and must alarm again rather than being deduped into
            # the previous one. Re-alarming on the same candidate is suppressed
            # by the DecisionEngine's fingerprint dedup.
            fingerprint: "promotion_stalled:#{node_module.id}:#{candidate.id}"
          )
        end

        # The newest version that is BOTH usable and ahead of what runs today.
        # `rollback_usable?` is the same admission test the rollback path uses:
        # it requires a recorded oci_digest and a promotable size, so a
        # half-published or empty artifact never counts as a backlog item and
        # cannot raise a stall the fleet could not act on anyway.
        def newest_usable_ahead_of_current(node_module)
          scope = node_module.versions.ordered
          current = node_module.current_version
          scope = scope.where("version_number > ?", current.version_number) if current

          scope.detect(&:rollback_usable?)
        end

        def stalled_payload(node_module, candidate, lag)
          {
            module_id: node_module.id,
            module_name: node_module.name,
            current_version_id: node_module.current_version_id,
            current_version_number: node_module.current_version_number,
            candidate_version_id: candidate.id,
            candidate_version_number: candidate.version_number,
            candidate_oci_digest: digest_of(candidate),
            lag_seconds: lag.round,
            lag_budget_seconds: lag_seconds,
            # ANNOTATION ONLY. Present so an operator sees why a stall may be
            # deliberate; deliberately NOT consulted above, because a gate that
            # stops emitting is the exact failure mode this sensor covers.
            last_withheld_reason: last_withheld_reason(candidate),
            fingerprint: "promotion_stalled:#{node_module.id}:#{candidate.id}",
            remediation_action: nil
          }
        end

        # Same defensive read as NodeModuleVersion#rollback_usable?: `artifact`
        # is a jsonb blob whose keys may arrive string- or symbol-shaped.
        def digest_of(version)
          data = version.artifact
          return nil if data.blank?

          data["oci_digest"] || data[:oci_digest]
        end

        def last_withheld_reason(candidate)
          ::System::FleetEvent
            .where(account_id: account.id,
                   kind: "system.module_promotion_withheld",
                   node_module_version_id: candidate.id)
            .order(emitted_at: :desc)
            .limit(1)
            .pick(:payload)
            &.dig("reason")
        rescue StandardError
          # Annotation must never be able to suppress the alarm it annotates.
          nil
        end

        def lag_seconds
          @lag_seconds ||= begin
            raw = account.settings&.dig("#{ACCOUNT_SETTING_PREFIX}_lag_seconds").presence ||
                  ::SiteSetting.get("#{SETTING_PREFIX}.lag_seconds")
            value = raw.to_i
            value.positive? ? value : DEFAULT_LAG_SECONDS
          end
        end
      end
    end
  end
end
