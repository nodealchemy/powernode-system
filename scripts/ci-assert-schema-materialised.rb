# frozen_string_literal: true

# Fails when a migration is recorded as applied but the schema object it
# declares does not exist — the "stamped-without-created" state, which is
# UNREPAIRABLE by db:migrate and invisible to every other check.
#
# Run from powernode-platform/server after the test DB is prepared:
#   bundle exec rails runner ../extensions/system/scripts/ci-assert-schema-materialised.rb
#
# HOW THE STATE ARISES. db:schema:load calls assume_migrated_upto_version,
# which stamps EVERY migration version <= schema.rb's declared version as
# applied — without running it. So any table whose migration sits below that
# version but which is ABSENT from schema.rb is never created, while
# schema_migrations insists it was. db:migrate then finds nothing pending and
# cannot repair it.
#
# Live instance this was written for (2026-09-05): extension migration
# 20260905061000_create_system_fleet_signal_states sat below schema.rb's
# 2026_09_05_062000 and was missing from the dump. Every schema-built database
# lacked the table. It surfaced only because System::Fleet::SignalState rescues
# StandardError and returns nil — so the standing-signal lane silently no-opped
# instead of raising, and no spec could see it.
#
# WHY NOT "un-assume and re-migrate", the fix scripts/prepare-extension-test-db.sh
# uses: that works only for PRIVATE extensions, whose tables are deliberately
# absent from the core schema.rb. Measured on 2026-09-05: un-assuming a PUBLIC
# extension migration whose table IS in schema.rb and re-running db:migrate
# raises, because create_table hits the table schema:load already made. So for
# public extensions the schema.rb must simply be correct — and this asserts it.

# COLUMNS TOO, since IMP-01a07e0f. This scanned create_table/drop_table alone,
# which meant a migration that only ADDS A COLUMN was never covered — and it is
# stamped by the identical mechanism and hits the identical wall: the table
# exists, so the guard passed, while the column never reached any schema-built
# database. 50 of the tree's 114 migrations add a column that way.
#
# The scan itself lives in SchemaMaterialisationAudit so it can be tested
# against fixture migrations (server/spec/scripts/schema_materialisation_audit_spec.rb).
# A scan that has silently drifted reports "0 missing" in the same words as one
# that is working, so the derivation needs an oracle of its own.
require_relative "schema_materialisation_audit"

MIGRATION_GLOBS = [ "db/migrate/*.rb", "../extensions/*/server/db/migrate/*.rb" ].freeze

files = MIGRATION_GLOBS.flat_map { |g| Dir.glob(g) }
                       .sort_by { |f| File.basename(f)[/\A\d+/].to_s }

abort("ci-assert-schema-materialised: no migrations matched #{MIGRATION_GLOBS.inspect} " \
      "(cwd=#{Dir.pwd}) — this guard's derivation has drifted and would pass vacuously") if files.empty?

audit = SchemaMaterialisationAudit.new(files)
expected_tables, expected_columns = audit.expectations

abort("ci-assert-schema-materialised: parsed 0 create_table across #{files.size} " \
      "migrations — the scan has drifted") if expected_tables.empty?
abort("ci-assert-schema-materialised: parsed 0 column additions across #{files.size} " \
      "migrations — the column scan has drifted") if expected_columns.empty?

conn   = ActiveRecord::Base.connection
actual = conn.tables.to_set

missing_tables = expected_tables.reject { |t, _| actual.include?(t) }

# Columns are only asked about for tables that exist: a missing table already
# fails above, and reporting each of its columns as well would bury the one
# line that names the cause.
columns_by_table = {}
missing_columns = expected_columns.reject do |key, _|
  table, column = key.split(".", 2)
  next true unless actual.include?(table)

  (columns_by_table[table] ||= conn.columns(table).map(&:name).to_set).include?(column)
end

# The skipped count is printed on the PASSING line as well. A guard that
# quietly covers less than it appears to is the shape of the defect this
# exists to catch, so its own coverage is stated every run.
puts "ci-assert-schema-materialised: #{files.size} migrations, " \
     "#{expected_tables.size} tables expected (#{missing_tables.size} missing), " \
     "#{expected_columns.size} columns expected (#{missing_columns.size} missing), " \
     "#{actual.size} tables present, #{audit.skipped.size} statement(s) not parseable"

audit.skipped.each { |line| puts "  not parsed (non-literal argument): #{line}" }

if missing_tables.empty? && missing_columns.empty?
  exit 0
end

warn "\nSTAMPED WITHOUT CREATED — these migrations are recorded applied but what they declare is absent."
warn "db:migrate CANNOT repair this; the schema.rb dump is missing them.\n\n"
missing_tables.each { |t, f| warn "  table  #{t}\n      created by #{f}" }
missing_columns.each { |key, f| warn "  column #{key}\n      added by #{f}" }
warn "\nRemedy: on a scratch DB, DELETE the version from schema_migrations, run db:migrate so"
warn "the migration actually executes, dump, and commit the result into schema.rb.\n"
exit 1
