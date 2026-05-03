# frozen_string_literal: true

# Permissions for the GitOps reconciler:
#   - system.gitops.read       — list/show GitopsRepository + SyncRun
#   - system.gitops.write      — create/update/destroy GitopsRepository
#   - system.gitops.sync       — trigger off-schedule reconciliation
#   - system.gitops.reconcile  — worker-side cron tick (system worker)
#
# Reference: comprehensive stabilization sweep P5.
class SeedGitopsPermissions < ActiveRecord::Migration[8.1]
  PERMISSIONS = {
    "system.gitops.read" => {
      resource: "system.gitops", action: "read",
      description: "List and view GitOps repositories + sync runs"
    },
    "system.gitops.write" => {
      resource: "system.gitops", action: "write",
      description: "Create, update, and destroy GitOps repositories"
    },
    "system.gitops.sync" => {
      resource: "system.gitops", action: "sync",
      description: "Trigger an on-demand GitOps reconciliation tick"
    },
    "system.gitops.reconcile" => {
      resource: "system.gitops", action: "reconcile",
      description: "Drive the scheduled GitOps reconciliation tick (worker-side)"
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
  end

  def down
    return unless table_exists?(:permissions)

    ::Permission.where(name: PERMISSIONS.keys).destroy_all
  end
end
