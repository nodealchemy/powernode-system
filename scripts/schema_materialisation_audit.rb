# frozen_string_literal: true

# Parses a migration set for the schema objects it CLAIMS should exist, so a
# caller with a live connection can assert they actually do.
#
# Split out of ci-assert-schema-materialised.rb so the derivation is testable
# against fixture migrations rather than only against whatever the repository
# happens to contain — a scan that has silently drifted looks exactly like a
# scan with nothing to report (see spec/lib/powernode_system/schema_materialisation_audit_spec.rb).
#
# SCOPE, deliberately narrow. Only unambiguous one-line, literal-argument forms
# are parsed:
#
#   create_table / drop_table / rename_table
#   add_column / remove_column / rename_column
#   add_reference / add_belongs_to / remove_reference / remove_belongs_to
#
# NOT parsed, and each omission is a decision:
#   - columns declared INSIDE a create_table block. They materialise with the
#     table, which the table check already covers; parsing `t.references`,
#     `t.timestamps` and multi-name `t.string :a, :b` correctly is a Ruby
#     parser's job, and getting it wrong turns this guard into a false alarm.
#   - anything whose table or column is a VARIABLE (`add_missing_fk_indexes`
#     loops over a list). A literal scan cannot see those; under-covering is
#     the safe direction for a guard that fails a build.
#   - indexes and foreign keys. A missing index is a performance defect, not
#     the unrepairable stamped-without-created state this exists to catch.
class SchemaMaterialisationAudit
  # `def down` bodies describe the REVERSE migration, which never runs on a
  # forward-migrated database. Parsing them inverts every expectation in the
  # 42 migrations that define one: a `remove_column` there would forget a
  # column that does exist, and an `add_column` reverting a removal would
  # demand one that must not. Matched by indentation — these are one-per-file,
  # rubocop-formatted, and no migration in the tree uses `reversible do`.
  DOWN_BLOCK = /^(\s*)def (?:self\.)?down\b.*?^\1end\s*$/m

  # A literal symbol or quoted string, anchored: the WHOLE argument must be
  # one. `add_reference table, :environment, ...` (a loop over a table list)
  # must not parse — reading past the variable shifts every later argument
  # left and invents an expectation, which is how the first run of this scan
  # reported a missing "environment.uuid_id" that no migration ever declared.
  LITERAL = /\A[:"']([a-z0-9_]+)["']?\z/

  # How many leading positional arguments each statement needs. A statement
  # that cannot supply that many LITERAL arguments is not parsed at all.
  ARITY = {
    "create_table" => 1, "drop_table" => 1, "rename_table" => 2,
    "add_column" => 2, "remove_column" => 2, "rename_column" => 3,
    "add_reference" => 2, "add_belongs_to" => 2,
    "remove_reference" => 2, "remove_belongs_to" => 2
  }.freeze

  Finding = Struct.new(:kind, :table, :column, :source, keyword_init: true) do
    def label = column ? "#{table}.#{column}" : table
  end

  # Statements skipped because an argument was a variable rather than a
  # literal. REPORTED rather than swallowed: a guard that quietly covers less
  # than it appears to is the shape of the defect it exists to catch.
  attr_reader :skipped

  def initialize(files)
    @files = files
    @skipped = []
  end

  # Replays the set in declaration order — a table created then dropped, or a
  # column added then removed, must not be expected.
  def expectations
    tables = {}
    columns = {}

    @files.each do |file|
      src = File.read(file).gsub(DOWN_BLOCK, "")

      each_statement(src) do |op, args|
        case op
        when "create_table"
          tables[args[0]] = file
        when "drop_table"
          tables.delete(args[0])
          columns.reject! { |key, _| key.start_with?("#{args[0]}.") }
        when "rename_table"
          tables[args[1]] = tables.delete(args[0]) || file
          rekey_table(columns, args[0], args[1])
        when "add_column"
          columns["#{args[0]}.#{args[1]}"] = file
        when "remove_column"
          columns.delete("#{args[0]}.#{args[1]}")
        when "rename_column"
          columns.delete("#{args[0]}.#{args[1]}")
          columns["#{args[0]}.#{args[2]}"] = file
        when "add_reference", "add_belongs_to"
          columns["#{args[0]}.#{args[1]}_id"] = file
        when "remove_reference", "remove_belongs_to"
          columns.delete("#{args[0]}.#{args[1]}_id")
        end
      end
    end

    [ tables, columns ]
  end

  private

  # Only statements at the start of a line (after indentation) count, so a
  # `create_table` named inside a comment or a heredoc of remediation advice
  # is not mistaken for a declaration.
  def each_statement(src)
    src.each_line do |line|
      next if line =~ /^\s*#/

      match = line.match(/^\s*(#{Regexp.union(ARITY.keys)})[ (]+(.*)$/o)
      next unless match

      op = match[1]
      args = literal_args(match[2], ARITY.fetch(op))
      if args.size < ARITY.fetch(op)
        @skipped << line.strip
        next
      end

      yield op, args
    end
  end

  # Takes the first `limit` comma-separated arguments, stopping at the first
  # one that is not a bare literal — which is where the positional arguments
  # end and the options hash (`type: :uuid`, `foreign_key: { ... }`) begins.
  def literal_args(rest, limit)
    args = []
    rest.split(",").first(limit).each do |token|
      match = token.strip.match(LITERAL)
      break unless match

      args << match[1]
    end
    args
  end

  def rekey_table(columns, from, to)
    columns.keys.grep(/\A#{Regexp.escape(from)}\./).each do |key|
      columns["#{to}.#{key.split('.', 2).last}"] = columns.delete(key)
    end
  end
end
