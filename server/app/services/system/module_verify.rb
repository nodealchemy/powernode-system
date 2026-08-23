# frozen_string_literal: true

module System
  # IMP-3855ff9908f2 — the `verify:` manifest probe block: the platform's
  # "node N now provides capability C" primitive.
  #
  # == The defect this closes
  #
  # A module deploy proves only that the platform SERVED an artifact and that
  # the agent MOUNTED it. Nothing on either side asks whether the thing the
  # module exists to provide is actually reachable afterwards. Two shipped
  # incidents are exactly this shape:
  #
  #   * gitleaks v4 (2026-08-07) published an EMPTY artifact, auto-promoted,
  #     and the agent's hot-prune whiteout-deleted /usr/local/bin/gitleaks off
  #     a live root. Digests matched end to end. The deploy looked clean.
  #   * VM-9000: a binary was SHADOWED — an earlier PATH entry answered the
  #     name. An existence check ("is there a `foo` on PATH?") PASSED while
  #     the node was broken, because something was there; it was the wrong
  #     something.
  #
  # == The two clauses that are the whole point
  #
  # Both come from docs/operations/autonomous-infrastructure-readiness-
  # 2026-08-12.md §2, where the design was ratified and left unbuilt:
  #
  #   1. A `command` probe asserts RESOLVES_TO — the resolved path — never
  #      mere existence. `resolves_to` is REQUIRED (see
  #      ManifestImportService#validate_verify): a probe that cannot say
  #      WHICH file must answer the name is the existence check that already
  #      passed while the thing was broken, and this platform will not import
  #      one. For the same reason `command` must be a BARE NAME: a probe that
  #      names an absolute path resolves that path, not the PATH lookup, and
  #      so cannot see a shadow at all.
  #
  #   2. Every probe runs in BOTH a login and a non-login shell, and a probe
  #      is PASSING only when BOTH agree with `resolves_to`. This is not a
  #      tunable — there is deliberately no `shells:` key, because the
  #      VM-9000 bug was precisely a divergence between the two (login shells
  #      source /etc/profile[.d] and ~/.bash_profile, which is where a PATH
  #      gets reordered). A probe that ran one shell would REPRODUCE that bug
  #      rather than catch it. The server enforces the same rule on ingest:
  #      System::ModuleVerifyStateWriter refuses to score a probe as passing
  #      unless the report covers both shells, so an older or lazier agent
  #      produces "not measured", never a false green.
  #
  # == Manifest shape (optional; absent means exactly today's behaviour)
  #
  #   verify:
  #     probes:
  #       - name: gitleaks-binary
  #         command: gitleaks               # bare name — resolved through PATH
  #         resolves_to: /usr/local/bin/gitleaks
  #
  # == Where it lives, and why there is no new column
  #
  # ManifestImportService mirrors the block onto NodeModule#config, which
  # NodeModuleNodeApiSerializer#serialize_module_full already ships to the
  # agent verbatim as `config`. The agent reads config["verify"] off the
  # manifest it already caches. No migration, no serializer change, and no
  # second copy of the declaration to drift.
  class ModuleVerify
    # Manifest key, mirrored onto NodeModule#config by ManifestImportService.
    DECLARATION_KEY = "verify"

    # The two shells every probe runs in. A CONSTANT, not a manifest field —
    # see clause 2 above. Consumers (the writer, the sensor, the agent's
    # internal/probe package) all key on these exact strings.
    LOGIN_SHELL     = "login"
    NON_LOGIN_SHELL = "non_login"
    REQUIRED_SHELLS = [ LOGIN_SHELL, NON_LOGIN_SHELL ].freeze

    # Bounded so one manifest cannot make every heartbeat on the fleet run an
    # unbounded number of subshells.
    MAX_PROBES = 32

    # A probe NAME is an identifier: it is concatenated into the sensor's
    # signal fingerprint, which becomes a RemediationOutcome key.
    NAME_RX = /\A[a-z0-9][a-z0-9._-]{0,63}\z/

    # A BARE command name. No slash (an absolute path defeats the PATH
    # resolution the probe exists to exercise), no whitespace, and no shell
    # metacharacter — the string is interpolated into a shell word on the
    # node, so this is a hard boundary, not a style rule.
    COMMAND_RX = /\A[A-Za-z0-9][A-Za-z0-9._+-]{0,127}\z/

    # An absolute path with no shell metacharacters and no traversal. `..`
    # is rejected because the comparison is a STRING equality against what
    # the node resolved; a path that is not already canonical could never
    # match and would fail every probe for a reason the author cannot see.
    RESOLVES_TO_RX = %r{\A/[A-Za-z0-9._+\-/]{1,255}\z}

    PROBE_KNOWN_KEYS = %w[name command resolves_to].freeze

    Probe = Struct.new(:name, :command, :resolves_to, keyword_init: true) do
      def to_h
        { "name" => name, "command" => command, "resolves_to" => resolves_to }
      end
    end

    class << self
      # Parses NodeModule#config into normalized probes. Pure: no DB, no
      # writes. Anything malformed is DROPPED rather than raised — the
      # manifest validator (ManifestImportService#validate_verify) is the
      # gate that rejects a bad declaration, and it does so at validation
      # time so CI catches it. A survivor here is corrupt data, and dropping
      # it fails closed: the module declares no probe, so nothing claims it
      # was verified. It never fails OPEN into "verified with no evidence".
      def probes(node_module)
        raw = node_module&.config.is_a?(Hash) ? node_module.config[DECLARATION_KEY] : nil
        probes_from(raw)
      end

      # Same parse, from a raw block — used by the manifest validator's
      # round-trip spec and by callers holding a manifest rather than a row.
      def probes_from(raw)
        return [] unless raw.is_a?(Hash)

        entries = raw["probes"] || raw[:probes]
        return [] unless entries.is_a?(Array)

        seen = Set.new
        entries.first(MAX_PROBES).filter_map do |entry|
          probe = normalize(entry)
          next if probe.nil?
          next if seen.include?(probe.name)

          seen << probe.name
          probe
        end
      end

      # True when ANY of the account's modules declares a probe. The sensor
      # uses this to tell "this fleet has nothing to verify" (silence is
      # correct) from "this fleet has probes and no report" (not measured).
      def declared?(node_module)
        probes(node_module).any?
      end

      private

      def normalize(entry)
        return nil unless entry.respond_to?(:[])

        name        = fetch(entry, "name").to_s
        command     = fetch(entry, "command").to_s
        resolves_to = fetch(entry, "resolves_to").to_s

        return nil unless name.match?(NAME_RX)
        return nil unless command.match?(COMMAND_RX)
        # The load-bearing drop. A probe with no resolved-path assertion is an
        # EXISTENCE check, which is the check that passed while VM-9000 was
        # broken. It is not a weaker probe; it is the bug. Never admitted.
        return nil unless resolves_to.match?(RESOLVES_TO_RX)
        return nil if resolves_to.split("/").include?("..")

        Probe.new(name: name, command: command, resolves_to: resolves_to)
      end

      def fetch(entry, key)
        value = entry[key]
        value.nil? ? entry[key.to_sym] : value
      rescue TypeError, NoMethodError
        nil
      end
    end
  end
end
