# frozen_string_literal: true

require "rails_helper"

# Confirms the system extension's engine initializer
# ("powernode_system.register_permissions", lib/powernode_system/engine.rb)
# actually granted the operator-facing CI worker / disk-image webhook / CI
# runner lease / disk-image rollback permissions to admin (+ manager for
# read-only) at boot (improvement 019f6479 — these names were declared in
# core server/config/permissions.rb's SYSTEM_PERMISSIONS hash but only
# reached system_worker by default, so a plain admin could not use the
# operator UI/API for them).
#
# Mirrors the shape of engine_permissions coverage already established for
# system.module_builds.read (see module_build_batches_spec.rb) and the
# registration-at-boot idiom used by ingress_provider_registration_spec.rb.
RSpec.describe "PowernodeSystem operator permission registration", type: :lib do
  ADMIN_READ_AND_MUTATE = %w[
    system.ci_workers.create
    system.ci_workers.delete
    system.ci_workers.rotate_token
    system.disk_image_webhooks.create
    system.disk_image_webhooks.delete
    system.disk_image_webhooks.rotate_secret
    system.platforms.rollback_disk_image
    system.platforms.manage_disk_image_policy
    system.ci_runner_leases.create
    system.ci_runner_leases.update
  ].freeze

  ADMIN_AND_MANAGER_READ = %w[
    system.ci_workers.read
    system.disk_image_webhooks.read
    system.ci_runner_leases.read
  ].freeze

  # Worker/webhook-only by explicit design — must NEVER reach admin/manager
  # even though they live in the same SYSTEM_PERMISSIONS block. Regression
  # guard against over-granting (see the engine.rb comment for the exclusion
  # rationale: leaked-CI-token blast radius / already-documented dispatch
  # scoping).
  WORKER_ONLY_EXCLUDED = %w[
    system.platforms.publish_disk_image
    system.module_builds.dispatch
  ].freeze

  it "every asserted permission name is a real catalog entry (no typos)" do
    (ADMIN_READ_AND_MUTATE + ADMIN_AND_MANAGER_READ + WORKER_ONLY_EXCLUDED).each do |name|
      expect(::Permissions.permission_exists?(name)).to be(true), "#{name} is not in Permissions.all_permissions"
    end
  end

  describe "admin role" do
    let(:granted) { ::Permissions.permissions_for_role("admin") }

    it "resolves the mutate-tier CI worker / disk-image webhook / rollback / lease permissions" do
      expect(granted).to include(*ADMIN_READ_AND_MUTATE)
    end

    it "resolves the read-tier permissions" do
      expect(granted).to include(*ADMIN_AND_MANAGER_READ)
    end

    it "does NOT resolve the worker/webhook-only excluded permissions" do
      expect(granted).not_to include(*WORKER_ONLY_EXCLUDED)
    end
  end

  describe "manager role" do
    let(:granted) { ::Permissions.permissions_for_role("manager") }

    it "resolves only the read-tier permissions" do
      expect(granted).to include(*ADMIN_AND_MANAGER_READ)
    end

    it "does NOT resolve the admin-only mutate-tier permissions" do
      expect(granted).not_to include(*ADMIN_READ_AND_MUTATE)
    end

    it "does NOT resolve the worker/webhook-only excluded permissions" do
      expect(granted).not_to include(*WORKER_ONLY_EXCLUDED)
    end
  end

  describe "system_worker role (regression: unaffected by this change)" do
    let(:granted) { ::Permissions.permissions_for_role("system_worker") }

    it "still resolves system.platforms.publish_disk_image and system.module_builds.dispatch via the raw SYSTEM_PERMISSIONS splat" do
      expect(granted).to include(*WORKER_ONLY_EXCLUDED)
    end
  end
end
