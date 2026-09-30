# frozen_string_literal: true

# IMP-06cf44531256 — re-run the move of the legacy privileged-module grant into
# the protected setting. Safe to repeat: it unions into the existing value and
# does nothing once no legacy source remains.
#
#   rake system:privileged_allowlist:migrate_legacy
#   DISCARD_UNRESOLVED=1 rake system:privileged_allowlist:migrate_legacy
#
# An entry that names no module keeps its legacy source (and the critical fleet
# event) until it is fixed or explicitly discarded; DISCARD_UNRESOLVED=1 records
# the discarded entries in the audit row and then removes them.
namespace :system do
  namespace :privileged_allowlist do
    desc "Move the legacy privileged_module_ids grant into the protected site setting (audited, re-runnable)"
    task migrate_legacy: :environment do
      result = System::PrivilegedAllowlistLegacyMigration.call(discard_unresolved: ENV["DISCARD_UNRESOLVED"] == "1")
      puts "moved #{result.moved_ids.size} module id(s); unresolved: #{result.unresolved.inspect}; " \
           "legacy remaining: #{result.legacy_remaining}#{result.error ? "; error: #{result.error}" : ''}"
      exit(1) unless result.ok? && !result.legacy_remaining
    end
  end
end
