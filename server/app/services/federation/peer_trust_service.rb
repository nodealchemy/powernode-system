# frozen_string_literal: true

module Federation
  # Federation mTLS Phase 2 (SYMMETRIC) — the trust-anchor exchange between
  # peers of equals (neither is the other's CA). Centralizes BOTH sides of the
  # exchange so the acceptance service (server side) and the accept-initiator
  # (caller side) share one audited path.
  #
  # After the exchange each side holds, for the peer relationship:
  #   - trusted_ca_pem      : the OTHER side's CA (so we trust certs it signs,
  #                           verified per-peer in FederationApi::BaseController)
  #   - inbound_subject     : the CN the other side presents to us — we assign
  #                           it, always "fed:<our local peer id>" (unique)
  #   - outbound_certificate: our cert, signed by OUR CA, whose CN is the
  #                           inbound_subject the OTHER side assigned us; we
  #                           present it when calling them
  #
  # Hierarchical peers do NOT use this — the parent signs the child's CSR off a
  # single shared CA (see FederationAcceptanceService#sign_federation_csr!).
  class PeerTrustService
    class << self
      # SERVER side (the accepting platform). Reads what the caller advertised
      # in the accept request; returns what to echo back in the response.
      #
      # @param peer [System::FederationPeer] our row representing the caller
      # @param peer_ca_bundle_pem [String] the caller's CA (we will trust it)
      # @param caller_inbound_subject [String] the CN the caller wants US to
      #        present when calling THEM (they assigned it)
      # @return [Hash] { ca_bundle_pem:, assigned_inbound_subject: }
      def establish_from_request!(peer:, peer_ca_bundle_pem:, caller_inbound_subject:)
        assigned = "fed:#{peer.id}"
        store_trust!(
          peer: peer,
          trusted_ca_pem: peer_ca_bundle_pem,
          our_inbound_subject: assigned,
          present_as: caller_inbound_subject
        )
        {
          ca_bundle_pem: ::System::InternalCaService.ca_chain_pem,
          assigned_inbound_subject: assigned
        }
      end

      # CALLER side (the joining platform). Absorbs the accept response.
      #
      # @param peer [System::FederationPeer] our row representing the accepter
      # @param ca_bundle_pem [String] the accepter's CA (we will trust it)
      # @param assigned_inbound_subject [String] the CN the accepter wants US
      #        to present when calling THEM (they assigned it)
      def absorb_response!(peer:, ca_bundle_pem:, assigned_inbound_subject:)
        store_trust!(
          peer: peer,
          trusted_ca_pem: ca_bundle_pem,
          our_inbound_subject: "fed:#{peer.id}",
          present_as: assigned_inbound_subject
        )
        peer
      end

      private

      # Common storage: trust the other's CA, record the CN they present to us,
      # and self-issue (from our own CA) the cert we present back to them.
      def store_trust!(peer:, trusted_ca_pem:, our_inbound_subject:, present_as:)
        peer.update!(trusted_ca_pem: trusted_ca_pem, inbound_subject: our_inbound_subject)
        OutboundIdentityService.self_issue!(peer: peer, common_name: present_as) if present_as.present?
        refresh_client_auth_bundle!
      end

      # Rewrite Traefik's client-auth bundle so the newly-trusted peer CA is
      # honored at the handshake. Best-effort — the periodic refresh + next
      # reverse-proxy boot also rewrite it, so a hiccup never aborts the accept.
      def refresh_client_auth_bundle!
        return unless defined?(::Acme::TraefikConfigWriter)

        ::Acme::TraefikConfigWriter.write_client_auth_bundle!
      rescue StandardError => e
        ::Rails.logger.warn("[PeerTrustService] client-auth bundle refresh failed: #{e.class}: #{e.message}")
      end
    end
  end
end
