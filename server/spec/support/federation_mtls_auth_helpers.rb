# frozen_string_literal: true

# Federation mTLS Phase 2 request-spec helpers.
#
# Inbound federation_api auth resolves a peer by the CN the reverse proxy
# forwards — which is the peer's `inbound_subject` (the `fed:<peer.id>`
# identity we assign at accept). Traefik does the cryptographic verification;
# the app maps the verified CN → peer row. These helpers build a reachable
# platform peer carrying an inbound_subject plus the matching forwarded header,
# so request specs don't re-implement the handshake plumbing.
module FederationMtlsAuthHelpers
  # The header Traefik's passTLSClientCert middleware forwards for `subject`.
  def federation_cert_info_header(subject)
    { "X-Forwarded-Tls-Client-Cert-Info" => CGI.escape(%(Subject="CN=#{subject}")) }
  end

  # Header for an already-built peer (uses its inbound_subject).
  def federation_mtls_headers(peer)
    federation_cert_info_header(peer.inbound_subject)
  end

  # A reachable platform peer that can authenticate to federation_api. The
  # inbound_subject is stamped to fed:<peer.id> (exactly what the acceptance
  # service assigns) unless an explicit one is supplied.
  def enrolled_federation_peer(account:, status: "enrolled", inbound_subject: nil, **attrs)
    peer = create(:system_federation_peer, :platform, account: account, status: status, **attrs)
    peer.update_column(:inbound_subject, inbound_subject || "fed:#{peer.id}")
    peer
  end
end

RSpec.configure do |config|
  config.include FederationMtlsAuthHelpers, type: :request
end
