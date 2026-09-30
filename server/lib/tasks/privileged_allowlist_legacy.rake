# frozen_string_literal: true

# IMP-06cf44531256 — move the legacy privileged-module grant into the protected
# setting. An explicit operator action: it PRINTS what it would do, and writes
# only when told to.
#
#   rake system:privileged_allowlist:migrate_legacy
#       prints the plan (source account, entry, module id and name, owning
#       account, and whether it would migrate); writes nothing.
#   CONFIRM=1 OPERATOR=<email or user id> rake system:privileged_allowlist:migrate_legacy
#       applies it, and the audit rows name that operator. Refuses without an
#       OPERATOR that resolves to a user holding admin.access.
#   ... DISCARD_UNRESOLVED=1
#       also removes the legacy entries that are not migrated (they name no
#       module, or a module owned by another account), after recording them in
#       the audit row. To grant a module of another account, use the protected
#       site setting instead.
#
# Only entries naming a module OWNED by the granting account migrate: the
# protected setting is global, so a foreign-owned entry would otherwise turn one
# tenant's grant into another tenant's privilege.
namespace :system do
  namespace :privileged_allowlist do
    desc "Show, and with CONFIRM=1 OPERATOR=<user> apply, the move of the legacy privileged_module_ids grant"
    task migrate_legacy: :environment do
      service = System::PrivilegedAllowlistLegacyMigration
      lines = service.plan_lines(service.new.plan)
      puts(lines.empty? ? "no legacy privileged_module_ids source present" : lines)
      next if lines.empty?

      unless ENV["CONFIRM"] == "1"
        puts "dry run: nothing written. Re-run with CONFIRM=1 OPERATOR=<email or user id> to apply."
        next
      end

      operator = ENV["OPERATOR"].to_s.strip
      actor = if operator.include?("@") then User.find_by(email: operator) else User.find_by(id: operator) end
      abort "refusing to write: OPERATOR=<email or user id> must name an existing user (got #{operator.inspect})" if actor.nil?
      unless actor.has_permission?("admin.access")
        abort "refusing to write: OPERATOR #{operator.inspect} does not hold admin.access; the audit row must name an administrator"
      end

      result = service.call(discard_unresolved: ENV["DISCARD_UNRESOLVED"] == "1", actor: actor)
      puts "moved #{result.moved_ids.size} module id(s); kept: #{result.unresolved.inspect}; " \
           "legacy remaining: #{result.legacy_remaining}#{result.error ? "; error: #{result.error}" : ''}"
      exit(1) unless result.ok? && !result.legacy_remaining
    end
  end
end
