# frozen_string_literal: true

# Seeds permissions for the architecture catalog AI-first design:
#
# - system.architectures.read    — already seeded historically; included
#                                   here for idempotency in fresh DBs.
# - system.architectures.manage  — platform admins: direct CRUD on
#                                   non-canonical custom rows.
# - system.architectures.propose — broader: any operator/agent can
#                                   propose a new arch; approval gates
#                                   materialization.
#
# This mirrors the system.package_repositories permission shape (read +
# manage_shared) and the SDWAN VIPs shape (read + manage). Splitting
# `manage` from `propose` lets unprivileged AI agents surface needs for
# human review without granting them direct mutation power on the
# fleet's architecture catalog.
#
# Reference: i-would-like-to-zesty-glade.md Tier 1 — T1.A + T1.B.
class SeedArchitectureManagementPermissions < ActiveRecord::Migration[8.1]
  PERMISSIONS = [
    { name: "system.architectures.read",    category: "resource", action: "read",
      resource: "architectures",
      description: "View the system architecture catalog (canonical + custom)" },
    { name: "system.architectures.manage",  category: "resource", action: "manage",
      resource: "architectures",
      description: "Create, update, or delete non-canonical custom architectures. Canonical rows remain immutable via the API." },
    { name: "system.architectures.propose", category: "resource", action: "propose",
      resource: "architectures",
      description: "Propose a new architecture for human review. Lower bar than `manage` — unprivileged operators and AI agents use this to surface needs." }
  ].freeze

  def up
    return unless defined?(::Permission)

    PERMISSIONS.each do |attrs|
      ::Permission.find_or_create_by!(name: attrs[:name]) do |p|
        p.category    = attrs[:category]    if p.respond_to?(:category=)
        p.action      = attrs[:action]      if p.respond_to?(:action=)
        p.resource    = attrs[:resource]    if p.respond_to?(:resource=)
        p.description = attrs[:description] if p.respond_to?(:description=)
      end
    end
  end

  def down
    return unless defined?(::Permission)

    # Don't yank `system.architectures.read` — it pre-existed.
    ::Permission.where(name: %w[system.architectures.manage system.architectures.propose]).delete_all
  end
end
