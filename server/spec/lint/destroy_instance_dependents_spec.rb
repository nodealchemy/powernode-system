# frozen_string_literal: true

require "rails_helper"

# Ai::Tools::SystemFleetTool::DESTROY_INSTANCE_FKS is a raw-SQL cascade the
# system extension runs before destroying a NodeInstance. It used to name a
# private extension's table (business_billing_provisioning_usage_records),
# which does not exist on a core-mode install, so every
# system_destroy_instance there raised PG::UndefinedTable. A table owned by
# another extension registers itself through
# System::NodeInstance.register_destroy_dependent instead; the static list
# holds only tables this extension or core owns, and every one must exist, so
# a typo or a cross-extension name fails here rather than in production.
RSpec.describe "system_destroy_instance static dependent tables" do
  # Deliberately restated, not read from the tool: widening the allowed set
  # should be a visible edit to this spec.
  allowed_prefixes = %w[system_ devops_ ai_].freeze
  # The committed core-only schema: a static entry must be a table every
  # install has, which a private extension's never is.
  schema_rb = File.read(Rails.root.join("db/schema.rb"))

  Ai::Tools::SystemFleetTool::DESTROY_INSTANCE_FKS.each do |table, column|
    it "#{table}.#{column} is owned by core or the system extension" do
      expect(allowed_prefixes.any? { |prefix| table.start_with?(prefix) }).to be(true),
        "#{table} is not under #{allowed_prefixes.join(', ')}: a table owned by another extension must " \
        "register itself with System::NodeInstance.register_destroy_dependent instead of being listed here"
    end

    it "#{table} is created by the committed db/schema.rb" do
      expect(schema_rb).to include(%(create_table "#{table}")), "#{table} is not in server/db/schema.rb"
    end

    it "#{table}.#{column} exists in the schema" do
      connection = ActiveRecord::Base.connection
      expect(connection.data_source_exists?(table)).to be(true), "#{table} does not exist"
      expect(connection.column_exists?(table, column)).to be(true), "#{table}.#{column} does not exist"
    end
  end
end
