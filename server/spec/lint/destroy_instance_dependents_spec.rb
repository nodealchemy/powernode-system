# frozen_string_literal: true

require "rails_helper"

# Ai::Tools::SystemFleetTool::DESTROY_INSTANCE_FKS is a raw-SQL cascade the
# system extension runs before destroying a NodeInstance. It used to name a
# private extension's table, which does not exist on a core-mode install, so
# every system_destroy_instance there raised PG::UndefinedTable. A table owned by
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

  it "is not empty" do
    expect(Ai::Tools::SystemFleetTool::DESTROY_INSTANCE_FKS).not_to be_empty
  end

  # Every FK onto system_node_instances in the committed schema is cleared
  # somehow, or is a named exemption with its reason. A new FK fails here
  # until someone decides which.
  describe "coverage of the FKs onto system_node_instances" do
    # Known gaps, each with why it is not in the static list.
    exemptions = {
      "system_storage_migrations.node_instance_id" =>
        "Known gap: neither the static list nor an FK action clears it, so an instance with a storage " \
        "migration row still refuses to destroy with the InvalidForeignKey message. Reconciling this list " \
        "with NodeInstance::CASCADE_DEPENDENTS is its own change (see instance_pool_service.rb)."
    }.freeze

    fks = schema_rb.scan(/^\s*add_foreign_key "(\w+)", "system_node_instances"(.*)$/).map do |table, rest|
      column = rest[/column: "(\w+)"/, 1] || "system_node_instance_id"
      { edge: "#{table}.#{column}", on_delete: rest[/on_delete: :(\w+)/, 1] }
    end
    static = Ai::Tools::SystemFleetTool::DESTROY_INSTANCE_FKS.map { |table, column| "#{table}.#{column}" }

    it "finds the FKs to check" do
      expect(fks).not_to be_empty
    end

    it "clears every FK statically, by its own ON DELETE, or names it as an exemption" do
      uncovered = fks.reject do |fk|
        static.include?(fk[:edge]) || %w[cascade nullify].include?(fk[:on_delete]) || exemptions.key?(fk[:edge])
      end
      expect(uncovered.map { |fk| fk[:edge] }).to be_empty
    end

    it "carries no stale exemption" do
      edges = fks.map { |fk| fk[:edge] }
      expect(exemptions.keys - edges).to be_empty
      expect(exemptions.keys & static).to be_empty
    end
  end

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
