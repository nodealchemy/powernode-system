# frozen_string_literal: true

module Powernode
  # Service-startup helper for discovering platform peer endpoints.
  #
  # A Sidekiq worker on Node B at startup calls
  # `Powernode::Bootstrap.discover_peer(:api, account: account)` to learn
  # the SDWAN VIP (or fallback DNS hostname) for the Rails API tier on
  # Node A. Result is cached per-process with a TTL so repeated lookups
  # are cheap.
  #
  # Plan reference: Decentralized Federation §G + P2.4.
  #
  # Usage:
  #
  #   # Get the PlatformDeployment row for the api tier
  #   Powernode::Bootstrap.discover_peer(:api, account: account)
  #   #=> #<System::PlatformDeployment id: ..., service_role: "api", ...>
  #
  #   # Get a dial URL (VIP first, DNS fallback) for the api tier on :3000
  #   Powernode::Bootstrap.endpoint_for(:api, port: 3000, account: account)
  #   #=> "https://fd00:beef::42:3000"
  #
  #   # Force re-read (skip cache)
  #   Powernode::Bootstrap.discover_peer(:api, account: account, refresh: true)
  #
  #   # Clear the entire cache (called by FleetEvent subscriber)
  #   Powernode::Bootstrap.invalidate!
  module Bootstrap
    DEFAULT_CACHE_TTL = 60 # seconds

    class << self
      # Returns the PlatformDeployment for `role` within `account`, or nil
      # if no deployment exists. Cached for `DEFAULT_CACHE_TTL` seconds.
      def discover_peer(role, account:, refresh: false)
        key = cache_key(role, account)
        invalidate_key(key) if refresh

        cached = cache_get(key)
        return cached if cached

        deployment = ::System::PlatformDeployment
          .where(account: account, service_role: role.to_s)
          .for_mainline
          .order(target_replicas: :desc, created_at: :asc)
          .first

        cache_set(key, deployment) if deployment
        deployment
      end

      # Returns the preferred dial URL for a service role + port.
      # Walks the same VIP→DNS priority as PlatformDeployment#dial_candidates.
      # Returns nil if no deployment found or no endpoint configured.
      def endpoint_for(role, port: nil, account:, refresh: false)
        deployment = discover_peer(role, account: account, refresh: refresh)
        return nil unless deployment

        candidates = deployment.dial_candidates(port: port)
        candidates.first&.dig(:url)
      end

      # Returns all dial candidates (priority-ordered) for a role.
      # Used by Federation::EndpointProber (P2.5+) for fast-fail probing.
      def dial_candidates(role, port: nil, account:, refresh: false)
        deployment = discover_peer(role, account: account, refresh: refresh)
        deployment ? deployment.dial_candidates(port: port) : []
      end

      # Invalidate the cache entirely. Called by a FleetEvent subscriber
      # on `platform.deployment.*` so the next discover_peer re-reads
      # from the DB rather than returning a stale cache hit.
      def invalidate!
        cache_mutex.synchronize { @cache = {} }
      end

      # Invalidate a single account+role pair. Useful when a single
      # deployment changes and we don't want to clear the global cache.
      def invalidate(role, account:)
        invalidate_key(cache_key(role, account))
      end

      # Test hook: override the TTL.
      attr_writer :cache_ttl

      def cache_ttl
        @cache_ttl ||= DEFAULT_CACHE_TTL
      end

      private

      def cache_key(role, account)
        account_id = account.respond_to?(:id) ? account.id : account
        "#{account_id}:#{role}"
      end

      def cache_get(key)
        cache_mutex.synchronize do
          entry = (@cache ||= {})[key]
          return nil unless entry
          return nil if entry[:expires_at] < Time.current

          entry[:value]
        end
      end

      def cache_set(key, value)
        cache_mutex.synchronize do
          (@cache ||= {})[key] = { value: value, expires_at: Time.current + cache_ttl }
        end
      end

      def invalidate_key(key)
        cache_mutex.synchronize { (@cache ||= {}).delete(key) }
      end

      def cache_mutex
        @cache_mutex ||= Mutex.new
      end
    end
  end
end
