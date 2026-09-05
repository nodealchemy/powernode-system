# frozen_string_literal: true

# Stamps schema_migrations with every migration version a freshly loaded test
# database should be considered to already carry.
#
# Run from powernode-platform/server, after `db:schema:load`:
#   bundle exec rails runner ../extensions/system/scripts/ci-stamp-migration-versions.rb
#
# WHY BOTH TREES ARE GLOBBED. `db:schema:load` calls
# assume_migrated_upto_version, which stamps only migrations up to the version
# schema.rb itself declares. Two kinds go unstamped:
#
#   1. EXTENSION migrations — they never appear in core's schema.rb at all.
#      This is the case the original inline backfill was written for.
#
#   2. CORE migrations NEWER than schema.rb's version. A DATA-only migration
#      changes no schema, so schema.rb is not regenerated, its version stays
#      behind, and the migration is pending forever.
#
# Case 2 broke CI on 2026-09-05. Core's data-only
# 20260905050000_scrub_historical_audit_log_secrets.rb sits above schema.rb's
# 20260904150000; the backfill globbed extensions ONLY, so every rspec and
# provider-specs suite aborted at load with "Migrations are pending" before a
# single example ran. It went unnoticed because every previous core migration
# was DDL and therefore bumped schema.rb — the extension-only glob had never
# been the binding constraint.
#
# This lives in a file, not inline in ci.yaml, because the backfill was
# duplicated verbatim across the rspec and provider-specs jobs and the gap
# existed in both. One copy cannot drift from the other.
#
# STAMPING WITHOUT RUNNING is correct here and is what the inline version did:
# the test DB is built from schema.rb, so its tables are empty and a data
# migration has nothing to act on.

core       = Dir.glob("db/migrate/*.rb")
extensions = Dir.glob("../extensions/*/server/db/migrate/*.rb")
paths      = core + extensions

# Fail loudly rather than stamp nothing. If a path convention changes, an empty
# glob would leave the DB unstamped and the suites would abort later with a
# message pointing at migrations rather than at this script.
if core.empty?
  abort("ci-stamp-migration-versions: no core migrations matched db/migrate/*.rb " \
        "(cwd=#{Dir.pwd}) — run this from powernode-platform/server")
end
if extensions.empty?
  abort("ci-stamp-migration-versions: no extension migrations matched " \
        "../extensions/*/server/db/migrate/*.rb (cwd=#{Dir.pwd}) — is the extension mounted?")
end

versions = paths.filter_map { |f| File.basename(f)[/\A\d+/] }.uniq
abort("ci-stamp-migration-versions: #{paths.size} files matched but none carried a " \
      "leading version number") if versions.empty?

connection = ActiveRecord::Base.connection
versions.each do |v|
  connection.execute(
    "INSERT INTO schema_migrations (version) VALUES (#{connection.quote(v)}) ON CONFLICT DO NOTHING"
  )
end

puts "ci-stamp-migration-versions: stamped #{versions.size} version(s) " \
     "(#{core.size} core, #{extensions.size} extension)"
