# frozen_string_literal: true

require "rails_helper"
require Rails.root.join(
  "../extensions/system/server/db/migrate/20260930100000_create_system_node_assignment_clearances.rb"
)

# IMP-9f4e162d9ed1 follow-up - server/db/schema.rb already carries this table, so
# a fresh database built with db:schema:load still sees the migration as pending.
# Called against the already-loaded schema, `up` must be a no-op rather than
# raising PG::DuplicateTable and aborting every later migration.
RSpec.describe CreateSystemNodeAssignmentClearances do
  subject(:migration) { described_class.new }

  after(:context) { ActiveRecord::Base.connection.clear_cache! }

  it "is a no-op when the table already exists (schema.rb loaded ahead of the migration)" do
    expect(ActiveRecord::Base.connection.table_exists?(:system_node_assignment_clearances)).to be(true)

    migration.verbose = false
    expect { migration.migrate(:up) }.not_to raise_error

    expect(ActiveRecord::Base.connection.table_exists?(:system_node_assignment_clearances)).to be(true)
  end
end
