# frozen_string_literal: true

require "rails_helper"
require "openssl"

# Federation mTLS Phase 2 (S5.4) — per-peer cert binding.
#
# Symmetric peers sign with their OWN CA, exchanged at accept and stored as
# peer.trusted_ca_pem. An inbound cert must verify against THAT peer's anchor,
# so one trusted peer cannot present a cert in another peer's name (the
# cross-peer impersonation guard a pooled trust bundle would allow).
RSpec.describe "Federation per-peer mTLS binding", type: :request do
  let(:account) { create(:account) }
  let(:path)    { "/api/v1/system/federation_api/heartbeat" }

  def build_ca
    key  = OpenSSL::PKey.generate_key("ED25519")
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2; cert.serial = 1
    cert.not_before = Time.now - 60; cert.not_after = Time.now + 3600
    cert.subject = OpenSSL::X509::Name.parse("/CN=Peer CA"); cert.issuer = cert.subject
    cert.public_key = key
    ef = OpenSSL::X509::ExtensionFactory.new(cert, cert)
    cert.add_extension(ef.create_extension("basicConstraints", "CA:TRUE", true))
    cert.sign(key, nil)
    [ key, cert ]
  end

  def leaf_pem(cn, ca_key, ca_cert)
    key  = OpenSSL::PKey.generate_key("ED25519")
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2; cert.serial = 2
    cert.not_before = Time.now - 60; cert.not_after = Time.now + 3600
    cert.subject = OpenSSL::X509::Name.parse("/CN=#{cn}"); cert.issuer = ca_cert.subject
    cert.public_key = key
    cert.sign(ca_key, nil)
    cert.to_pem
  end

  def headers(cn, cert_pem)
    {
      "X-Forwarded-Tls-Client-Cert-Info" => CGI.escape(%(Subject="CN=#{cn}")),
      "X-Forwarded-Tls-Client-Cert"      => CGI.escape(cert_pem)
    }
  end

  let(:peer_ca) { build_ca }
  # A symmetric peer that signs with its OWN CA (stored as trusted_ca_pem).
  let(:peer) do
    p = create(:system_federation_peer, :platform, account: account, status: "active")
    p.update_columns(inbound_subject: "fed:#{p.id}", trusted_ca_pem: peer_ca[1].to_pem)
    p
  end

  it "accepts a cert signed by the peer's own CA" do
    cert = leaf_pem(peer.inbound_subject, peer_ca[0], peer_ca[1])
    post path, params: {}, headers: headers(peer.inbound_subject, cert), as: :json
    expect(response).to have_http_status(:ok)
  end

  it "REJECTS a cert signed by a DIFFERENT CA (cross-peer impersonation guard)" do
    other_ca = build_ca
    cert = leaf_pem(peer.inbound_subject, other_ca[0], other_ca[1])
    post path, params: {}, headers: headers(peer.inbound_subject, cert), as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  # IMP-01a02b0c — build_ca names every CA "/CN=Peer CA", exactly the shape
  # the fleet was in when every hub's root was "Powernode Internal CA
  # (local-dev)": the refusal must be attributable to a SPECIFIC anchor, which
  # only the fingerprint can do.
  it "names the anchor it checked against, by FINGERPRINT, when it refuses" do
    other_ca = build_ca
    expect(other_ca[1].subject.to_s).to eq(peer_ca[1].subject.to_s) # premise: DNs collide
    cert = leaf_pem(peer.inbound_subject, other_ca[0], other_ca[1])

    post path, params: {}, headers: headers(peer.inbound_subject, cert), as: :json

    message = response.parsed_body["error"] || response.parsed_body["message"]
    expect(message).to include(::Security::CaFingerprint.of(peer_ca[1]))
    expect(message).not_to include(::Security::CaFingerprint.of(other_ca[1]))
    # ...but NOT where that anchor came from: this renders on a 401 to an
    # unauthenticated caller whose peer was resolved from a forgeable header,
    # so it must not disclose whether trusted_ca_pem is configured.
    expect(message).not_to include("trusted_ca_pem")
  end
end
