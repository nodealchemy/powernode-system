# frozen_string_literal: true

# Fails when a migration is recorded as applied but the table it creates does
# not exist — the "stamped-without-created" state, which is UNREPAIRABLE by
# db:migrate and invisible to every other check.
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

MIGRATION_GLOBS = [ "db/migrate/*.rb", "../extensions/*/server/db/migrate/*.rb" ].freeze

files = MIGRATION_GLOBS.flat_map { |g| Dir.glob(g) }
                       .sort_by { |f| File.basename(f)[/\A\d+/].to_s }

abort("ci-assert-schema-materialised: no migrations matched #{MIGRATION_GLOBS.inspect} " \
      "(cwd=#{Dir.pwd}) — this guard's derivation has drifted and would pass vacuously") if files.empty?

# Replay the migration set to get the tables it claims should exist. Order
# matters: a table created then dropped must not be expected.
expected = {}
files.each do |f|
  src = File.read(f)
  src.scan(/^\s*create_table[ (]+[:"]([a-z0-9_]+)/) { |(t)| expected[t] = f }
  src.scan(/^\s*drop_table[ (]+[:"]([a-z0-9_]+)/)   { |(t)| expected.delete(t) }
end

abort("ci-assert-schema-materialised: parsed 0 create_table across #{files.size} " \
      "migrations — the scan has drifted") if expected.empty?

conn   = ActiveRecord::Base.connection
actual = conn.tables.to_set
missing = expected.reject { |t, _| actual.include?(t) }

puts "ci-assert-schema-materialised: #{files.size} migrations, #{expected.size} tables expected, " \
     "#{actual.size} present, #{missing.size} missing"

unless missing.empty?
  warn "\nSTAMPED WITHOUT CREATED — these migrations are recorded applied but their table is absent."
  warn "db:migrate CANNOT repair this; the schema.rb dump is missing the table.\n\n"
  missing.each { |t, f| warn "  #{t}\n      created by #{f}" }
  warn "\nRemedy: on a scratch DB, DELETE the version from schema_migrations, run db:migrate so"
  warn "the migration actually executes, dump, and commit the table into schema.rb.\n"
  exit 1
end
