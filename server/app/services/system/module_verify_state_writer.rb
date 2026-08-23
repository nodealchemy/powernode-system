# frozen_string_literal: true

module System
  # IMP-3855ff9908f2 — ingest for the agent's `verify:` PROBE observation.
  #
  # The platform can prove it SERVED a module artifact and the agent can prove
  # it MOUNTED one. Neither answers the only question a deploy is for: is the
  # thing the module exists to provide actually reachable on the node now? That
  # answer exists on the node and nowhere else. The agent computes it (see
  # agent/internal/probe) and reports it on the heartbeat as
  # `module_verify_state`; this class is what reads it.
  #
  # WIRE SHAPE (agent/internal/probe/report.go, embedded by
  # runtime.HeartbeatPayload#ModuleVerifyState as `module_verify_state`):
  #
  #   ModuleReport      — one entry PER ATTACHED MODULE that declares probes
  #     module_id, module_name, declared_count, observed_at,
  #     probes[] — ProbeReport:
  #       name, command, expected,
  #       shells[] — ShellResult:
  #         shell ("login" | "non_login"), status ("pass"|"fail"|"error"),
  #         resolved, message
  #
  # == THE ROLL-UP IS COMPUTED HERE, NOT TRUSTED FROM THE WIRE
  #
  # The agent reports per-shell FACTS; this class derives the probe's verdict.
  # That split is deliberate and it is where clause 2 of the settled design
  # (readiness map §2 — probes must run in BOTH login and non-login shells)
  # becomes enforceable rather than aspirational:
  #
  #   a probe is PASSING only when the report covers BOTH shells AND both
  #   agree with the declared path.
  #
  # A report naming one shell — an older agent, a partial run, a hostile one
  # trimming the failing half — yields `unknown`, never `pass`. If the roll-up
  # arrived pre-computed on the wire, an agent that only ran a login shell
  # would report `pass` and the platform would have reproduced the VM-9000
  # bug (an existence-shaped check that was green in one shell while the node
  # was broken in the other) inside the very lane built to catch it.
  #
  # THREE absences kept distinguishable, for the same reason
  # Sdwan::AgentApplyStateWriter keeps its three:
  #
  #   1. NO `module_verify_state` KEY. Nothing is written; the instance keeps
  #      no document, which the sensor reads as "never reported". A node whose
  #      modules declare no probes reports an EMPTY module list, which is a
  #      different fact and is recorded as one.
  #   2. NO `shells` for a probe, or only one of the two. Recorded as
  #      `shells_covered => false` with status `unknown`.
  #   3. A `status` string this platform does not recognize becomes `error`,
  #      never `pass` — an unparseable outcome is an unmeasured one.
  class ModuleVerifyStateWriter
    # Where the document lands on System::NodeInstance#config. A jsonb key
    # rather than a column, for the same reason the SDWAN apply state is one:
    # this is per-tick telemetry whose shape follows the agent's wire format,
    # and a migration in front of a consumer-side fix helps nobody.
    CONFIG_KEY = "module_verify_state"

    # Caps. The payload arrives from a node — a compromised or simply buggy
    # agent can make it as large as it likes — and lands in a jsonb column
    # read on every sense pass.
    MAX_MODULES          = 64
    MAX_PROBES_PER_MODULE = ::System::ModuleVerify::MAX_PROBES
    MAX_SHELLS_PER_PROBE  = 4
    MAX_MESSAGE_CHARS     = 500
    # Identifiers are capped shorter, and separately: `module_id` and probe
    # `name` are concatenated into the sensor's SIGNAL FINGERPRINT, which
    # becomes a RemediationOutcome key. An uncapped identifier there is
    # unbounded growth in a second table.
    MAX_IDENTIFIER_CHARS = 128
    MAX_PATH_CHARS       = 255

    PASS    = "pass"
    FAIL    = "fail"
    ERROR   = "error"
    UNKNOWN = "unknown"

    SHELL_STATUSES = [ PASS, FAIL, ERROR ].freeze

    class << self
      # Returns the persisted document, or nil when the heartbeat carried no
      # block at all (in which case NOTHING is written — absence case 1).
      def write!(instance:, payload:)
        return nil if instance.nil? || payload.nil?

        document = {
          "observed_at" => Time.current.utc.iso8601,
          "modules"     => normalize_modules(payload)
        }
        merge_config_key!(instance, document)
        document
      end

      private

      def normalize_modules(payload)
        entries = payload.is_a?(Array) ? payload : [ payload ]
        entries
          .select { |e| e.respond_to?(:key?) }
          .first(MAX_MODULES)
          .map { |entry| normalize_module(entry) }
      end

      def normalize_module(entry)
        raw_probes = fetch(entry, :probes)
        probes     = normalize_probes(raw_probes)

        {
          "module_id"   => identifier(fetch(entry, :module_id)),
          "module_name" => identifier(fetch(entry, :module_name)),
          # What the AGENT believed it was asked to run. Compared by the
          # sensor against the number of probes that actually reported: an
          # agent that declares 3 and reports 1 has not verified the module,
          # and the two probes it dropped must not vanish silently.
          "declared_count" => integer_or_nil(fetch(entry, :declared_count)),
          "reported_count" => probes.size,
          # The AGENT's own clock for when it last ran this module's probes.
          # The document's top-level `observed_at` is only when the report
          # REACHED us; an agent whose probe loop wedged keeps re-shipping a
          # frozen snapshot the server would otherwise re-stamp as fresh.
          "observed_at" => identifier(fetch(entry, :observed_at)),
          "probes"      => probes
        }
      end

      def normalize_probes(raw)
        return [] unless raw.is_a?(Array)

        raw
          .select { |p| p.respond_to?(:key?) }
          .first(MAX_PROBES_PER_MODULE)
          .map { |p| normalize_probe(p) }
      end

      def normalize_probe(raw)
        expected = path(fetch(raw, :expected)).to_s
        shells   = normalize_shells(fetch(raw, :shells), expected)
        covered = ::System::ModuleVerify::REQUIRED_SHELLS.all? do |required|
          shells.any? { |s| s["shell"] == required }
        end

        {
          # A nameless probe is KEPT, under a name that says so. Dropping it
          # would shrink the list silently and let a module whose every probe
          # was nameless read as reported-with-nothing-wrong.
          "name"     => identifier(fetch(raw, :name)).presence || "unnamed",
          "command"  => identifier(fetch(raw, :command)).to_s,
          # The path the MANIFEST demanded, echoed back by the agent so a
          # failure signal can show expected-vs-resolved without a second
          # lookup against a module row that may since have been updated.
          "expected" => expected,
          # Clause 2, enforced. FALSE means this probe cannot be scored as
          # passing no matter what its shells said.
          "shells_covered" => covered,
          "shells"         => shells,
          # DERIVED here, never read from the wire. See the class doc.
          "status"         => roll_up(shells, covered)
        }
      end

      # The cap is applied AFTER the known-name filter, deliberately. Capping
      # first lets a producer push the two real entries out of the window with
      # junk names — the probe then reads `shells_covered => false` and its
      # FAIL is downgraded to a medium not-measured aggregate. Filtering first
      # means unrecognized names cost nothing.
      def normalize_shells(raw, expected)
        return [] unless raw.is_a?(Array)

        seen = {}
        raw
          .select { |s| s.respond_to?(:key?) }
          .each do |s|
            break if seen.size >= MAX_SHELLS_PER_PROBE

            name = identifier(fetch(s, :shell)).to_s
            next unless ::System::ModuleVerify::REQUIRED_SHELLS.include?(name)
            # First report per shell wins. A duplicate entry for the same
            # shell is a producer bug; letting a later PASS overwrite an
            # earlier FAIL would be the one direction that hides a fault.
            next if seen.key?(name)

            resolved = path(fetch(s, :resolved)).to_s
            seen[name] = {
              "shell"    => name,
              # RE-DERIVED, not trusted. The agent ships both the path it
              # resolved and the path the manifest demanded, so a report of
              # `status: pass, resolved: /usr/bin/gh` against an expected
              # /usr/local/bin/gh is self-contradicting — and it is the exact
              # shape a compromised or buggy agent would send to hide a
              # shadow. Robustness against a producer that TRIMS the failing
              # half (which shells_covered already handles) is not robustness
              # against one that LIES about it.
              "status"   => shell_status(fetch(s, :status), resolved, expected),
              "resolved" => resolved,
              "message"  => truncate(string_or_nil(fetch(s, :message))).to_s
            }
          end
        ::System::ModuleVerify::REQUIRED_SHELLS.filter_map { |n| seen[n] }
      end

      # A claimed PASS is honoured only when the path the agent reports
      # resolving actually equals the path the manifest declared. A claimed
      # pass with a blank `resolved` is left alone: an older producer that
      # omits the field is unmeasured territory, and the roll-up already
      # refuses to call an incomplete report a pass.
      def shell_status(raw, resolved, expected)
        status = normalize_status(raw)
        return status unless status == PASS
        return status if resolved.blank? || expected.blank?

        resolved == expected ? PASS : FAIL
      end

      # PASS requires BOTH shells present AND both passing. Anything less is
      # UNKNOWN or FAIL — never PASS. This is the whole enforcement point.
      def roll_up(shells, covered)
        return FAIL if shells.any? { |s| s["status"] == FAIL }
        return UNKNOWN unless covered
        return UNKNOWN if shells.any? { |s| s["status"] != PASS }

        PASS
      end

      # Only the three statuses the producer declares are recognized.
      # Anything else is ERROR — an unparseable outcome is an unmeasured one,
      # and defaulting it to PASS would let a wire-format change silently
      # paint the fleet green.
      def normalize_status(raw)
        value = raw.to_s
        SHELL_STATUSES.include?(value) ? value : ERROR
      end

      def fetch(entry, key)
        entry[key].nil? ? entry[key.to_s] : entry[key]
      rescue TypeError, NoMethodError
        nil
      end

      def string_or_nil(raw)
        raw.nil? ? nil : raw.to_s
      end

      def integer_or_nil(raw)
        return nil if raw.nil? || raw.to_s.strip.empty?
        return nil unless raw.to_s.match?(/\A-?\d+\z/)

        raw.to_i
      end

      def identifier(raw)
        clamp(raw, MAX_IDENTIFIER_CHARS)
      end

      def path(raw)
        clamp(raw, MAX_PATH_CHARS)
      end

      def clamp(raw, limit)
        return nil if raw.nil?

        value = raw.to_s
        value.length > limit ? value[0, limit] : value
      end

      def truncate(raw)
        clamp(raw, MAX_MESSAGE_CHARS)
      end

      # Sets ONE top-level key without reading the rest of the document
      # first — `config` is written from several request cycles, and a
      # read-modify-write of the whole jsonb from this per-tick path would
      # silently erase whatever another writer put there in the interval.
      # Same idiom as Sdwan::AgentApplyStateWriter.merge_config_key!.
      def merge_config_key!(instance, document)
        ::System::NodeInstance.where(id: instance.id).update_all([
          "config = jsonb_set(COALESCE(config, '{}'::jsonb), ARRAY[?], ?::jsonb, true)",
          CONFIG_KEY, document.to_json
        ])
      end
    end
  end
end
