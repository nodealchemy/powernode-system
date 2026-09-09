# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

require File.expand_path("../../../scripts/schema_materialisation_audit", __dir__)

# IMP-01a07e0f. ci-assert-schema-materialised.rb catches the unrepairable
# "stamped without created" state: db:schema:load calls
# assume_migrated_upto_version, which marks every migration at or below
# schema.rb's version as applied WITHOUT running it, so anything missing from
# the dump is never materialised while schema_migrations insists it was, and
# db:migrate finds nothing pending to repair.
#
# The guard scanned create_table / drop_table and nothing else. A migration
# that only ADDS A COLUMN is stamped by exactly the same mechanism and hits
# exactly the same wall — the table exists, so the guard passed, while the
# column never reached any schema-built database. 50 of the tree's 114
# migrations add a column that way, and none of them were covered.
#
# These examples pin the SCAN, on fixture migrations rather than on whatever
# the repository happens to contain: a scan that has silently drifted reports
# "0 missing" in exactly the same words as a scan that is working.
RSpec.describe SchemaMaterialisationAudit do
  around do |example|
    Dir.mktmpdir("schema-audit") do |dir|
      @dir = dir
      example.run
    end
  end

  # Migrations are replayed in filename order, so the fixtures are numbered
  # the way real ones are — order is load-bearing for every "added then
  # removed" case below.
  def migration(version, body)
    path = File.join(@dir, "#{version}_fixture.rb")
    File.write(path, body)
    path
  end

  def expectations_for(*paths)
    audit = SchemaMaterialisationAudit.new(paths)
    tables, columns = audit.expectations
    [ tables.keys, columns.keys, audit ]
  end

  describe "the gap this closes" do
    it "expects a column an add_column migration declares" do
      _, columns, = expectations_for(migration("20260101000000", <<~RB))
        class Fixture < ActiveRecord::Migration[8.0]
          def change
            add_column :system_nodes, :environment_id, :uuid
          end
        end
      RB

      expect(columns).to eq([ "system_nodes.environment_id" ])
    end

    it "expects the _id column an add_reference declares" do
      _, columns, = expectations_for(migration("20260101000000", <<~RB))
        class Fixture < ActiveRecord::Migration[8.0]
          def change
            add_reference :system_nodes, :environment, type: :uuid, foreign_key: true
            add_belongs_to :system_tasks, :operator, type: :uuid
          end
        end
      RB

      expect(columns).to contain_exactly(
        "system_nodes.environment_id", "system_tasks.operator_id"
      )
    end
  end

  describe "replay order" do
    it "does not expect a column a later migration removes" do
      _, columns, = expectations_for(
        migration("20260101000000", <<~RB),
          class Fixture < ActiveRecord::Migration[8.0]
            def change
              add_column :system_nodes, :legacy_flag, :boolean
            end
          end
        RB
        migration("20260102000000", <<~RB)
          class Fixture < ActiveRecord::Migration[8.0]
            def change
              remove_column :system_nodes, :legacy_flag, :boolean
            end
          end
        RB
      )

      expect(columns).to be_empty
    end

    it "follows a rename to the new name and drops the old" do
      _, columns, = expectations_for(
        migration("20260101000000", <<~RB),
          class Fixture < ActiveRecord::Migration[8.0]
            def change
              add_column :system_nodes, :old_name, :string
            end
          end
        RB
        migration("20260102000000", <<~RB)
          class Fixture < ActiveRecord::Migration[8.0]
            def change
              rename_column :system_nodes, :old_name, :new_name
            end
          end
        RB
      )

      expect(columns).to eq([ "system_nodes.new_name" ])
    end

    it "forgets a dropped table's columns along with the table" do
      tables, columns, = expectations_for(
        migration("20260101000000", <<~RB),
          class Fixture < ActiveRecord::Migration[8.0]
            def change
              create_table :doomed, id: :uuid do |t|
                t.string :name
              end
              add_column :doomed, :extra, :string
            end
          end
        RB
        migration("20260102000000", <<~RB)
          class Fixture < ActiveRecord::Migration[8.0]
            def change
              drop_table :doomed
            end
          end
        RB
      )

      expect(tables).to be_empty
      expect(columns).to be_empty
    end

    it "carries a table's columns across a rename" do
      tables, columns, = expectations_for(
        migration("20260101000000", <<~RB),
          class Fixture < ActiveRecord::Migration[8.0]
            def change
              create_table :before_name, id: :uuid
              add_column :before_name, :extra, :string
            end
          end
        RB
        migration("20260102000000", <<~RB)
          class Fixture < ActiveRecord::Migration[8.0]
            def change
              rename_table :before_name, :after_name
            end
          end
        RB
      )

      expect(tables).to eq([ "after_name" ])
      expect(columns).to eq([ "after_name.extra" ])
    end
  end

  describe "statements that must NOT be read as declarations" do
    # 42 migrations in the tree define `down`. Its body describes the REVERSE
    # migration, which never runs on a forward-migrated database — reading it
    # inverts every expectation it contains.
    it "ignores a def down body in both directions" do
      _, columns, = expectations_for(migration("20260101000000", <<~RB))
        class Fixture < ActiveRecord::Migration[8.0]
          def up
            add_column :system_nodes, :kept, :string
          end

          def down
            remove_column :system_nodes, :kept, :string
            add_column :system_nodes, :resurrected, :string
          end
        end
      RB

      expect(columns).to eq([ "system_nodes.kept" ])
    end

    # The first run of this scan invented an expectation for
    # "environment.uuid_id" out of `add_reference table, :environment, type:
    # :uuid` — a loop over a table list. Reading past the variable shifts
    # every later argument one position left.
    it "skips a statement whose table is a variable, and says so" do
      _, columns, audit = expectations_for(migration("20260101000000", <<~RB))
        class Fixture < ActiveRecord::Migration[8.0]
          def change
            %i[system_nodes system_tasks].each do |table|
              add_reference table, :environment, type: :uuid
            end
          end
        end
      RB

      expect(columns).to be_empty
      expect(audit.skipped).to contain_exactly(
        "add_reference table, :environment, type: :uuid"
      )
    end

    it "ignores a commented-out statement" do
      _, columns, = expectations_for(migration("20260101000000", <<~RB))
        class Fixture < ActiveRecord::Migration[8.0]
          def change
            # add_column :system_nodes, :never_declared, :string
            add_column :system_nodes, :real, :string
          end
        end
      RB

      expect(columns).to eq([ "system_nodes.real" ])
    end

    # Columns inside a create_table block materialise WITH the table, which
    # the table check already covers. Parsing them is a Ruby parser's job
    # (t.references, t.timestamps, multi-name t.string :a, :b) and getting it
    # wrong turns a build gate into a false alarm.
    it "leaves create_table block columns to the table check" do
      tables, columns, = expectations_for(migration("20260101000000", <<~RB))
        class Fixture < ActiveRecord::Migration[8.0]
          def change
            create_table :system_widgets, id: :uuid do |t|
              t.string :name
              t.references :account, type: :uuid
              t.timestamps
            end
          end
        end
      RB

      expect(tables).to eq([ "system_widgets" ])
      expect(columns).to be_empty
    end
  end

  describe "the guard script that drives it" do
    let(:script) do
      File.read(File.expand_path("../../../scripts/ci-assert-schema-materialised.rb", __dir__))
    end

    # The extraction is only worth anything if the driver actually asserts on
    # what the scan now returns. A driver still checking tables alone would
    # leave every example above passing while the build gate covers nothing.
    it "asserts columns, not only tables" do
      expect(script).to include("SchemaMaterialisationAudit")
      expect(script).to match(/conn\.columns\(/)
    end

    it "reports the statements the scan could not parse" do
      expect(script).to match(/skipped/)
    end
  end
end
