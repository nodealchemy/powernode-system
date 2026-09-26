# frozen_string_literal: true

module System
  # Ingests the agent's PendingModuleDigests heartbeat lane (N4, review
  # round 11 of IMP-caef5c00d63f's in-place-upgrade redesign).
  #
  # agent/internal/runtime/service.go's HeartbeatPayload has carried
  # `pending_module_digests` (map[string]string, module id -> the digest an
  # in-place upgrade is currently mid-way toward — see mount.Module.
  # PendingDigest's own doc) since M9 (round 9), surfacing a module whose
  # upgrade attempt failed partway (a restart failure, a settle-check crash)
  # and is being retried/backed-off/reverted per N2 — and nothing on the
  # server read it: the SAME "answerable but never asked" shape
  # BootLkgStateWriter and SecurityFailClosedSensor closed for their own
  # lanes. A module stuck retrying the same digest for an extended stretch
  # is real, node-visible state an operator cannot currently see anywhere.
  #
  # UNLIKE the sibling writers (BootLkgStateWriter, RuntimeMetricsWriter),
  # this lane needs CROSS-HEARTBEAT MEMORY: the wire carries only the
  # CURRENT map, no "since when" — the agent's own PendingDigestLastAttemptUnix
  # is per-digest retry-backoff bookkeeping, not "since this module first
  # became stuck", and is not on the wire at all. So this writer tracks,
  # per module id, the SERVER'S OWN first-observed timestamp: carried
  # forward across heartbeats for as long as the SAME digest keeps being
  # reported pending, reset to "now" the moment the pending digest CHANGES
  # (a revert, or a re-target to a third digest — see N2), and DROPPED the
  # moment a module stops being reported pending at all (resolved, one way
  # or another). PendingDigestStuckSensor reads first_seen_at to decide
  # whether a module has been stuck long enough to alert on.
  #
  # ACCEPTED SIMPLIFICATION: the merge base is `instance.config` as loaded
  # at the top of this request, not a fresh read at write time. Heartbeats
  # from ONE instance are not genuinely concurrent in practice (one agent
  # process, one heartbeat call at a time), so the risk this accepts is a
  # rare, harmless double-reset of first_seen_at — never a false "resolved"
  # (a module the fresh report still names is never dropped) and never a
  # fabricated stuck duration (resetting can only make a module look LESS
  # stuck, not more). BootLkgStateWriter's own guarded-UPDATE idiom protects
  # against clobbering OTHER writers' keys, which this shares; it does not
  # protect a writer's OWN key against itself, which is what would be needed
  # to close this gap, and is not worth the extra query for a duration
  # estimate that already fails safe in the one direction that matters.
  class PendingModuleDigestsWriter
    CONFIG_KEY = "pending_module_digests"

    # The single top-level key the controller slices out of the heartbeat.
    # Not a flat list of scalars like the sibling writers — the whole value
    # is one nested map — but the same slice-then-write! call shape.
    WIRE_KEYS = %w[pending_module_digests].freeze

    MAX_TRACKED_MODULES  = 200
    MAX_IDENTIFIER_CHARS = ::System::IdentifierCaps::MAX_IDENTIFIER_CHARS

    class << self
      # Returns the persisted document, or nil when nothing changed and no
      # write was needed (both the fresh report and the stored document are
      # empty).
      def write!(instance:, payload:)
        return nil if instance.nil?

        reported = extract(payload)
        previous = previous_modules(instance)
        modules = merge(reported, previous)

        return nil if reported.empty? && previous.empty?

        document = { "observed_at" => Time.current.utc.iso8601, "modules" => modules }
        merge_config_key!(instance, document)
        document
      end

      private

      # module_id => digest, string-keyed, capped, and dropping any entry
      # whose digest is blank (an agent should never send one, but a blank
      # digest is not a fact worth tracking as "pending").
      def extract(payload)
        raw = payload.respond_to?(:key?) ? (payload[:pending_module_digests] || payload["pending_module_digests"]) : nil
        return {} unless raw.is_a?(Hash)

        raw.to_h.first(MAX_TRACKED_MODULES).each_with_object({}) do |(module_id, digest), out|
          id = identifier(module_id)
          val = identifier(digest)
          next if id.blank? || val.blank?

          out[id] = val
        end
      end

      def previous_modules(instance)
        document = instance.config.is_a?(Hash) ? instance.config[CONFIG_KEY] : nil
        modules = document.is_a?(Hash) ? document["modules"] : nil
        modules.is_a?(Hash) ? modules : {}
      end

      # Carries forward first_seen_at for a module id whose reported digest
      # is UNCHANGED from the previous document; stamps "now" for a module
      # id that is new, or whose reported digest CHANGED (a revert or a
      # re-target — N2 — starts the clock over, since it is a different
      # stuck-ness question). A module id the fresh report no longer names
      # is dropped entirely — resolved, not stuck.
      def merge(reported, previous)
        now = Time.current.utc.iso8601
        reported.each_with_object({}) do |(module_id, digest), out|
          prior = previous[module_id]
          first_seen = if prior.is_a?(Hash) && prior["digest"] == digest
            prior["first_seen_at"].presence || now
          else
            now
          end
          out[module_id] = { "digest" => digest, "first_seen_at" => first_seen }
        end
      end

      def identifier(raw)
        return nil if raw.nil?

        value = raw.to_s
        return nil if value.empty?

        value.length > MAX_IDENTIFIER_CHARS ? value[0, MAX_IDENTIFIER_CHARS] : value
      end

      # Same guarded-UPDATE idiom as the sibling writers — sets ONE top-level
      # config key without reading (and so without risking clobbering) the
      # rest of the shared document.
      def merge_config_key!(instance, document)
        ::System::NodeInstance
          .where(id: instance.id)
          .update_all([
            "config = jsonb_set(COALESCE(config, '{}'::jsonb), ARRAY[?], ?::jsonb, true)",
            CONFIG_KEY, document.to_json
          ]).positive?
      end
    end
  end
end
