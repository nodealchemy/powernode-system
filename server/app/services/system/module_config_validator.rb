# frozen_string_literal: true

module System
  # Semantic validation for the blocks a module's `config` hash carries that a
  # CONSUMER acts on — extracted from ManifestImportService (IMP-7d4c691ffe91)
  # so the manifest-import path and the operator API's raw `config:` write
  # share ONE implementation.
  #
  # Why it had to be shared rather than re-stated: NodeModule#config is
  # writable wholesale through PATCH /api/v1/system/node_modules/:id, and that
  # write never passes through ManifestImportService. `config` is then
  # serialized VERBATIM to every node carrying the module
  # (NodeModuleNodeApiSerializer#serialize_module_full) and consumed on-node.
  # A second, hand-written set of checks on the API side is precisely how one
  # path ends up laxer than the other, which is the bug this closes.
  #
  # SCOPE — which config keys this validates, and why not the rest.
  # `config` is a shared bag with many producers:
  #
  #   manifest-derived (ManifestImportService#apply_to_module copies verbatim):
  #     restart_after_update  → System::RestartAfterUpdate            VALIDATED
  #     verify                → System::ModuleVerify + agent probe    VALIDATED
  #     security              → agent runtime/reconcile.go buildPolicy   VALIDATED
  #     skills, build, display_name, license, manifest_extras
  #   platform-written, never operator-authored:
  #     honeypot              → System::Honeypot::CanaryModuleService
  #     last_build            → System::ModuleBuildService
  #     reuse_check           → Ai::Tools::SystemFleetTool (update_columns)
  #   legitimately operator-tunable at runtime:
  #     module_promotion_required_count / module_promotion_dwell_minutes
  #                           → System::Fleet::PromotionCriteria (documented
  #                             per-module override cascade)      TYPE-CHECKED
  #     daemon_overrides      → System::DockerDaemonOverridesResolver   KEY-ALLOWLISTED
  #     resources             → node_api modules#resource
  #
  # Because that last group is deliberately operator-editable, the gate is a
  # SHAPE check on the semantic blocks, not a top-level key allowlist: an
  # allowlist would reject writes the platform documents as supported.
  #
  # ==========================================================================
  # SECURITY-BLOCK CONTRACT (IMP-01a02f4f75f4 and siblings — the write-side
  # seam the header above filed separately). This section is normative: the
  # G2 agent-side containment work (seccomp path-vs-set-name, MAC profile
  # containment, egress nft hygiene, privileged gating) binds to it.
  #
  # `config["security"]` is turned into a systemd confinement policy on every
  # node carrying the module (agent/internal/runtime/reconcile.go buildPolicy),
  # so it is validated on EVERY write path through this ONE implementation.
  # Keys it may carry — anything else is rejected (matching the manifest JSON
  # schema's additionalProperties: false):
  #
  #   capabilities     array of strings, each /\ACAP_[A-Z_]+\z/, max 64.
  #                    PRIVILEGED: each entry is a retained Linux capability
  #                    (CapabilityBoundingSet). Grammar is enforced here; the
  #                    grammar is also the injection barrier for the systemd
  #                    drop-in the agent renders. Gating high-risk caps
  #                    (CAP_SYS_ADMIN class) behind operator approval is G2's
  #                    apply-side decision, not a write-time rule.
  #   privileged       strictly boolean. PRIVILEGED: true disables ALL
  #                    confinement on-node. Deliberately still declarable at
  #                    write time (shipped dev-cell manifest declares it); the
  #                    operator-approval gate belongs at APPLY time and is
  #                    bound to G2.
  #   user_namespace   strictly boolean. Omitted defaults to TRUE on-node
  #                    (private userns isolation); an explicit false DROPS
  #                    that isolation and is therefore privileged-by-negation.
  #   seccomp_profile,
  #   apparmor_profile,
  #   selinux_profile  nil, or a bare profile NAME matching
  #                    /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/ — NEVER a path
  #                    (no "/", no "..", no whitespace/newlines: the value is
  #                    concatenated into a root-owned systemd drop-in, see
  #                    IMP-ce76b93d79fe). BINDING G2 DECISION: these are
  #                    names the agent resolves against an agent-owned
  #                    profile set/directory — never module-rootfs paths,
  #                    never operator-supplied paths; a name that fails to
  #                    resolve must fail CLOSED (unit does not start
  #                    unconfined).
  #   egress_allow     array of strings, max 64. Each entry: a hostname, a
  #                    hostname:port (port 1-65535), or an IPAddr-parseable
  #                    IP/CIDR ("0.0.0.0/0" and "::/0" are the documented,
  #                    review-required wildcard escape hatches). Entries
  #                    reach nft argv on-node, so this grammar (no spaces,
  #                    quotes, semicolons, braces) is the server-side
  #                    injection barrier; G2 owns the agent-side defense.
  #                    KEY PRESENCE is semantic (an empty list means
  #                    "restrict me to baseline", absence means "no egress
  #                    policy declared" — see buildPolicy's EgressDeclared).
  #
  # REMOVAL CONTRACT (downgrade-by-omission, IMP-01a02f59f44d): a config
  # write that OMITS `security` or `verify` while the stored config carries a
  # meaningful value for it is REFUSED — silence is not consent to drop
  # confinement. Removal is stated by writing the key EXPLICITLY: `"security":
  # null` or `"security": {}` (both yield the on-node default policy), or
  # `"verify": null`. Key presence — not any flag — is the acknowledgement,
  # so a partial payload can never ack by accident: the only way to pass the
  # gate is to say the key's name. Rollback restores a snapshot whose keys
  # cannot be edited, so it acknowledges via an explicit
  # `allow_confinement_removal:` argument instead (ModuleVersionService).
  #
  # `daemon_overrides` (IMP-01a02f5a6a1f) is validated as a key ALLOWLIST —
  # the platform's documented curated subset (see
  # System::DockerDaemonOverridesResolver::ALLOWED_KEYS, the resolver applies
  # the same list defensively at resolve time). `runtimes` (arbitrary OCI
  # binary paths executed as root) and `authorization-plugins` are refused
  # even though dockerd supports them; the tls*/hosts family stays refused as
  # platform-owned.
  # ==========================================================================
  module ModuleConfigValidator
    module_function

    # Returns an array of human-readable error strings for a candidate module
    # `config` hash. Empty array == acceptable.
    def errors_for(config)
      return [ "config must be a hash" ] unless config.is_a?(Hash)

      errors = []
      validate_restart_after_update(config, errors)
      validate_verify(config, errors)
      validate_promotion_thresholds(config, errors)
      validate_security(config, errors)
      validate_daemon_overrides(config, errors)
      errors
    end

    # === Downgrade-by-omission gate (see REMOVAL CONTRACT above) ===
    #
    # Keys whose silent disappearance changes what a node ENFORCES: `security`
    # is the module's confinement policy, `verify` its post-deploy proof. A
    # wholesale config replacement that simply does not mention them would
    # otherwise clear them fleet-wide with a 200 and no stated intent.
    PROTECTED_CONFINEMENT_KEYS = %w[security verify].freeze

    # Errors for a candidate REPLACEMENT config given the currently-stored
    # one. The acknowledgement is KEY PRESENCE in the candidate (any value the
    # grammar accepts, including nil / {}): an incomplete payload cannot state
    # a key's name by accident, so it cannot ack by accident.
    def removal_errors_for(config, previous)
      return [] unless config.is_a?(Hash) && previous.is_a?(Hash)

      errors = []
      PROTECTED_CONFINEMENT_KEYS.each do |key|
        next unless previous[key].present?
        next if config.key?(key)

        errors << "config write omits #{key.inspect}, which this module currently carries — " \
                  "dropping it would silently change what every node running the module enforces. " \
                  "To keep it, include the current #{key.inspect} block in the payload; to remove it, " \
                  "state that intent explicitly with \"#{key}\": null" \
                  "#{key == 'security' ? ' (or "security": {})' : ''}"
      end
      errors
    end

    # The two per-module promotion overrides System::Fleet::PromotionCriteria
    # resolves off `config` (see its resolution cascade). They are NOT manifest
    # keys — a manifest carrying them would land them under `manifest_extras`,
    # nested, where PromotionCriteria never looks — so this rule has no twin on
    # the import path to diverge FROM: the config-write path is the only way
    # they get set at all.
    #
    # It earns its keep because PromotionCriteria calls `raw.to_i` on whatever
    # it finds (promotion_criteria.rb resolve_threshold + required_count/
    # dwell_time). A Hash / Array / boolean there raises NoMethodError inside
    # the promotion sensor, which rescues per SENSOR rather than per version —
    # so ONE module with a poisoned value stops promotion sensing for the whole
    # account. A string is deliberately accepted: `to_i` handles it, and
    # SiteSetting/account-settings values arrive as strings.
    PROMOTION_THRESHOLD_KEYS = %w[
      module_promotion_required_count module_promotion_dwell_minutes
    ].freeze

    def validate_promotion_thresholds(config, errors)
      PROMOTION_THRESHOLD_KEYS.each do |key|
        next unless config.key?(key)

        value = config[key]
        next if value.nil?
        next if value.is_a?(Integer) || value.is_a?(Float) || value.is_a?(String)

        errors << "#{key} must be a number (System::Fleet::PromotionCriteria calls #to_i on it; "                   "a #{value.class} raises inside the promotion sensor, which rescues per-sensor "                   "and would stop promotion sensing for the whole account)"
      end
    end

    # Validates `restart_after_update:` — the declaration that updating THIS
    # module requires restarting ANOTHER module's service. See
    # System::RestartAfterUpdate for why the field exists and how it fires.
    #
    # Validated here, at manifest level, rather than at promotion time,
    # because a malformed declaration must be caught by CI (`validate_only`
    # backs the system_validate_module_manifest MCP action) before it ships.
    # A declaration that survives this gate but is still malformed is dropped
    # by RestartAfterUpdate.declarations — failing closed, i.e. no restart.
    #
    # The `services` check is the one that earns its keep: a `service:` /
    # `services:` typo would otherwise import cleanly and then silently never
    # restart anything, which is precisely the inert-deploy failure this whole
    # feature exists to remove.
    def validate_restart_after_update(manifest, errors)
      entries = manifest["restart_after_update"]
      return if entries.nil?

      unless entries.is_a?(Array)
        errors << "restart_after_update must be an array"
        return
      end

      entries.each_with_index do |entry, i|
        prefix = "restart_after_update[#{i}]"
        unless entry.is_a?(Hash)
          errors << "#{prefix} must be a hash"
          next
        end

        target = entry["module"]
        if target.blank?
          errors << "#{prefix}.module is required (the NAME of the module whose service must restart)"
        elsif !target.is_a?(String)
          errors << "#{prefix}.module must be a string"
        end

        services = entry["services"]
        if !services.is_a?(Array) || services.empty?
          errors << "#{prefix}.services must be a non-empty array of service names " \
                     "(note the plural — a `service:` key is ignored and would silently restart nothing)"
        else
          services.each_with_index do |svc, j|
            errors << "#{prefix}.services[#{j}] #{svc.inspect} must be a string" unless svc.is_a?(String)
          end
        end
      end
    end

    # Validates `verify:` — the post-deploy probe block (IMP-3855ff9908f2).
    # See System::ModuleVerify for the full rationale; the two rules that earn
    # their keep here are the two the settled design (readiness map §2) names:
    #
    #   1. `resolves_to` is REQUIRED on every probe. A `command` probe without
    #      it is an EXISTENCE check, and an existence check is exactly what
    #      passed while VM-9000 was broken — the name resolved, to the wrong
    #      file. Rejecting it at manifest level is the only place the mistake
    #      is cheap: once a probe ships, "it passed" is indistinguishable from
    #      "it proved something".
    #
    #   2. `command` must be a BARE NAME (no slash). A probe that names an
    #      absolute path asks the node to resolve that path, which it always
    #      can — it never exercises the PATH lookup, so it is structurally
    #      incapable of seeing a shadow. That is the same false green wearing
    #      a different hat.
    #
    # Note there is deliberately NO `shells:` key to validate. Every probe runs
    # in both a login and a non-login shell, always: the divergence between the
    # two IS the bug class, so it cannot be a per-manifest choice. Unknown probe
    # keys are rejected so `shells:`/`resolves-to:`-shaped typos fail loudly
    # rather than importing as a probe that silently checks less.
    def validate_verify(manifest, errors)
      block = manifest["verify"]
      return if block.nil?

      unless block.is_a?(Hash)
        errors << "verify must be a hash with a probes: key"
        return
      end

      extra_keys = block.keys.map(&:to_s) - [ "probes" ]
      if extra_keys.any?
        errors << "verify has unrecognized key(s) #{extra_keys.sort.inspect} " \
                  "(the only key is probes:; shells are NOT configurable — every " \
                  "probe runs in both a login and a non-login shell)"
      end

      probes = block["probes"]
      unless probes.is_a?(Array)
        errors << "verify.probes must be an array"
        return
      end

      # An EMPTY probes list is an error, not a permissive default. A module
      # that declares `verify:` is asserting it can prove itself; a block that
      # proves nothing would report as "declared and clean" on every tick.
      if probes.empty?
        errors << "verify.probes must not be empty (a verify: block that declares no probe " \
                  "asserts verification without performing any)"
        return
      end

      if probes.size > ::System::ModuleVerify::MAX_PROBES
        errors << "verify.probes has #{probes.size} entries (max #{::System::ModuleVerify::MAX_PROBES})"
      end

      seen_names = Set.new
      probes.each_with_index do |probe, i|
        validate_verify_probe(probe, "verify.probes[#{i}]", seen_names, errors)
      end
    end

    def validate_verify_probe(probe, prefix, seen_names, errors)
      unless probe.is_a?(Hash)
        errors << "#{prefix} must be a hash"
        return
      end

      unknown = probe.keys.map(&:to_s) - ::System::ModuleVerify::PROBE_KNOWN_KEYS
      if unknown.any?
        errors << "#{prefix} has unrecognized key(s) #{unknown.sort.inspect} " \
                  "(allowed: #{::System::ModuleVerify::PROBE_KNOWN_KEYS.join(', ')})"
      end

      name = probe["name"].to_s
      if name.blank?
        errors << "#{prefix}.name is required"
      elsif !name.match?(::System::ModuleVerify::NAME_RX)
        errors << "#{prefix}.name #{name.inspect} must match #{::System::ModuleVerify::NAME_RX.source} " \
                  "(it is concatenated into the signal fingerprint a failed probe raises)"
      elsif seen_names.include?(name)
        errors << "#{prefix}.name #{name.inspect} duplicates an earlier probe"
      else
        seen_names << name
      end

      command = probe["command"].to_s
      if command.blank?
        errors << "#{prefix}.command is required"
      elsif command.include?("/")
        errors << "#{prefix}.command #{command.inspect} must be a BARE command name, not a path — " \
                  "a probe naming an absolute path resolves that path instead of exercising the " \
                  "PATH lookup, so it cannot detect a shadowing binary (the VM-9000 failure)"
      elsif !command.match?(::System::ModuleVerify::COMMAND_RX)
        errors << "#{prefix}.command #{command.inspect} must match " \
                  "#{::System::ModuleVerify::COMMAND_RX.source} (it is expanded as a shell word on the node)"
      end

      resolves_to = probe["resolves_to"].to_s
      if resolves_to.blank?
        errors << "#{prefix}.resolves_to is required — a command probe MUST assert the resolved path, " \
                  "never mere existence; an existence check is what passed while the binary was shadowed"
      elsif !resolves_to.match?(::System::ModuleVerify::RESOLVES_TO_RX)
        errors << "#{prefix}.resolves_to #{resolves_to.inspect} must be an absolute path matching " \
                  "#{::System::ModuleVerify::RESOLVES_TO_RX.source}"
      elsif resolves_to.split("/").include?("..")
        errors << "#{prefix}.resolves_to #{resolves_to.inspect} must be canonical (no `..` segment) — " \
                  "the node compares it verbatim against what the shell resolved"
      end
    end

    # === security: — the confinement policy block (SECURITY-BLOCK CONTRACT
    # in the header is the normative statement; this enforces it) ===

    SECURITY_KNOWN_KEYS = %w[
      capabilities egress_allow privileged user_namespace
      seccomp_profile apparmor_profile selinux_profile
    ].freeze
    CAPABILITY_RX = /\ACAP_[A-Z_]{1,60}\z/
    PROFILE_NAME_RX = /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/
    HOSTNAME_RX = /\A[a-z0-9]([a-z0-9-]{0,62})?(\.[a-z0-9]([a-z0-9-]{0,62})?)*\z/i
    MAX_CAPABILITIES = 64
    MAX_EGRESS_ENTRIES = 64
    SECURITY_PROFILE_KEYS = %w[seccomp_profile apparmor_profile selinux_profile].freeze
    SECURITY_BOOLEAN_KEYS = %w[privileged user_namespace].freeze

    def validate_security(config, errors)
      return unless config.key?("security")

      sec = config["security"]
      # Explicit nil is the stated "no security policy" (removal ack) — the
      # agent's buildPolicy yields the default policy for it, same as absent.
      return if sec.nil?

      unless sec.is_a?(Hash)
        errors << "security must be a hash (the on-node confinement policy block)"
        return
      end

      unknown = sec.keys.map(&:to_s) - SECURITY_KNOWN_KEYS
      if unknown.any?
        errors << "security has unrecognized key(s) #{unknown.sort.inspect} " \
                  "(allowed: #{SECURITY_KNOWN_KEYS.join(', ')})"
      end

      validate_security_capabilities(sec, errors)
      validate_security_booleans(sec, errors)
      validate_security_profiles(sec, errors)
      validate_security_egress(sec, errors)
    end

    def validate_security_capabilities(sec, errors)
      return unless sec.key?("capabilities")

      caps = sec["capabilities"]
      return if caps.nil?

      unless caps.is_a?(Array)
        errors << "security.capabilities must be an array of CAP_* strings"
        return
      end
      if caps.size > MAX_CAPABILITIES
        errors << "security.capabilities has #{caps.size} entries (max #{MAX_CAPABILITIES})"
      end
      caps.each_with_index do |cap, i|
        next if cap.is_a?(String) && cap.match?(CAPABILITY_RX)

        errors << "security.capabilities[#{i}] #{cap.inspect} must be a string matching " \
                  "#{CAPABILITY_RX.source} — it is rendered into a root-owned systemd " \
                  "CapabilityBoundingSet drop-in on the node"
      end
    end

    def validate_security_booleans(sec, errors)
      SECURITY_BOOLEAN_KEYS.each do |key|
        next unless sec.key?(key)

        value = sec[key]
        next if value.nil? || value == true || value == false

        # The agent's buildPolicy type-asserts .(bool) and silently IGNORES
        # anything else — a string "false" for user_namespace would quietly
        # leave isolation ON while the author believes it off (and vice-shapes
        # for privileged). Loud refusal beats a silent divergence between what
        # was written and what the node enforces.
        errors << "security.#{key} must be strictly boolean (got #{value.class}) — the on-node " \
                  "policy reader ignores non-boolean values, so this write would not do what it says"
      end
    end

    def validate_security_profiles(sec, errors)
      SECURITY_PROFILE_KEYS.each do |key|
        next unless sec.key?(key)

        value = sec[key]
        next if value.nil?

        unless value.is_a?(String)
          errors << "security.#{key} must be a string profile NAME or null"
          next
        end
        next if value.match?(PROFILE_NAME_RX)

        errors << "security.#{key} #{value.inspect} must be a bare profile name matching " \
                  "#{PROFILE_NAME_RX.source} — never a path: the agent resolves names against " \
                  "an agent-owned profile set, and the value is concatenated into a root-owned " \
                  "systemd drop-in (IMP-ce76b93d79fe)"
      end
    end

    def validate_security_egress(sec, errors)
      return unless sec.key?("egress_allow")

      list = sec["egress_allow"]
      return if list.nil?

      unless list.is_a?(Array)
        errors << "security.egress_allow must be an array of host / host:port / CIDR strings " \
                  "(key presence with an empty array means \"baseline only\" and is meaningful)"
        return
      end
      if list.size > MAX_EGRESS_ENTRIES
        errors << "security.egress_allow has #{list.size} entries (max #{MAX_EGRESS_ENTRIES})"
      end
      list.each_with_index do |entry, i|
        next if valid_egress_entry?(entry)

        errors << "security.egress_allow[#{i}] #{entry.inspect} must be a hostname, hostname:port, " \
                  "IP, or CIDR — entries reach nft argv on the node, so the grammar is strict " \
                  "(\"0.0.0.0/0\" / \"::/0\" are the documented wildcard escape hatches)"
      end
    end

    # hostname[:port] | IP | CIDR. The grammar doubles as the nft-argv
    # injection barrier: no whitespace, quotes, semicolons, or braces can
    # pass. IPv6 zone-ids (%eth0) are refused — they are interface-local and
    # meaningless in a fleet-shipped policy — and a CIDR must use PREFIX form
    # (/0-128), never netmask form, so the reviewed wildcard escape hatch has
    # exactly two spellings ("0.0.0.0/0", "::/0") a grep can find.
    CIDR_RX = %r{\A[0-9a-fA-F:.]+/\d{1,3}\z}

    def valid_egress_entry?(entry)
      return false unless entry.is_a?(String)
      return false if entry.empty? || entry.length > 253
      return false if entry.include?("%")

      if entry.include?("/")
        entry.match?(CIDR_RX) && parseable_ip?(entry)
      elsif (m = entry.match(/\A(?<host>[^:]+)(:(?<port>\d{1,5}))?\z/))
        return false if m[:port] && !(1..65_535).cover?(m[:port].to_i)

        m[:host].match?(HOSTNAME_RX) || parseable_ip?(m[:host])
      else
        # Multiple colons: bare IPv6.
        parseable_ip?(entry)
      end
    end

    def parseable_ip?(value)
      IPAddr.new(value)
      true
    rescue IPAddr::Error, ArgumentError
      false
    end

    # === daemon_overrides: — dockerd daemon.json overlay (IMP-01a02f5a6a1f).
    #
    # A key ALLOWLIST, not a blocklist: dockerd's config surface grows, and a
    # blocklist enumerates only the bad keys someone already thought of. The
    # list itself lives on System::DockerDaemonOverridesResolver (the consumer
    # that documents the operator contract and applies the same list
    # defensively at resolve time for pre-gate rows); this validates at WRITE
    # time so the operator hears the refusal instead of a silent drop.
    #
    # The key is reachable only through the config-write path (not a manifest
    # KNOWN_TOP_KEY — a manifest carrying it lands it nested under
    # manifest_extras where the resolver never looks), so like the promotion
    # thresholds this rule has no import-path twin to diverge from.
    def validate_daemon_overrides(config, errors)
      return unless config.key?("daemon_overrides")

      overrides = config["daemon_overrides"]
      return if overrides.nil?

      unless overrides.is_a?(Hash)
        errors << "daemon_overrides must be a hash of dockerd daemon.json keys"
        return
      end

      keys = overrides.keys.map(&:to_s)
      refused = keys & ::System::DockerDaemonOverridesResolver::REFUSED_KEYS
      if refused.any?
        errors << "daemon_overrides may not carry #{refused.sort.inspect}: the tls*/hosts family is " \
                  "platform-owned (mTLS), and runtimes / authorization-plugins would hand the daemon " \
                  "an attacker-named binary or delegate its authz decisions"
      end

      unknown = keys - ::System::DockerDaemonOverridesResolver::ALLOWED_KEYS - refused
      if unknown.any?
        errors << "daemon_overrides has key(s) #{unknown.sort.inspect} outside the supported allowlist " \
                  "(#{::System::DockerDaemonOverridesResolver::ALLOWED_KEYS.join(', ')})"
      end

      validate_daemon_override_values(overrides, errors)
    end

    # Value grammar for the allowlisted keys whose VALUE is itself a
    # privilege lever (independent security review of this gate):
    #   data-root      relocates dockerd's root-owned tree — pointed at /etc
    #                  or /usr it becomes a host-integrity primitive, the same
    #                  class of harm as the refused `runtimes` key. Must be an
    #                  absolute, canonical path under a documented storage
    #                  root.
    #   storage-opts / exec-opts
    #                  arrays of daemon option tokens (dm.directlvm_device=
    #                  /dev/sda et al.) — constrained to a safe token grammar
    #                  so they cannot smuggle whitespace/newlines into
    #                  daemon.json semantics. Deeper per-option semantics are
    #                  the consumer's (agent-side) concern.
    DAEMON_DATA_ROOT_PREFIXES = %w[/var/lib/ /persist/ /data/ /mnt/ /srv/].freeze
    DAEMON_PATH_RX = %r{\A/[A-Za-z0-9_/.-]+\z}
    DAEMON_OPT_TOKEN_RX = %r{\A[A-Za-z0-9_.=:,+/@-]{1,256}\z}

    def validate_daemon_override_values(overrides, errors)
      if overrides.key?("data-root")
        root = overrides["data-root"]
        valid = root.is_a?(String) &&
                root.match?(DAEMON_PATH_RX) &&
                !root.split("/").include?("..") &&
                DAEMON_DATA_ROOT_PREFIXES.any? { |p| root.start_with?(p) }
        unless valid
          errors << "daemon_overrides.data-root #{root.inspect} must be an absolute, canonical path " \
                    "under one of #{DAEMON_DATA_ROOT_PREFIXES.join(', ')} — dockerd owns that tree as " \
                    "root, so an arbitrary path is a host-integrity primitive"
        end
      end

      %w[storage-opts exec-opts].each do |key|
        next unless overrides.key?(key)

        value = overrides[key]
        unless value.is_a?(Array)
          errors << "daemon_overrides.#{key} must be an array of option strings"
          next
        end
        value.each_with_index do |opt, i|
          next if opt.is_a?(String) && opt.match?(DAEMON_OPT_TOKEN_RX)

          errors << "daemon_overrides.#{key}[#{i}] #{opt.inspect} must be a plain option token " \
                    "matching #{DAEMON_OPT_TOKEN_RX.source}"
        end
      end
    end
  end
end
