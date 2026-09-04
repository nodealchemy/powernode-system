# frozen_string_literal: true

# IMP-f2a7a729d39b — makes the `:needs_step2_migration` tag REAL.
#
# The step-2 retirement guards (spec/models/system/node_lifecycle_class_retirement_spec.rb,
# spec/models/system/lifecycle_class_value_space_spec.rb,
# spec/models/system/node_instance_lease_class_spec.rb) tag the examples that
# read the LIVE schema for the absence of `system_nodes.lifecycle_class`. On a
# test database created before migration 20260904100000 those examples are not
# wrong, they are unanswerable — and with the tag registered nowhere they
# FAILED rather than skipped, so a tag that reads like a skip was documentary
# only.
#
# The skip is keyed on the MIGRATION, not on the column. Once 20260904100000 is
# recorded in schema_migrations the examples run for real, so a later change
# that re-adds the column is reported as the failure it is instead of being
# masked by a skip. The two conditions are only ever equal while nothing has
# regressed, which is exactly why the weaker one (column absent) is the wrong
# key.
RSPEC_STEP2_LIFECYCLE_DROP_MIGRATION = "20260904100000"

RSpec.configure do |config|
  config.before(:each, :needs_step2_migration) do
    applied = ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql_array(
        [ "SELECT 1 FROM schema_migrations WHERE version = ? LIMIT 1",
          RSPEC_STEP2_LIFECYCLE_DROP_MIGRATION ]
      )
    )

    next if applied

    skip("extension migration #{RSPEC_STEP2_LIFECYCLE_DROP_MIGRATION} " \
         "(drop_lifecycle_class_from_system_nodes) has not been applied to this test " \
         "database; the live-schema half of the step-2 retirement guard cannot be answered")
  end
end
