# frozen_string_literal: true

# Sdwan::FederationGovernance — read-only scanner over Sdwan::FederationPeer
# rows. Returns findings that operators (or a future scheduled
# governance_scan job) can act on.
#
# Two finding types in v1:
#
#   prefix_overlap_with_install
#     A FederationPeer's remote_prefix_advertisement overlaps with this
#     install's own prefix_40 root. Rare (random /40 + /48 collisions are
#     2^-8 per pair) but governance-critical when it happens — the
#     federation slice's eventual cross-instance routing math depends on
#     non-overlap. Surfacing as a warning before activation lets operators
#     re-roll the federation peer's prefix proposal.
#
#   stale_accepted_without_handshake
#     A peer in `accepted` status with no signed_at OR an expires_at in
#     the past. Indicates an operator-accepted federation that was never
#     completed (the cross-CA handshake fell through, or the trust JWT
#     expired before activation). Cleanup: revoke and re-propose.
#
# Slice 6 of the SDWAN plan.
module Sdwan
  class FederationGovernance
    SEVERITY_BY_KIND = {
      prefix_overlap_with_install:        :critical,
      prefix_overlap_with_other_peer:     :high,
      stale_accepted_without_handshake:   :medium,
      expired_trust_jwt:                  :high
    }.freeze

    # Returns an array of finding hashes:
    #   { kind:, severity:, federation_peer_id:, message:, payload: }
    def self.scan(account:)
      new(account: account).scan
    end

    def initialize(account:)
      @account = account
    end

    def scan
      findings = []
      peers = ::Sdwan::FederationPeer.where(account_id: @account.id).to_a

      install_prefix_48 = derive_install_prefix_48
      seen_prefixes = {} # remote_prefix_48 → first peer that claimed it

      peers.each do |peer|
        # 1. Overlap with our own /48
        if install_prefix_48 && peer.remote_prefix_48 && peer.remote_prefix_48 == install_prefix_48
          findings << build_finding(
            :prefix_overlap_with_install, peer,
            "Federation peer's remote_prefix_advertisement (#{peer.remote_prefix_advertisement}) " \
            "overlaps with this install's account prefix (#{install_prefix_48}). " \
            "Revoke and re-propose with a different prefix."
          )
        end

        # 2. Overlap between two federation peers
        if peer.remote_prefix_48
          if (other = seen_prefixes[peer.remote_prefix_48])
            findings << build_finding(
              :prefix_overlap_with_other_peer, peer,
              "Federation peer claims the same /48 (#{peer.remote_prefix_48}) as peer #{other.id}. " \
              "Two federations cannot share an address space without NAT64-style remapping " \
              "(deferred; not in v1)."
            )
          else
            seen_prefixes[peer.remote_prefix_48] = peer
          end
        end

        # 3. Stale accepted (status=accepted but no signed_at) — slice 6
        # never produces this state itself (V1_TRANSITIONS gates it), but
        # a future federation slice's accept flow could leave a row half-
        # transitioned on error. Catching it now keeps the data clean.
        if peer.status == "accepted" && peer.signed_at.nil?
          findings << build_finding(
            :stale_accepted_without_handshake, peer,
            "Peer is in `accepted` status but has no signed_at — the cross-CA " \
            "handshake never completed. Revoke and re-propose."
          )
        end

        # 4. Expired trust JWT
        if peer.expires_at && peer.expires_at < Time.current && peer.status != "revoked"
          findings << build_finding(
            :expired_trust_jwt, peer,
            "Trust JWT expired at #{peer.expires_at.utc.iso8601}. " \
            "Revoke and re-propose with a fresh JWT."
          )
        end
      end

      findings
    end

    private

    def build_finding(kind, peer, message)
      {
        kind: kind,
        severity: SEVERITY_BY_KIND.fetch(kind, :medium),
        federation_peer_id: peer.id,
        message: message,
        payload: {
          account_id: peer.account_id,
          remote_instance_url: peer.remote_instance_url,
          remote_prefix_advertisement: peer.remote_prefix_advertisement,
          status: peer.status,
          signed_at: peer.signed_at&.iso8601,
          expires_at: peer.expires_at&.iso8601
        }
      }
    end

    # Derive the /48 portion of this account's install prefix. The
    # PrefixAllocator stores the account's /48 directly on
    # Sdwan::Configuration.account_prefix_48 — that's what governance
    # needs to compare against.
    def derive_install_prefix_48
      cfg = ::Sdwan::Configuration.find_by(account_id: @account.id)
      cfg&.account_prefix_48
    end
  end
end
