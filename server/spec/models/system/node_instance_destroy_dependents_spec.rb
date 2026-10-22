# frozen_string_literal: true

require "rails_helper"

# The extension seam for system_destroy_instance's raw-SQL cascade: a table
# another extension owns, holding a node_instance FK, registers here
# (mirroring Account.register_teardown_guard) rather than being named in the
# system extension's own DESTROY_INSTANCE_FKS.
RSpec.describe System::NodeInstance, ".register_destroy_dependent" do
  around do |example|
    snapshot = described_class.destroy_dependents.dup
    example.run
  ensure
    described_class.destroy_dependents.replace(snapshot)
  end

  it "records the table and FK column" do
    described_class.register_destroy_dependent("zz_ext_widgets", "node_instance_id")

    expect(described_class.registered_destroy_dependents).to include([ "zz_ext_widgets", "node_instance_id" ])
  end

  it "is idempotent, so a to_prepare block re-running on reload does not pile up duplicates" do
    2.times { described_class.register_destroy_dependent(:zz_ext_widgets, :node_instance_id) }

    expect(described_class.registered_destroy_dependents.count([ "zz_ext_widgets", "node_instance_id" ])).to eq(1)
  end

  # The names are interpolated into a DELETE statement, so only a plain SQL
  # identifier is accepted.
  it "refuses a name that is not a plain identifier" do
    expect { described_class.register_destroy_dependent("widgets; DROP TABLE accounts", "node_instance_id") }
      .to raise_error(ArgumentError, /identifier/)
    expect { described_class.register_destroy_dependent("zz_ext_widgets", "node_instance_id = 1 OR 1") }
      .to raise_error(ArgumentError, /identifier/)
  end
end
