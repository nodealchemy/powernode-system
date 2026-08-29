# frozen_string_literal: true

# IMP-da1b772c2596 — ingest for the agent's SDWAN APPLY observation.
#
# The compile pipeline (Sdwan::TopologyCompiler and friends) can only prove
# the platform SERVED a config. Whether the kernel ACCEPTED it is known on the
# node and nowhere else, and the agent has been reporting it on every
# heartbeat as `sdwan_state` — a key that, until this class, ZERO server code
# read. A node whose nftables/vrf/bridge apply failed every tick was therefore
# indistinguishable from one that applied cleanly: "served" scored as
# "applied".
#
# WIRE SHAPE (agent/internal/sdwan/state.go, embedded by
# runtime.HeartbeatPayload#SdwanState as the top-level `sdwan_state` array):
#
#   HeartbeatStatus  — one entry PER WG INTERFACE / network
#     interface, network_id, peer_count,
#     healthy_peers      (*int — JSON null means NOT MEASURED, see below),
#     last_reconcile_at, last_error,
#     subsystem_states[] — SubsystemStatus:
#       subsystem, scope, state ("ok" | "error"), message, observed_at
#
# THREE absences the persisted shape keeps distinguishable, because collapsing
# any of them into a healthy-looking value is the exact false green this lane
# exists to end:
#
#   1. NO `sdwan_state` KEY AT ALL. Nothing is written — the instance keeps
#      no sdwan_state document, which the sensor reads as "never reported".
#      A host with zero desired networks emits no entries (the omitempty
#      PAYLOAD-SHAPE LIMIT documented on HeartbeatStatus), so silence here is
#      "nothing observable on this host", never "SDWAN healthy".
#   2. NO `subsystem_states`. A pre-28460bbb agent — which is what much of
#      the deployed fleet still runs — sends network entries with no applier
#      outcomes at all. Recorded as `subsystems_reported => false` so the
#      empty list can never be misread as "nothing failed".
#   3. NO `healthy_peers`. The pointer is nil precisely so a consumer can
#      tell "we did not look" from a measured zero. Recorded as
#      `healthy_peers_measured => false` with `healthy_peers => nil`; it is
#      NEVER defaulted to 0.
#
# A state string that is neither "ok" nor "error" becomes "unknown", never
# "ok" — an unrecognized value is unmeasured, not success.
module Sdwan
  class AgentApplyStateWriter
    # Where the document lands on System::NodeInstance#config. A jsonb column
    # rather than a dedicated one deliberately: this is per-tick telemetry
    # whose shape follows the agent's wire format, and adding a column would
    # put a migration in front of a consumer-side fix. The write below touches
    # ONLY this key, so it cannot clobber the config store_accessors.
    CONFIG_KEY = "sdwan_state"

    # Caps. The payload is attacker-adjacent (it arrives from a node, and a
    # compromised or simply buggy agent can make it as large as it likes) and
    # it lands in a jsonb column that is read on every sense pass.
    MAX_NETWORKS               = 64
    MAX_SUBSYSTEMS_PER_NETWORK = 128
    MAX_MESSAGE_CHARS          = 500
    # Identifiers are capped far shorter than messages, and separately,
    # because `subsystem` and `scope` are concatenated into the sensor's
    # SIGNAL FINGERPRINT — which becomes a RemediationOutcome key. An
    # uncapped identifier there is unbounded growth in a second table, not
    # just in this column.
    MAX_IDENTIFIER_CHARS       = ::System::IdentifierCaps::MAX_IDENTIFIER_CHARS

    OK      = "ok"
    ERROR   = "error"
    UNKNOWN = "unknown"

    class << self
      # Returns the persisted document, or nil when the heartbeat carried no
      # block at all (in which case NOTHING is written — see absence case 1).
      def write!(instance:, payload:)
        return nil if instance.nil? || payload.nil?

        document = {
          "observed_at" => Time.current.utc.iso8601,
          "networks"    => normalize_networks(payload)
        }
        merge_config_key!(instance, document)
        document
      end

      private

      def normalize_networks(payload)
        entries = payload.is_a?(Array) ? payload : [ payload ]
        entries
          .select { |e| e.respond_to?(:key?) }
          .first(MAX_NETWORKS)
          .map { |entry| normalize_network(entry) }
      end

      def normalize_network(entry)
        # Read through [] rather than converting: the element may be a
        # symbol-keyed hash from an internal caller or a string-keyed one from
        # the heartbeat body, and both arms below cover either.
        raw_subsystems = entry[:subsystem_states] || entry["subsystem_states"]
        subsystems     = normalize_subsystems(raw_subsystems)
        # TRUE only when the agent sent a NON-EMPTY list AND every element of
        # it survived normalization. Deriving it from `is_a?(Array)` alone
        # fails in the GREEN direction: a list whose elements were all
        # unreadable (or an explicitly empty one, which the producer's
        # `omitempty` never emits) would record "reported" with nothing in
        # it, and the sensor would score that as measured-and-clean.
        # Compared against the CAPPED length, not the raw one: otherwise an
        # agent that sends more than MAX_SUBSYSTEMS_PER_NETWORK entries flips
        # `reported` to false and the whole instance drops into the
        # not-measured lane — which would let a hostile agent HIDE a real
        # failure by padding its list.
        reported       = raw_subsystems.is_a?(Array) && raw_subsystems.any? &&
                         subsystems.size == [ raw_subsystems.size, MAX_SUBSYSTEMS_PER_NETWORK ].min
        healthy_peers  = integer_or_nil(fetch(entry, :healthy_peers))

        {
          "network_id"        => identifier(fetch(entry, :network_id)),
          "interface"         => identifier(fetch(entry, :interface)),
          "peer_count"        => integer_or_nil(fetch(entry, :peer_count)),
          # nil, and its own explicit boolean, so no reader has to infer
          # "unmeasured" from a value that could also be a real zero.
          "healthy_peers"          => healthy_peers,
          "healthy_peers_measured" => !healthy_peers.nil?,
          # The AGENT's own clock for its last completed reconcile pass. This
          # is the sensor's freshness oracle — `observed_at` above is only
          # when the report REACHED us, and a wedged reconciler keeps
          # re-shipping a frozen snapshot that the server would otherwise
          # re-stamp as fresh on every tick.
          "last_reconcile_at" => identifier(fetch(entry, :last_reconcile_at)),
          "last_error"        => truncate(string_or_nil(fetch(entry, :last_error))),
          # FALSE means the agent told us nothing about its appliers — the
          # pre-28460bbb shape. It must never read as "nothing failed".
          "subsystems_reported" => reported,
          "subsystems"          => subsystems
        }
      end

      def normalize_subsystems(raw)
        return [] unless raw.is_a?(Array)

        raw
          .select { |s| s.respond_to?(:key?) }
          .first(MAX_SUBSYSTEMS_PER_NETWORK)
          .map do |s|
            name = identifier(fetch(s, :subsystem))
            # A nameless entry is KEPT, under a name that says so. Dropping
            # it would shrink the list silently, and (before the
            # `subsystems_reported` derivation above) let a network whose
            # every entry was nameless read as measured with nothing wrong.
            name = "unnamed" if name.blank?

            {
              "subsystem"   => name,
              "scope"       => identifier(fetch(s, :scope)).to_s,
              "state"       => normalize_state(fetch(s, :state)),
              "message"     => truncate(string_or_nil(fetch(s, :message))).to_s,
              "observed_at" => identifier(fetch(s, :observed_at))
            }
          end
      end

      # Only the two states the producer declares are recognized. Anything
      # else is UNKNOWN — an unparseable outcome is an unmeasured one, and
      # defaulting it to "ok" would let a wire-format change silently paint
      # every node green.
      def normalize_state(raw)
        case raw.to_s
        when OK    then OK
        when ERROR then ERROR
        else UNKNOWN
        end
      end

      def fetch(entry, key)
        entry[key].nil? ? entry[key.to_s] : entry[key]
      end

      def string_or_nil(raw)
        return nil if raw.nil?

        raw.to_s
      end

      def integer_or_nil(raw)
        return nil if raw.nil? || raw.to_s.strip.empty?
        return nil unless raw.to_s.match?(/\A-?\d+\z/)

        raw.to_i
      end

      # Every string that is an IDENTIFIER rather than prose — and every
      # timestamp, which is parsed not displayed.
      def identifier(raw)
        return nil if raw.nil?

        value = raw.to_s
        value.length > MAX_IDENTIFIER_CHARS ? value[0, MAX_IDENTIFIER_CHARS] : value
      end

      def truncate(raw)
        return nil if raw.nil?

        raw.length > MAX_MESSAGE_CHARS ? raw[0, MAX_MESSAGE_CHARS] : raw
      end

      # Sets ONE top-level key without reading the rest of the document
      # first. `config` is written from several request cycles (the operator
      # API, the status report endpoint, the cloud_instance_id store
      # accessors), and a read-modify-write of the whole jsonb from this
      # per-tick path would silently erase whatever another writer put there
      # in the interval. Same idiom as Sdwan::MultiIbgpHostFlagger.merge_key!.
      def merge_config_key!(instance, document)
        ::System::NodeInstance.where(id: instance.id).update_all([
          "config = jsonb_set(COALESCE(config, '{}'::jsonb), ARRAY[?], ?::jsonb, true)",
          CONFIG_KEY, document.to_json
        ])
      end
    end
  end
end
