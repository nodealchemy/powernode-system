# frozen_string_literal: true

# Consolidates System::NodeArchitecture from account-scoped to platform-wide.
#
# 1. Adds catalog columns: apt_name, rpm_name, display_name, family,
#    is_canonical, plus three counter-cache columns (node_platform_count,
#    package_repository_count, package_count) so the catalog UI can show
#    usage without N+1 counts.
#
# 2. Drops account_id (FK, column, and the account-scoped indexes) and
#    replaces them with platform-wide indexes including a unique index
#    on `name`.
#
# 3. Seeds the seven canonical CPU architectures with is_canonical=true.
#    Names follow apt/Debian convention (amd64, arm64, armhf, i386,
#    ppc64el — Ubuntu is the base distro and production callers default
#    to apt-style names). The rpm-style equivalent lives on `rpm_name`
#    for cross-distro lookups via `find_normalized` / `value_for_kind`.
#    Canonical rows can't be mutated via the API — only via migration.
#
# Reference: i-would-like-to-zesty-glade.md Tier 1.
class ConsolidateNodeArchitectures < ActiveRecord::Migration[8.1]
  CANONICAL_ARCHS = [
    {
      name: "amd64", family: "x86", display_name: "Intel/AMD 64-bit",
      apt_name: "amd64", rpm_name: "x86_64",
      description: "64-bit x86 architecture used by Intel and AMD processors. The dominant server and desktop CPU since the mid-2000s; runs essentially all mainstream Linux distributions."
    },
    {
      name: "arm64", family: "arm", display_name: "ARM 64-bit",
      apt_name: "arm64", rpm_name: "aarch64",
      description: "64-bit ARM architecture (ARMv8-A and newer). Powers Apple Silicon Macs, AWS Graviton, Ampere Altra, and most modern Raspberry Pi 4/5 boards."
    },
    {
      name: "armhf", family: "arm", display_name: "ARM 32-bit (hard-float)",
      apt_name: "armhf", rpm_name: "armv7hl",
      description: "32-bit ARM with hardware floating-point (VFP). Used by older Raspberry Pi models and embedded boards from before the 64-bit ARM transition."
    },
    {
      name: "i386", family: "x86", display_name: "Intel/AMD 32-bit",
      apt_name: "i386", rpm_name: "i686",
      description: "32-bit x86 architecture. Largely deprecated for server workloads but still common in legacy embedded systems and constrained VMs."
    },
    {
      name: "ppc64el", family: "power", display_name: "POWER 64-bit (little-endian)",
      apt_name: "ppc64el", rpm_name: "ppc64le",
      description: "IBM POWER architecture in 64-bit little-endian mode. Used by IBM Power Systems and OpenPOWER hardware for HPC and database workloads."
    },
    {
      name: "s390x", family: "z", display_name: "IBM Z (System z)",
      apt_name: "s390x", rpm_name: "s390x",
      description: "IBM System z mainframe architecture. Used by IBM Z and LinuxONE for transaction-heavy enterprise workloads."
    },
    {
      name: "riscv64", family: "risc-v", display_name: "RISC-V 64-bit",
      apt_name: "riscv64", rpm_name: "riscv64",
      description: "64-bit RISC-V open ISA. Emerging for embedded systems, accelerators, and increasingly available on developer boards (VisionFive, StarFive, SiFive HiFive)."
    }
  ].freeze

  def up
    add_catalog_columns!
    drop_account_scoping!
    add_platform_wide_indexes!
    seed_canonical_rows!
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Consolidating NodeArchitecture is a one-way migration. Restore from backup if needed."
  end

  private

  def add_catalog_columns!
    change_table :system_node_architectures do |t|
      t.string  :apt_name
      t.string  :rpm_name
      t.string  :display_name
      t.string  :family, null: false, default: "other"
      t.boolean :is_canonical, null: false, default: false
      t.integer :node_platform_count, null: false, default: 0
      t.integer :package_repository_count, null: false, default: 0
      t.integer :package_count, null: false, default: 0
    end
  end

  def drop_account_scoping!
    remove_index :system_node_architectures, name: "index_system_node_architectures_on_account_id_and_name" if index_name_exists?(:system_node_architectures, "index_system_node_architectures_on_account_id_and_name")
    remove_index :system_node_architectures, [:account_id, :enabled] if index_exists?(:system_node_architectures, [:account_id, :enabled])
    remove_index :system_node_architectures, [:account_id, :public]  if index_exists?(:system_node_architectures, [:account_id, :public])

    remove_reference :system_node_architectures, :account, foreign_key: true, type: :uuid, index: true
  end

  def add_platform_wide_indexes!
    add_index :system_node_architectures, :name, unique: true
    add_index :system_node_architectures, :enabled
    add_index :system_node_architectures, :public
    add_index :system_node_architectures, :family
    add_index :system_node_architectures, :is_canonical
    add_index :system_node_architectures, :apt_name, where: "apt_name IS NOT NULL"
    add_index :system_node_architectures, :rpm_name, where: "rpm_name IS NOT NULL"
  end

  def seed_canonical_rows!
    now = Time.current.utc
    CANONICAL_ARCHS.each do |attrs|
      new_id = SecureRandom.uuid
      execute(<<~SQL)
        INSERT INTO system_node_architectures
          (id, name, apt_name, rpm_name, display_name, family, description,
           is_canonical, enabled, public,
           node_platform_count, package_repository_count, package_count,
           created_at, updated_at)
        VALUES
          (#{q(new_id)},
           #{q(attrs[:name])},
           #{q(attrs[:apt_name])},
           #{q(attrs[:rpm_name])},
           #{q(attrs[:display_name])},
           #{q(attrs[:family])},
           #{q(attrs[:description])},
           TRUE, TRUE, TRUE, 0, 0, 0,
           #{q(now)}, #{q(now)})
      SQL
    end
    say "Seeded #{CANONICAL_ARCHS.size} canonical architectures", true
  end

  def q(value)
    ActiveRecord::Base.connection.quote(value)
  end
end
