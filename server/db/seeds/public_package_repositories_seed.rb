# frozen_string_literal: true

# Seeds two well-known public package repositories as `shared` (system-wide)
# rows that every account can browse, sync, and materialize from:
#
#   * Debian stable — official US mirror at ftp.us.debian.org
#   * Ubuntu noble (24.04 LTS) — US mirror at us.archive.ubuntu.com
#
# Both are platform-agnostic (no node_platform links). Architectures are
# stored as canonical names (T2.A) — the apt adapter translates back to
# kind-specific names (amd64, arm64, armhf, …) at sync time via
# NodeArchitecture#value_for_kind.
#
# Idempotent: re-running the seed updates fields in-place rather than
# duplicating rows. The composite unique index on
# (account_id IS NULL, name) means name is the primary key for shared rows.
#
# created_by attribution: anchored to the platform admin user. The repos
# don't really have a human author, but PackageRepository.created_by_id
# is NOT NULL, so we point at the admin account's admin user.

puts "  📦 Seeding public package repositories…"

admin_account = Account.first
unless admin_account
  puts "  ⚠️  No account found — skipping public package repository seed"
  return
end

admin_user = admin_account.users.find_by(email: "admin@powernode.org") || admin_account.users.first
unless admin_user
  puts "  ⚠️  No admin user found — skipping public package repository seed"
  return
end

# Defensive check: every canonical arch name we reference must exist
# in the catalog. Canonical convention is apt-style (amd64, arm64, …)
# — the rpm adapter translates at sync time. Architecture seed runs in
# an earlier migration; if it's absent (e.g. a partial reset) skip
# rather than create broken rows.
required_canonical = %w[amd64 arm64 armhf ppc64el s390x riscv64]
missing = required_canonical.reject { |n| ::System::NodeArchitecture.exists?(name: n) }
if missing.any?
  puts "  ⚠️  Missing canonical architectures #{missing.inspect} — skipping"
  return
end

PUBLIC_REPOS = [
  {
    name:        "Debian stable (US mirror)",
    description: "Official Debian stable archive served from ftp.us.debian.org. Tracks the current stable release (bookworm → trixie → …) automatically via the `stable` meta-suite.",
    base_url:    "http://ftp.us.debian.org/debian/",
    apt_config:  { "suite" => "stable", "components" => ["main"] },
    # Debian stable supports: amd64, arm64, armhf, i386, mips64el,
    # mipsel, ppc64el, s390x. We list canonicals that have a row in the
    # catalog. i386 deliberately excluded — it remains in stable but
    # its kernel is being phased out.
    architectures: %w[amd64 arm64 armhf ppc64el s390x]
  },
  {
    name:        "Ubuntu noble (US mirror)",
    description: "Ubuntu 24.04 LTS (noble) main archive served from us.archive.ubuntu.com. Tracks Ubuntu's primary architecture set: amd64, arm64, armhf, ppc64el, riscv64, s390x.",
    base_url:    "http://us.archive.ubuntu.com/ubuntu/",
    apt_config:  { "suite" => "noble", "components" => ["main", "restricted", "universe", "multiverse"] },
    architectures: %w[amd64 arm64 armhf ppc64el riscv64 s390x]
  }
].freeze

created = 0
updated = 0
PUBLIC_REPOS.each do |spec|
  repo = ::System::PackageRepository.find_or_initialize_by(
    visibility: "shared",
    account_id: nil,
    name:       spec[:name]
  )
  was_new = repo.new_record?
  repo.assign_attributes(
    description:    spec[:description],
    kind:           "apt",
    base_url:       spec[:base_url],
    architectures:  spec[:architectures],
    apt_config:     spec[:apt_config],
    rpm_config:     {},
    enabled:        true,
    priority:       100,
    created_by:     admin_user
  )
  repo.save!
  was_new ? created += 1 : updated += 1
end

puts "  ✅ Public package repositories: #{created} created, #{updated} updated " \
     "(#{::System::PackageRepository.shared.count} shared total)"
