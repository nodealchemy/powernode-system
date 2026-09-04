# frozen_string_literal: true

require "spec_helper"

# IMP-4c5c53574683 — `rails db:seed` on ops-hub died with
#   PG::UndefinedTable: relation "solid_cache_entries" does not exist
# and information_schema on powernode_production confirmed the table absent.
#
# The core-side root cause is pinned in server/spec/db/solid_cache_schema_delivery_spec.rb:
# every production database config resolves to the same physical database, so
# ActiveRecord's initialize_database finds the shared schema_migrations table
# already present by the time it reaches the non-primary configs and skips their
# schema DUMPS entirely. db/cache_schema.rb is therefore unreachable on a fresh
# install as well as on this live host, and the cache config's declared
# migrations_paths is the only remaining delivery mechanism.
#
# This module's start wrapper is the OTHER half of that: it is what actually runs
# `db:migrate`, and it does so deliberately and exclusively (its own "INVARIANT
# (imp 019f77c5)" block forbids the schema:load family, because those stamp the
# extension migrations as applied without running their DDL). These invariants
# keep that delivery path intact — if the wrapper ever stops running db:migrate
# on either branch, or grows a schema:load shortcut, the cache schema silently
# stops landing again.
RSpec.describe "hub-backend start wrapper: cache-schema delivery (IMP-4c5c53574683)" do
  let(:extension_root) { File.expand_path("../../..", __dir__) }
  let(:script) do
    File.read(File.join(extension_root,
                        "modules/powernode-hub-backend/rootfs/usr/local/bin/rails-start.sh"))
  end

  it "runs db:migrate on BOTH the first-boot and the already-initialized branch" do
    # First boot creates the schema; every later boot is what converges an
    # established host onto a newly added cache migration with no manual step.
    expect(script.scan(/bundle exec rails db:migrate/).length).to be >= 2,
      "db:migrate must run on both branches, otherwise a cache migration added later " \
      "never reaches an already-initialized install"
  end

  it "never uses a schema:load-family task to initialize the database" do
    expect(script).not_to match(/rails db:(schema:load|setup|prepare)\b/),
      "see the INVARIANT (imp 019f77c5) block: schema:load stamps the extension " \
      "migrations via assume_migrated_upto_version without running their DDL"
  end

  it "does not claim the hub ships no solid_cache table" do
    # The wrapper's generated-secrets heredoc carried that claim as the reason
    # CACHE_STORE is overridden. It is false for solid_cache once db/cache_migrate
    # ships the table, and a stale justification is what keeps a workaround alive.
    #
    # Unwrap comment continuations FIRST: the claim spans two comment lines
    # ("...this hub ships\n# no solid_cache/solid_queue tables"), so a pattern
    # applied to the raw bytes matches nothing and passes vacuously.
    #
    # The containment check is structural, not a phrase this very commit is
    # rewriting: a wording anchor would expire with the edit and leave the
    # assertion below unable to fail.
    unwrapped = script.gsub(/\n#\s*/, " ")
    expect(unwrapped.lines.length).to be < script.lines.length,
      "unwrapping collapsed no comment continuations, so a wrapped claim would slip through"

    expect(unwrapped).not_to match(/ships no solid_cache/),
      "rails-start.sh still asserts the hub ships no solid_cache tables — that claim " \
      "was falsified by IMP-4c5c53574683 (db/cache_migrate now creates them)"
  end
end
