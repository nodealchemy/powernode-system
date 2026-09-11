# frozen_string_literal: true

require "rails_helper"

# The component drawer's per-component signals view filters fleet events by
# the typed certificate_id column, per record. node_instance_id and
# node_module_id were already indexed; certificate_id was not, so every
# acme_certificate drawer read scanned the account's whole event window.
#
# PARTIAL (certificate_id IS NOT NULL): nearly every fleet event carries no
# certificate, and a NULL column means "not recorded" — it is never a value the
# filter matches — so NULL rows have no business in the index.
RSpec.describe "system_fleet_events typed-column indexes", type: :model do
  let(:connection) { ActiveRecord::Base.connection }
  let(:indexes) { connection.indexes(:system_fleet_events) }

  def single_column_index(column)
    indexes.find { |i| i.columns == [ column ] }
  end

  it "indexes certificate_id over recorded certificates only" do
    index = single_column_index("certificate_id")
    expect(index).to be_present, "no single-column index on system_fleet_events.certificate_id"
    expect(index.where).to eq("(certificate_id IS NOT NULL)")
  end

  it "leaves the certificate_id index valid in the catalog (a failed concurrent build is not an index)" do
    valid = connection.select_value(<<~SQL)
      SELECT i.indisvalid
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indexrelid
       WHERE c.relname = 'index_system_fleet_events_on_certificate_id'
    SQL
    expect(valid).to be(true)
  end

  # The other arm: the lookup finds the sibling typed-column indexes that were
  # already there, so an absent certificate_id index is an absence, not a
  # lookup that can find nothing.
  it "finds the sibling typed-column indexes with the same lookup" do
    expect(single_column_index("node_instance_id")).to be_present
    expect(single_column_index("node_module_id")).to be_present
  end
end
