# frozen_string_literal: true

module Federation
  # Federation mTLS Phase 2 (symmetric) — periodic trust-anchor refresh.
  #
  # Symmetric peers sign with their own CA; when a peer rotates that CA, our
  # stored trusted_ca_pem goes stale and we'd reject its new certs. This sweep
  # re-fetches each symmetric peer's current CA bundle from its
  # /federation_api/trust_bundle endpoint, updates trusted_ca_pem when it
  # changed, then rewrites the Traefik client-auth bundle so the new anchor is
  # honored at the handshake. Mirrors the SPIFFE bundle-endpoint refresh;
  # designed to run on the heartbeat cadence via a worker job.
  class TrustBundleRefreshService
    Result = ::Struct.new(:checked, :updated, :failures, keyword_init: true)

    class << self
      def run!(account: nil, client_factory: nil)
        new(account: account, client_factory: client_factory).run!
      end
    end

    def initialize(account: nil, client_factory: nil)
      @account = account
      @client_factory = client_factory || ->(peer) { ::Federation::PeerClient.new(peer: peer) }
    end

    def run!
      checked = 0
      updated = 0
      failures = []

      symmetric_peers.find_each do |peer|
        checked += 1
        begin
          fresh = fetch_bundle(peer)
          next if fresh.blank?
          next if normalize(fresh) == normalize(peer.trusted_ca_pem)

          peer.update!(trusted_ca_pem: fresh)
          updated += 1
        rescue ::StandardError => e
          failures << { peer_id: peer.id, error: "#{e.class}: #{e.message}" }
          ::Rails.logger.warn("[TrustBundleRefreshService] peer=#{peer.id} #{e.class}: #{e.message}")
        end
      end

      rewrite_bundle! if updated.positive?
      Result.new(checked: checked, updated: updated, failures: failures)
    end

    private

    # Symmetric peers are the reachable platform peers carrying a peer CA anchor
    # (hierarchical children sign off our own CA and have none).
    def symmetric_peers
      scope = ::System::FederationPeer.platform_peers.reachable.where.not(trusted_ca_pem: [ nil, "" ])
      scope = scope.where(account: @account) if @account
      scope
    end

    def fetch_bundle(peer)
      @client_factory.call(peer).fetch_trust_bundle["ca_bundle_pem"]
    end

    def normalize(pem)
      pem.to_s.strip
    end

    def rewrite_bundle!
      return unless defined?(::Acme::TraefikConfigWriter)

      ::Acme::TraefikConfigWriter.write_client_auth_bundle!
    rescue ::StandardError => e
      ::Rails.logger.warn("[TrustBundleRefreshService] bundle rewrite failed: #{e.message}")
    end
  end
end
