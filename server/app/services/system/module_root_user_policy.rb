# frozen_string_literal: true

module System
  # IMP-94977647c24c — reject a shipped service `user: root` for the
  # hub modules unless a DOCUMENTED exception exists.
  #
  # SCOPE, DELIBERATELY NARROW. Several other modules (postgres-primary,
  # postgres-replica, redis) also declare `user: root` today and drop
  # privileges INTERNALLY (postgres-start.sh's `runuser`, redis-server's
  # own setuid handling) — a pattern this task does not touch or judge.
  # This policy only evaluates IN_SCOPE_MODULES; every other module's
  # `user: root` is out of scope and untouched, so this cannot regress a
  # module this task never reviewed.
  #
  # An exception is not a bare boolean: it must carry a real `reason` and
  # a `task` (an IMP id) that a reader can go verify, so removing the
  # justification (not just the boolean) is what makes the check start
  # failing again — see modules/.schema/root-user-exceptions.yml.
  class ModuleRootUserPolicy
    IN_SCOPE_MODULES = %w[powernode-hub-backend powernode-hub-worker].freeze
    # review_by: an exception EXPIRES — it is a snapshot of a prerequisite
    # (e.g. "polkit is absent on the live hub") that can become stale. A
    # boolean-only exception would never force anyone to re-check that the
    # reason still holds.
    REQUIRED_EXCEPTION_KEYS = %w[reason task review_by].freeze
    TASK_ID_RX = /\AIMP-[0-9a-f]{12}\z/

    class << self
      # manifest: a parsed manifest hash (as YAML.safe_load returns) —
      # must carry "name" and "services".
      # exceptions: the parsed root-user-exceptions.yml hash, shaped
      #   module_name => service_name => {"reason" => ..., "task" => ...,
      #   "review_by" => ...}.
      #
      # Returns an array of human-readable violation strings; empty means
      # the manifest complies (either no in-scope root usage, or every
      # instance is validly exception-documented).
      #
      # FAILS CLOSED, NEVER RAISES (review round 4). `manifest` can be nil
      # or a non-Hash, `services` can be present but not an Array (or
      # contain a non-Hash entry), and `exceptions` can be nil/false —
      # exactly what YAML.safe_load returns for a missing/empty file, and
      # a real state a git checkout can be in mid-edit. Every one of those
      # is treated as "nothing to check" (or "no exception on record"),
      # never a crash — the gate that is supposed to be enforcing safety
      # must not itself be the thing that breaks CI on a malformed input.
      def violations(manifest, exceptions)
        return [] unless manifest.is_a?(Hash)

        module_name = manifest["name"]
        return [] unless IN_SCOPE_MODULES.include?(module_name)

        services = manifest["services"]
        return [] unless services.is_a?(Array)

        exceptions = exceptions.is_a?(Hash) ? exceptions : {}

        services.filter_map { |service| service_violation(module_name, service, exceptions) }
      end

      private

      def service_violation(module_name, service, exceptions)
        return unless service.is_a?(Hash)
        return unless service["user"] == "root"

        service_name = service["name"]
        exception = safe_dig(exceptions, module_name, service_name)
        exception_violation(module_name, service_name, exception)
      end

      # exceptions.dig(a, b) raises TypeError if an intermediate value
      # (e.g. exceptions[module_name]) isn't dig-able — a malformed
      # registry entry (a String instead of a Hash) must read as ABSENT,
      # not crash the gate.
      def safe_dig(exceptions, module_name, service_name)
        exceptions.dig(module_name, service_name)
      rescue TypeError, NoMethodError
        nil
      end

      def exception_violation(module_name, service_name, exception)
        label = "#{module_name}/#{service_name}"

        unless exception.is_a?(Hash)
          return "#{label}: user: root with no documented exception " \
                 "(add one to modules/.schema/root-user-exceptions.yml, or drop root)"
        end

        missing = REQUIRED_EXCEPTION_KEYS - exception.keys.map(&:to_s)
        return "#{label}: exception is missing #{missing.join(', ')}" if missing.any?

        task = exception["task"].to_s
        return "#{label}: exception task #{task.inspect} is not an IMP id" unless task.match?(TASK_ID_RX)

        reason = exception["reason"].to_s
        return "#{label}: exception reason is blank" if reason.strip.empty?

        review_by_violation(label, exception["review_by"])
      end

      def review_by_violation(label, review_by)
        date = begin
          Date.parse(review_by.to_s)
        rescue ArgumentError, TypeError
          nil
        end

        return "#{label}: exception review_by #{review_by.inspect} is not a valid date" if date.nil?

        if date < Date.current
          return "#{label}: exception review_by #{date} has passed — re-review whether the " \
                 "prerequisite this exception cites still holds, then update review_by"
        end

        nil
      end
    end
  end
end
