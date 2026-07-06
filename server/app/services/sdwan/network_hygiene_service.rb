# frozen_string_literal: true

module Sdwan
  # Overlay-network hygiene — opt-in TTL + GC for ephemeral/test SDWAN
  # networks. Mirrors System::InstancePoolService's TTL-reaper shape
  # (recycle_stale_members!: a per-row metadata TTL, resolved with a
  # baked-in default, swept by a class-method pass) applied to
  # Sdwan::Network instead of System::NodeInstance.
  #
  # A network is eligible for GC only when BOTH:
  #   1. It carries an explicit `metadata["expires_at"]` (set via
  #      mark_for_gc! or directly) that has passed.
  #   2. It has zero peers — a network with even one peer, healthy or
  #      dead, is never touched here. Cleaning up networks that still carry
  #      dead (terminated-instance) peers is a reviewed, one-time action
  #      (see Sdwan::DebrisReport), not an automatic sweep.
  #
  # Networks with no explicit expiry are NEVER swept, regardless of age —
  # opt-in only, so a long-lived network already in the database is never
  # surprised into cleanup by this feature shipping.
  #
  # GC does not hard-delete: it archives (status: "archived"), matching the
  # network model's own documented lifecycle ("archived — read-only, audit
  # retention" — see Sdwan::Network's class comment). Reversible by an
  # operator flipping status back.
  class NetworkHygieneService
    DEFAULT_TTL_SECONDS = 7.days.to_i
    TTL_SETTING_KEY = "system.sdwan.network.gc_ttl_seconds"

    class << self
      # 3-tier resolution mirroring System::StorageMigration.cleanup_grace_hours:
      # 1) account override, 2) SiteSetting global default, 3) baked-in
      # default. No hardcoded constant reaches callers unqualified.
      def default_ttl_seconds(account: nil)
        account_value = account.respond_to?(:settings) ? account.settings&.dig(TTL_SETTING_KEY) : nil
        return account_value.to_i if account_value.present?

        site_value = begin
          ::SiteSetting.get(TTL_SETTING_KEY)
        rescue StandardError
          nil
        end
        return site_value.to_i if site_value.present?

        DEFAULT_TTL_SECONDS
      end

      # Opt a network into GC — stamps metadata["expires_at"]. ttl_seconds
      # defaults through the same 3-tier resolution as gc_expired! uses.
      # A negative ttl_seconds is honored as-is (tests use it to mint an
      # already-expired network without freezing time).
      def mark_for_gc!(network, ttl_seconds: nil)
        ttl = ttl_seconds || default_ttl_seconds(account: network.account)
        network.update!(metadata: network.metadata.merge("expires_at" => (Time.current + ttl.seconds).iso8601))
      end

      # Archives every expired + empty network (scoped to `account` if
      # given; sweeps every account otherwise). Returns
      # { archived: [...ids], skipped_has_peers: [...ids] } for
      # observability. Never touches a network with any peers, and never
      # re-touches an already-archived one.
      def gc_expired!(account: nil)
        scope = account ? ::Sdwan::Network.where(account: account) : ::Sdwan::Network.all
        archived = []
        skipped_has_peers = []

        scope.where.not(status: "archived").find_each do |network|
          expires_at = parse_expires_at(network)
          next unless expires_at && expires_at < Time.current

          if network.peers.exists?
            skipped_has_peers << network.id
            next
          end

          network.update!(status: "archived")
          archived << network.id
        end

        if archived.any? || skipped_has_peers.any?
          Rails.logger.info(
            "[Sdwan::NetworkHygieneService] gc_expired!: archived=#{archived.size} skipped_has_peers=#{skipped_has_peers.size}"
          )
        end

        { archived: archived, skipped_has_peers: skipped_has_peers }
      end

      private

      # Defensive parsing mirrors System::InstancePoolService's
      # stale_claimed flagged_at handling — a malformed value must never
      # abort the whole sweep for every other network.
      def parse_expires_at(network)
        raw = network.metadata.is_a?(Hash) ? network.metadata["expires_at"] : nil
        return nil if raw.blank?

        Time.zone.parse(raw.to_s)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
