# frozen_string_literal: true

# Two distinct permissions for the embedding pipeline:
#
#   - system.packages.embed   — worker-only. Gates the lease + writeback
#     endpoints under /api/v1/system/worker_api/packages/* so a stray operator
#     token can't claim a batch and never finish it (leaving rows stuck with
#     embedding_started_at set). Granted to the system_worker role here.
#
#   - system.packages.reembed — operator-facing. Gates the manual rake task
#     (`rake system:packages:backfill_embeddings`) and any future "re-embed
#     this repo" UI action. NOT auto-granted — admins assign per-role via
#     normal permission management so a worker compromise can't force a
#     full re-embed of the catalog.
#
# Mirrors the SeedCloudSyncPermission pattern (find_or_create_by!, table_exists?
# guards, grant-to-system_worker block).
class SeedPackageEmbeddingPermissions < ActiveRecord::Migration[8.0]
  PERMISSIONS = {
    "system.packages.embed" => {
      resource:    "system.packages",
      action:      "embed",
      description: "Lease + write package embeddings (worker-only — granted to system_worker)",
      grant_to_worker: true
    },
    "system.packages.reembed" => {
      resource:    "system.packages",
      action:      "reembed",
      description: "Manually re-embed a package repository's catalog (operator action)",
      grant_to_worker: false
    }
  }.freeze

  def up
    return unless table_exists?(:permissions)

    PERMISSIONS.each do |name, attrs|
      ::Permission.find_or_create_by!(name: name) do |p|
        p.resource    = attrs[:resource]
        p.action      = attrs[:action]
        p.description = attrs[:description]
        p.category    = "resource" if p.respond_to?(:category=)
      end
    end

    return unless table_exists?(:roles) && table_exists?(:role_permissions)

    PERMISSIONS.each do |name, attrs|
      next unless attrs[:grant_to_worker]

      perm = ::Permission.find_by(name: name)
      next unless perm

      ::Role.where(name: "system_worker").find_each do |role|
        role.permissions << perm unless role.permissions.exists?(id: perm.id)
      end
    end
  end

  def down
    return unless table_exists?(:permissions)

    ::Permission.where(name: PERMISSIONS.keys).destroy_all
  end
end
