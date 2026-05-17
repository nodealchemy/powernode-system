# frozen_string_literal: true

module System
  module Platform
    # Computes intelligent subpath layouts for storage volumes shared
    # across deployments. The convention is:
    #
    #   <export-root>/
    #     deployments/
    #       <deployment-name>/
    #         <role>/          ← per-component data (postgres / redis / etc.)
    #     shared/
    #       acme/              ← cross-deployment certs + account keys
    #       traefik-config/    ← shared proxy config
    #     migrations/
    #       <iso-date>/<deployment>/<role>/   ← migration snapshots
    #
    # This isolation enables:
    #   - One NFS export hosting many stateful deployments concurrently
    #   - Migrating any single <deployment>/<role> to a different volume
    #     without touching the others
    #   - Snapshot/rollback per-component (the migrations/ tree)
    #
    # Plan reference: NFS multi-tenant storage + per-component migration.
    class StorageLayout
      # Canonical sub-directories under the export root.
      DEPLOYMENTS_PREFIX = "deployments"
      SHARED_PREFIX      = "shared"
      MIGRATIONS_PREFIX  = "migrations"

      # Roles that participate in the shared/ namespace rather than
      # owning per-deployment subdirs. ACME state is shared across
      # all deployments in an account because the cert account key is
      # account-scoped.
      SHARED_ROLES = %w[acme-shared traefik-shared].freeze

      class << self
        # Returns the subpath (relative to the NFS export root) where
        # the given (deployment_name, role) pair should mount.
        #
        # Examples:
        #   subpath_for("hub-east-1", "postgres")
        #     => "deployments/hub-east-1/postgres"
        #   subpath_for(nil, "acme-shared")
        #     => "shared/acme"
        #
        # Always returns a path WITHOUT a leading slash so callers can
        # join it with whatever export root they're using.
        def subpath_for(deployment_name:, role:)
          if SHARED_ROLES.include?(role.to_s)
            shared_subpath_for(role)
          else
            slug = slugify(deployment_name.to_s.presence || "_unnamed")
            "#{DEPLOYMENTS_PREFIX}/#{slug}/#{role}"
          end
        end

        # Returns the full export path including the NFS server's export
        # root. For NFS, this is what the mount command needs:
        #   <server>:<export_root>/<subpath>
        def full_nfs_path(volume:, deployment_name:, role:)
          return nil unless volume&.config&.dig("nfs", "export_path")

          root = volume.config["nfs"]["export_path"].sub(%r{/\z}, "")
          sub  = subpath_for(deployment_name: deployment_name, role: role)
          "#{root}/#{sub}"
        end

        # Migration target subpath — same shape as the live path but
        # under migrations/<iso-date>. The orchestrator's migration
        # helper creates this subpath, rsyncs data to it, then promotes
        # by swapping the live binding.
        def migration_subpath_for(deployment_name:, role:, at: Time.current)
          date_slug = at.utc.strftime("%Y%m%dT%H%M%SZ")
          slug = slugify(deployment_name.to_s.presence || "_unnamed")
          "#{MIGRATIONS_PREFIX}/#{date_slug}/#{slug}/#{role}"
        end

        # Lists the subpaths the orchestrator should ensure exist on the
        # mount before the on-node agent tries to use them. Returns a
        # flat list of subpath strings (relative to export root).
        def required_subpaths_for(deployment_name:, role:)
          base = subpath_for(deployment_name: deployment_name, role: role)
          [ base ]
        end

        # Convert a deployment name to a path-safe slug. Preserve
        # readability where possible (the operator picked the name);
        # only strip what's hostile to NFS path semantics.
        def slugify(raw)
          raw.to_s.downcase
             .gsub(/[^a-z0-9_\-\.]/, "-")
             .gsub(/-+/, "-")
             .gsub(/^-|-$/, "")
             .slice(0, 80)
             .presence || "_unnamed"
        end

        private

        def shared_subpath_for(role)
          case role.to_s
          when "acme-shared"   then "#{SHARED_PREFIX}/acme"
          when "traefik-shared" then "#{SHARED_PREFIX}/traefik-config"
          else                       "#{SHARED_PREFIX}/#{slugify(role)}"
          end
        end
      end
    end
  end
end
