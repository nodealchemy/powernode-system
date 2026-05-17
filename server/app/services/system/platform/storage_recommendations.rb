# frozen_string_literal: true

module System
  module Platform
    # Resolves recommended storage-volume sizes + mount points per
    # service role. Reads from the account's default Ai::MemoryPool at
    # key `powernode.storage_recommendations`; falls back to a baked-in
    # default when the key is missing (fresh platform, no prior writes).
    #
    # Shape stored in shared memory:
    #
    #   {
    #     "stateful_role_mounts" => {
    #       "postgres" => "/var/lib/postgresql",
    #       "redis"    => "/var/lib/redis",
    #       ...
    #     },
    #     "recommended_size_gb_by_role" => {
    #       "postgres" => 50,
    #       "redis"    => 5,
    #       ...
    #     },
    #     "updated_at" => "2026-05-17T..."
    #   }
    #
    # Operators (and autonomous agents) can update these via the
    # `platform.write_shared_memory` MCP tool; the orchestrator + chat
    # card pick up the new values on the next read with no redeploy.
    #
    # Plan reference: VOL.1 follow-up — operator-tunable storage policy.
    class StorageRecommendations
      KEY = "powernode.storage_recommendations"
      POOL_ID = "default"

      DEFAULTS = {
        "stateful_role_mounts" => {
          "postgres" => "/var/lib/postgresql",
          "redis" => "/var/lib/redis",
          "satellite-runtime" => "/var/lib/powernode-state"
        }.freeze,
        "recommended_size_gb_by_role" => {
          "postgres" => 50,
          "redis" => 5,
          "satellite-runtime" => 10
        }.freeze
      }.freeze

      class << self
        # Returns the full recommendations hash, merging stored values
        # over defaults so partial overrides work (e.g. operator stores
        # only `recommended_size_gb_by_role.postgres = 100` and the
        # rest of the defaults still apply).
        def fetch(account:)
          stored = read_from_memory(account)
          return DEFAULTS unless stored.is_a?(Hash)

          {
            "stateful_role_mounts" =>
              DEFAULTS["stateful_role_mounts"].merge(stored["stateful_role_mounts"] || {}),
            "recommended_size_gb_by_role" =>
              DEFAULTS["recommended_size_gb_by_role"].merge(stored["recommended_size_gb_by_role"] || {}),
            "updated_at" => stored["updated_at"]
          }
        end

        def mount_point_for(account:, role:)
          fetch(account: account)["stateful_role_mounts"][role.to_s] || "/var/lib/powernode-state"
        end

        def recommended_size_gb(account:, role:)
          fetch(account: account)["recommended_size_gb_by_role"][role.to_s] || 10
        end

        def stateful_role?(account:, role:)
          fetch(account: account)["stateful_role_mounts"].key?(role.to_s)
        end

        def stateful_roles(account:)
          fetch(account: account)["stateful_role_mounts"].keys
        end

        # Operator/agent update path. Writes a partial merge into shared
        # memory, preserving previously-set keys. Pass a hash with any
        # subset of: stateful_role_mounts, recommended_size_gb_by_role.
        def update!(account:, attrs:, agent: nil)
          pool = default_pool_for(account)
          return false unless pool

          # MemoryPool#write_data requires an agent_id with write
          # access. Resolution order:
          #   1. Explicit agent passed by caller
          #   2. Pool's owner_agent_id (the primary write-authorized agent)
          #   3. System Concierge agent for this account (well-known
          #      system-managed agent — always present on a seeded platform)
          #   4. Any agent owned by this account (last-resort)
          agent_id = agent&.id ||
                     pool.owner_agent_id ||
                     resolve_system_agent_id(account)
          return false unless agent_id

          merged = fetch(account: account).deep_merge(attrs.transform_keys(&:to_s))
          merged["updated_at"] = Time.current.iso8601

          pool.write_data(KEY, merged, agent_id: agent_id)
          true
        rescue StandardError => e
          ::Rails.logger.warn("[StorageRecommendations.update!] #{e.class}: #{e.message}")
          false
        end

        # Find a system-managed agent for non-agent-context writes
        # (e.g. MCP from a user-authenticated session, REST API, runner).
        def resolve_system_agent_id(account)
          # Prefer the seeded System Concierge — it's the canonical
          # "system operator" agent on every platform.
          concierge = ::Ai::Agent.where(account: account)
                                 .where("metadata ->> 'concierge_kind' = ?", "system_concierge")
                                 .first
          return concierge.id if concierge

          # Fall back to the account's first agent of any kind.
          ::Ai::Agent.where(account: account).order(:created_at).first&.id
        rescue StandardError
          nil
        end

        private

        # MemoryPool stores values via a dot-split nested path
        # (write_data uses `data.dig(*key.split("."))`). Our key
        # contains a `.` so we read with the same traversal — `read_data`
        # would do it but requires an agent_id for accessibility. We
        # mirror its dig logic directly so this helper is callable from
        # any context (system services, MCP tools, background jobs).
        def read_from_memory(account)
          pool = default_pool_for(account)
          return nil unless pool

          data = pool.data || {}
          data.dig(*KEY.split("."))
        rescue StandardError => e
          ::Rails.logger.warn("[StorageRecommendations.read] #{e.class}: #{e.message}")
          nil
        end

        def default_pool_for(account)
          return nil unless account
          account.ai_memory_pools.find_by(pool_id: POOL_ID)
        rescue StandardError
          nil
        end
      end
    end
  end
end
