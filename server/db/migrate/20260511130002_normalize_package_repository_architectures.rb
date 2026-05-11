# frozen_string_literal: true

# Light data clean of the JSONB `architectures` column on
# system_package_repositories so the new multi-select UI can render it
# without exploding on stale whitespace / casing / empties.
#
# This is intentionally *not* the full T2.A canonical-name consolidation
# (which would store rpm-style names everywhere and translate at sync
# time). That's a follow-up PR. This migration just:
#
# - strips whitespace and lowercases each entry
# - drops empty strings
# - de-duplicates (preserving first-seen order)
# - logs a count of rows that changed
#
# Idempotent: re-running is a no-op once the data is clean.
#
# Reference: i-would-like-to-zesty-glade.md Tier 1 schema section.
class NormalizePackageRepositoryArchitectures < ActiveRecord::Migration[8.1]
  def up
    return unless table_exists?(:system_package_repositories)

    changed = 0

    rows = execute("SELECT id, architectures FROM system_package_repositories").to_a
    rows.each do |row|
      original = parse_jsonb_array(row["architectures"])
      cleaned  = normalize(original)
      next if cleaned == original

      execute("UPDATE system_package_repositories SET architectures = #{quote_jsonb(cleaned)} WHERE id = #{quote(row['id'])}")
      changed += 1
    end

    say "Normalized #{changed} PackageRepository.architectures row(s)", true if changed > 0
  end

  def down
    # No-op — normalization is forward-only (we don't preserve the
    # pre-clean values).
  end

  private

  def normalize(values)
    Array(values).map { |v| v.to_s.strip.downcase }.reject(&:empty?).uniq
  end

  def parse_jsonb_array(raw)
    return raw if raw.is_a?(Array)
    return [] if raw.nil? || raw == ""

    parsed = JSON.parse(raw) rescue [raw.to_s]
    Array(parsed)
  end

  def quote(value)
    ActiveRecord::Base.connection.quote(value)
  end

  def quote_jsonb(array)
    quote(JSON.generate(array))
  end
end
