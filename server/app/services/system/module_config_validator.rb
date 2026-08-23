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
  #     security              → agent runtime/reconcile.go buildPolicy    (see below)
  #     skills, build, display_name, license, manifest_extras
  #   platform-written, never operator-authored:
  #     honeypot              → System::Honeypot::CanaryModuleService
  #     last_build            → System::ModuleBuildService
  #     reuse_check           → Ai::Tools::SystemFleetTool (update_columns)
  #   legitimately operator-tunable at runtime:
  #     module_promotion_required_count / module_promotion_dwell_minutes
  #                           → System::Fleet::PromotionCriteria (documented
  #                             per-module override cascade)      TYPE-CHECKED
  #     daemon_overrides      → System::DockerDaemonOverridesResolver
  #     resources             → node_api modules#resource
  #
  # Because that last group is deliberately operator-editable, the gate is a
  # SHAPE check on the semantic blocks, not a top-level key allowlist: an
  # allowlist would reject writes the platform documents as supported.
  #
  # `security` is deliberately NOT validated here: the import path does not
  # validate it either, so adding a rule here would recreate the divergence
  # this module exists to remove (and changing the import path's behaviour is
  # out of scope). Filed separately.
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
  end
end
