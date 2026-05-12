# frozen_string_literal: true

# T2.A — Canonical-name storage for PackageRepository.architectures.
#
# Before this migration, rpm repos stored kind-specific names like
# ["x86_64", "aarch64"] while apt repos stored ["amd64", "arm64"].
# Cross-repo aggregation queries had to normalize per-kind every time
# ("which CPUs does my fleet's package catalog support?").
#
# After this migration, every repo's architectures column stores
# canonical names (the `name` column on system_node_architectures —
# apt-convention per the prior session's design choice). The adapters
# translate canonical → kind-specific at sync time via
# PackageRepository#architectures_for_kind.
#
# Translation rules:
#   - apt repo with ["amd64", "arm64"]   → unchanged (canonical = apt-style)
#   - rpm repo with ["x86_64", "aarch64"] → ["amd64", "arm64"]
#   - rpm repo with ["armv7hl"]           → ["armhf"]
#   - rpm repo with ["i686"]              → ["i386"]
#   - rpm repo with ["ppc64le"]           → ["ppc64el"]
#
# Unmappable entries (no NodeArchitecture row matches via name/apt_name/
# rpm_name/aliases) are dropped with a loud LOG WARN. The migration
# logs every translation so operators can audit what changed.
#
# Idempotent: re-running on already-canonical data is a no-op.
class CanonicalizePackageRepositoryArchitectures < ActiveRecord::Migration[8.0]
  def up
    return unless table_exists?(:system_package_repositories)
    return unless table_exists?(:system_node_architectures)

    # Build the kind-specific → canonical lookup once. Includes aliases
    # (case-insensitive) so vendor tags get normalized too.
    lookup = build_canonical_lookup

    rows = execute("SELECT id, kind, architectures FROM system_package_repositories").to_a
    changed = 0
    dropped = 0

    rows.each do |row|
      original = Array(parse_jsonb(row["architectures"]))
      next if original.empty?

      canonicalized = []
      original.each do |value|
        canonical = lookup[value.to_s.downcase]
        if canonical
          canonicalized << canonical
        else
          dropped += 1
          say "  [WARN] PackageRepository id=#{row['id']} kind=#{row['kind']}: dropping unmappable arch #{value.inspect}"
        end
      end
      canonicalized.uniq!

      next if canonicalized == original

      execute(
        "UPDATE system_package_repositories " \
        "SET architectures = #{quote_jsonb(canonicalized)} " \
        "WHERE id = #{ActiveRecord::Base.connection.quote(row['id'])}"
      )
      changed += 1
    end

    say "Canonicalized #{changed} PackageRepository.architectures row(s); dropped #{dropped} unmappable value(s)" if changed > 0 || dropped > 0
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Canonicalization is one-way — the original kind-specific names " \
          "can't be reconstructed without per-repo kind context that this " \
          "migration discards. Restore from DB backup if rollback is needed."
  end

  private

  # Map every variant (name, apt_name, rpm_name, alias) → canonical name.
  # Lowercase keys so the lookup is case-insensitive.
  def build_canonical_lookup
    lookup = {}
    execute("SELECT name, apt_name, rpm_name, aliases FROM system_node_architectures").each do |row|
      canonical = row["name"]
      [row["name"], row["apt_name"], row["rpm_name"]].compact.each do |v|
        lookup[v.downcase] = canonical
      end
      Array(parse_jsonb(row["aliases"])).each { |a| lookup[a.to_s.downcase] = canonical }
    end
    lookup
  end

  def parse_jsonb(value)
    return value if value.is_a?(Array)
    return [] if value.nil?
    JSON.parse(value)
  rescue JSON::ParserError
    []
  end

  def quote_jsonb(value)
    "#{ActiveRecord::Base.connection.quote(value.to_json)}::jsonb"
  end
end
