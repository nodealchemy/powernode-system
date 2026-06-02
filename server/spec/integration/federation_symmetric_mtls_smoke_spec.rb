# frozen_string_literal: true

require "rails_helper"
require "openssl"
require "tmpdir"

# Federation mTLS Phase 2 — SYMMETRIC two-platform end-to-end smoke.
#
# Models two independent platforms (A, B), each with its OWN internal CA, and
# drives the full symmetric handshake + bidirectional mTLS verification with
# REAL crypto (two distinct LocalCaAdapter roots) — the closest single-process
# proof of the symmetric trust model short of two live reverse proxies:
#
#   1. A establishes trust from B's accept request (stores B's CA, self-issues
#      A's outbound cert off A's CA with the CN B assigned).
#   2. B absorbs A's response (stores A's CA, self-issues B's outbound cert).
#   3. B->A and A->B both resolve the peer by inbound_subject and verify the
#      presented cert against the EXCHANGED per-peer anchor.
#   4. A foreign-CA cert (cloned CN) is rejected; a peer cert cannot impersonate
#      a node (verified against OUR CA only).
RSpec.describe "Federation symmetric mTLS — two-platform smoke", type: :model do
  let(:account) { create(:account) }

  # Two distinct on-disk CA roots → two independent platform CAs.
  let(:dir_a) { Dir.mktmpdir("ca-a") }
  let(:dir_b) { Dir.mktmpdir("ca-b") }
  let(:ca_a)  { build_ca(dir_a) }
  let(:ca_b)  { build_ca(dir_b) }

  after do
    System::InternalCaService.reset!
    FileUtils.rm_rf(dir_a)
    FileUtils.rm_rf(dir_b)
  end

  # A LocalCaAdapter rooted at its own dir (best-effort persistence → each dir
  # yields a distinct root).
  def build_ca(dir)
    prev = ENV["POWERNODE_CA_LOCAL_DIR"]
    ENV["POWERNODE_CA_LOCAL_DIR"] = dir
    System::InternalCaService::LocalCaAdapter.new
  ensure
    prev ? (ENV["POWERNODE_CA_LOCAL_DIR"] = prev) : ENV.delete("POWERNODE_CA_LOCAL_DIR")
  end

  # Run a block "as" the platform whose internal CA is `ca`.
  def as_platform(ca)
    System::InternalCaService.adapter = ca
    yield
  end

  # Mint a leaf with `cn` signed by `ca` (used to forge a foreign cert).
  def mint_cert(ca, cn)
    prepared = Federation::OutboundIdentityService.prepare_csr(common_name: cn)
    as_platform(ca) do
      System::InternalCaService.issue_certificate(csr_pem: prepared.csr_pem, common_name: cn)[:cert_pem]
    end
  end

  def cn_of(cert_pem)
    OpenSSL::X509::Certificate.new(cert_pem).subject.to_a.find { |n, _, _| n == "CN" }[1]
  end

  # A's row representing B, and B's row representing A.
  let!(:peer_b_on_a) { create(:system_federation_peer, :platform, account: account, status: "accepted") }
  let!(:peer_a_on_b) { create(:system_federation_peer, :platform, account: account, status: "accepted") }

  it "completes the symmetric handshake + bidirectional mTLS with two real CAs" do
    # ── Handshake ───────────────────────────────────────────────────────
    response = as_platform(ca_a) do
      Federation::PeerTrustService.establish_from_request!(
        peer: peer_b_on_a,
        peer_ca_bundle_pem: ca_b.ca_chain_pem,
        caller_inbound_subject: "fed:#{peer_a_on_b.id}" # CN A must present to B
      )
    end
    expect(response[:assigned_inbound_subject]).to eq("fed:#{peer_b_on_a.id}")
    expect(response[:ca_bundle_pem]).to eq(ca_a.ca_chain_pem)

    as_platform(ca_b) do
      Federation::PeerTrustService.absorb_response!(
        peer: peer_a_on_b,
        ca_bundle_pem: response[:ca_bundle_pem],
        assigned_inbound_subject: response[:assigned_inbound_subject]
      )
    end

    peer_b_on_a.reload
    peer_a_on_b.reload

    # Each side trusts the OTHER's CA and holds its own self-issued outbound cert.
    expect(peer_b_on_a.trusted_ca_pem).to eq(ca_b.ca_chain_pem)
    expect(peer_a_on_b.trusted_ca_pem).to eq(ca_a.ca_chain_pem)

    a_cert = peer_b_on_a.outbound_certificate.credentials["cert_pem"] # A→B, signed ca_a
    b_cert = peer_a_on_b.outbound_certificate.credentials["cert_pem"] # B→A, signed ca_b
    expect(cn_of(a_cert)).to eq("fed:#{peer_a_on_b.id}")
    expect(cn_of(b_cert)).to eq("fed:#{peer_b_on_a.id}")

    # ── B → A: resolve by inbound_subject + verify against B's CA ────────
    resolved = System::FederationPeer.platform_peers.find_by(inbound_subject: cn_of(b_cert))
    expect(resolved).to eq(peer_b_on_a)
    vr = Security::MtlsClientVerifier.verify(cert_pem: b_cert, anchors: [ resolved.trusted_ca_pem ])
    expect(vr.verified?).to be(true)
    expect(vr.subject_cn).to eq(resolved.inbound_subject)

    # ── A → B: the reverse direction verifies too ───────────────────────
    resolved2 = System::FederationPeer.platform_peers.find_by(inbound_subject: cn_of(a_cert))
    expect(resolved2).to eq(peer_a_on_b)
    expect(Security::MtlsClientVerifier.verify(cert_pem: a_cert, anchors: [ resolved2.trusted_ca_pem ]).verified?).to be(true)

    # ── Negative: a foreign-CA cert cloning B's CN is rejected at A ──────
    dir_x = Dir.mktmpdir("ca-x")
    ca_x  = build_ca(dir_x)
    forged = mint_cert(ca_x, "fed:#{peer_b_on_a.id}")
    expect(Security::MtlsClientVerifier.verify(cert_pem: forged, anchors: [ peer_b_on_a.trusted_ca_pem ]).verified?).to be(false)
    FileUtils.rm_rf(dir_x)

    # ── Negative: B's peer cert cannot impersonate a node (vs OUR CA) ────
    expect(Security::MtlsClientVerifier.verify(cert_pem: b_cert, anchors: [ ca_a.ca_chain_pem ]).verified?).to be(false)
  end
end
