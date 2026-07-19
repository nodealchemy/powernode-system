# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

RSpec.describe System::SchemaDriftDetector do
  # A minimal fake connection so the parse + compare logic is exercised without
  # having to stamp real rows into schema_migrations or run real DDL.
  def fake_conn(applied:, tables:, columns: {}, indexes: {}, raise_on: nil)
    conn = instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter)
    allow(conn).to receive(:select_values).and_return(applied.map(&:to_s))
    allow(conn).to receive(:data_source_exists?) do |t|
      raise "boom" if raise_on == :data_source_exists?
      tables.include?(t.to_s)
    end
    allow(conn).to receive(:columns) do |t|
      Array(columns[t.to_s]).map { |c| instance_double("Column", name: c) }
    end
    allow(conn).to receive(:indexes) do |t|
      Array(indexes[t.to_s]).map { |i| instance_double("IndexDef", name: i) }
    end
    conn
  end

  def with_migrations(files)
    Dir.mktmpdir do |dir|
      files.each { |name, body| File.write(File.join(dir, name), body) }
      yield dir
    end
  end

  it "reports NO drift when an applied migration's add_column exists live" do
    with_migrations(
      "20260101000001_add_lifecycle.rb" =>
        "class AddLifecycle < ActiveRecord::Migration[8.0]\n" \
        "  def change\n    add_column :widgets, :lifecycle_class, :string\n  end\nend\n"
    ) do |dir|
      conn = fake_conn(applied: %w[20260101000001], tables: %w[widgets],
                       columns: { "widgets" => %w[id lifecycle_class] })
      result = described_class.run(migration_paths: [ dir ], connection: conn)

      expect(result.drifted?).to be(false)
      expect(result.migrations_scanned).to eq(1)
      expect(result.missing).to be_empty
    end
  end

  it "FLAGS a stamped migration's add_column that is absent from a live table (the #41 signature)" do
    with_migrations(
      "20260715120100_add_lifecycle.rb" =>
        "class AddLifecycle < ActiveRecord::Migration[8.0]\n" \
        "  def change\n    add_column :system_node_instances, :lifecycle_class, :string\n  end\nend\n"
    ) do |dir|
      conn = fake_conn(applied: %w[20260715120100], tables: %w[system_node_instances],
                       columns: { "system_node_instances" => %w[id name] }) # lifecycle_class ABSENT
      result = described_class.run(migration_paths: [ dir ], connection: conn)

      expect(result.drifted?).to be(true)
      expect(result.missing).to include(
        hash_including(table: "system_node_instances", kind: "column",
                       name: "lifecycle_class", version: "20260715120100")
      )
    end
  end

  it "SKIPS objects on a table absent from the live DB (uninstalled extension → never a false positive)" do
    with_migrations(
      "20260101000002_create_biz.rb" =>
        "class AddBiz < ActiveRecord::Migration[8.0]\n" \
        "  def change\n    add_column :business_invoices, :total_cents, :integer\n  end\nend\n"
    ) do |dir|
      conn = fake_conn(applied: %w[20260101000002], tables: []) # table not installed here
      result = described_class.run(migration_paths: [ dir ], connection: conn)

      expect(result.drifted?).to be(false)
      expect(result.missing).to be_empty
      expect(result.tables_absent_skipped).to be >= 1
    end
  end

  it "does NOT flag a PENDING (unstamped) migration even if its column is absent" do
    with_migrations(
      "20260901000000_add_future.rb" =>
        "class AddFuture < ActiveRecord::Migration[8.0]\n" \
        "  def change\n    add_column :widgets, :not_yet, :string\n  end\nend\n"
    ) do |dir|
      conn = fake_conn(applied: [], tables: %w[widgets], columns: { "widgets" => %w[id] })
      result = described_class.run(migration_paths: [ dir ], connection: conn)

      expect(result.drifted?).to be(false)
      expect(result.versions_pending_skipped).to eq(1)
      expect(result.migrations_scanned).to eq(0)
    end
  end

  it "nets out a column added then removed by a later applied migration (no false positive)" do
    with_migrations(
      "20260101000010_add_col.rb" =>
        "class AddCol < ActiveRecord::Migration[8.0]\n  def change\n    add_column :widgets, :temp_col, :string\n  end\nend\n",
      "20260101000020_drop_col.rb" =>
        "class DropCol < ActiveRecord::Migration[8.0]\n  def change\n    remove_column :widgets, :temp_col, :string\n  end\nend\n"
    ) do |dir|
      conn = fake_conn(applied: %w[20260101000010 20260101000020], tables: %w[widgets],
                       columns: { "widgets" => %w[id] }) # temp_col absent — but it was dropped
      result = described_class.run(migration_paths: [ dir ], connection: conn)

      expect(result.drifted?).to be(false)
      expect(result.missing).to be_empty
    end
  end

  it "FLAGS a stamped add_index that is absent from a live table" do
    with_migrations(
      "20260101000030_add_idx.rb" =>
        "class AddIdx < ActiveRecord::Migration[8.0]\n" \
        "  def change\n    add_index :widgets, [:lifecycle_class], name: \"idx_widgets_lifecycle\"\n  end\nend\n"
    ) do |dir|
      conn = fake_conn(applied: %w[20260101000030], tables: %w[widgets],
                       columns: { "widgets" => %w[id lifecycle_class] },
                       indexes: { "widgets" => %w[index_widgets_on_id] }) # named index absent
      result = described_class.run(migration_paths: [ dir ], connection: conn)

      expect(result.drifted?).to be(true)
      expect(result.missing).to include(
        hash_including(table: "widgets", kind: "index", name: "idx_widgets_lifecycle")
      )
    end
  end

  it "NEVER raises — a connection error yields a safe empty result with error set" do
    with_migrations(
      "20260101000040_add_col.rb" =>
        "class AddCol < ActiveRecord::Migration[8.0]\n  def change\n    add_column :widgets, :x, :string\n  end\nend\n"
    ) do |dir|
      conn = fake_conn(applied: %w[20260101000040], tables: %w[widgets], raise_on: :data_source_exists?)
      result = nil
      expect { result = described_class.run(migration_paths: [ dir ], connection: conn) }.not_to raise_error
      expect(result.drifted?).to be(false)
      expect(result.error).to be_present
    end
  end

  it "finds NO drift against the real, correctly-migrated test DB (real migration paths)" do
    # Strong real-world assertion: a properly-migrated DB has zero stamped-but-
    # absent objects across every loaded migration path.
    result = described_class.run # real migration_paths + real connection
    expect(result.error).to be_nil
    expect(result.drifted?).to be(false), "unexpected drift: #{result.missing.inspect}"
    expect(result.migrations_scanned).to be > 0
  end
end
