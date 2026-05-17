# frozen_string_literal: true

# Sdwan::FederationGovernance — read-only scanner over System::FederationPeer
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
      expired_trust_jwt:                  :high,
      # Added by P3.6 — platform-peer health checks. These only apply
      # to peers with peer_kind="platform"; sdwan_only rows skip them.
      peer_heartbeat_stale:               :medium,
      peer_capability_drift:              :medium,
      peer_cert_expiring:                 :medium,
      peer_cert_expired:                  :high,
      # P9.3 — Schema-version drift findings (per Social Contract #10).
      peer_schema_version_drift:          :medium,
      peer_schema_version_missing:        :low,
      # P9.4 — Data residency findings (per Social Contract #8).
      peer_residency_missing:             :low,
      # P9.5 — Multi-hop migration chain findings.
      migration_chain_stalled:            :medium,
      migration_chain_failed:             :high
    }.freeze

    # A chain is "stalled" if it's been in_flight without an audit-log
    # event for this long. The worker sweep skips stalled chains so
    # they don't churn; this finding surfaces them so the operator can
    # cancel or hand-advance.
    CHAIN_STALL_THRESHOLD = 1.hour

    # A failed chain is surfaced for this long before being demoted to
    # background. After the window passes, operators are expected to
    # have either retried, cancelled, or accepted the stuck position.
    CHAIN_FAILURE_VISIBILITY = 7.days

    # Default cert-expiry warning threshold (matches Social Contract #1
    # operational guidance — 30 days gives operators enough lead time to
    # coordinate rotation across a federation pair).
    CERT_EXPIRY_WARN_DAYS = 30

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
      peers = ::System::FederationPeer.where(account_id: @account.id).to_a

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

        # === Platform-peer checks (P3.6) ===
        next unless peer.platform_peer?

        # 5. Heartbeat stale (platform peers in active/enrolled with no
        # recent heartbeat). The HeartbeatSweepService transitions active
        # → degraded automatically; this finding surfaces the staleness
        # in the operator dashboard regardless of state.
        if peer.status.in?(%w[enrolled active]) && peer.heartbeat_stale?
          last_hb = peer.last_heartbeat_at&.utc&.iso8601 || "never"
          findings << build_finding(
            :peer_heartbeat_stale, peer,
            "Platform peer hasn't heartbeated since #{last_hb}. " \
            "Stale beyond #{::System::FederationPeer::HEARTBEAT_STALE_AFTER.inspect}."
          )
        end

        # 6. Capability drift — peer's advertised extension_slugs
        # don't match what was granted (capabilities key empty but
        # extension_slugs declared, or vice-versa). Indicates a
        # capability handshake that didn't fully complete.
        if peer.extension_slugs.any? && peer.capabilities.blank?
          findings << build_finding(
            :peer_capability_drift, peer,
            "Peer advertised extensions #{peer.extension_slugs.inspect} but " \
            "exchanged no capabilities. Re-handshake to re-establish capability grants."
          )
        end

        # 6a. P9.4 — Data residency declaration check. Active peers
        # are expected to declare data_residency per Social Contract
        # commitment #8. Silence on this is a low-severity nudge
        # (operator should ask their peer to upgrade or set residency).
        if peer.peer_kind == "platform" && peer.status == "active" && peer.data_residency.blank?
          findings << build_finding(
            :peer_residency_missing, peer,
            "Active peer has not declared data_residency per Social Contract #8. " \
            "Ask the remote operator to set POWERNODE_DATA_RESIDENCY and re-heartbeat."
          )
        end

        # 6b. P9.3 — Schema version drift. Two flavors:
        #   - missing: peer is `active` but hasn't reported a
        #     platform_version yet. They're running an older release
        #     that doesn't include the version-handshake hook.
        #   - drift: pair's negotiated outcome is not "compatible".
        #     Operator should pin an override row or schedule the
        #     remote to upgrade.
        if peer.peer_kind == "platform" && peer.status == "active"
          if peer.platform_version.blank?
            findings << build_finding(
              :peer_schema_version_missing, peer,
              "Peer is active but hasn't reported a platform_version. " \
              "Likely running a pre-P9.3 release without the schema-version handshake."
            )
          else
            negotiation = ::Federation::SchemaVersionNegotiator.negotiate(
              remote_version: peer.platform_version
            )
            unless negotiation.compatible?
              findings << build_finding(
                :peer_schema_version_drift, peer,
                "Peer's platform_version #{peer.platform_version.inspect} is " \
                "#{negotiation.status} with ours " \
                "(#{::Federation::SchemaVersionNegotiator.current_platform_version}); " \
                "source=#{negotiation.source}. #{negotiation.notes}"
              )
            end
          end
        end

        # 7. Cert expiring / expired (when a node_certificate is bound).
        if peer.node_certificate && peer.node_certificate.not_after
          days_remaining = ((peer.node_certificate.not_after - Time.current) / 1.day).to_i
          if days_remaining < 0
            findings << build_finding(
              :peer_cert_expired, peer,
              "Peer's federation cert expired #{-days_remaining} day(s) ago " \
              "(#{peer.node_certificate.not_after.utc.iso8601}). Rotate immediately."
            )
          elsif days_remaining <= CERT_EXPIRY_WARN_DAYS
            findings << build_finding(
              :peer_cert_expiring, peer,
              "Peer's federation cert expires in #{days_remaining} day(s) " \
              "(#{peer.node_certificate.not_after.utc.iso8601}). Plan rotation."
            )
          end
        end
      end

      # P9.5 — Multi-hop migration chain findings. Iterates over chains
      # owned by the account (not per-peer); the finding's
      # federation_peer_id is set to the destination of the hop where
      # the chain stuck, when discoverable. Defined as `System::*`
      # records so wrapped in `defined?` to keep the system extension
      # optional at boot in core mode.
      if defined?(::System::MigrationChain)
        findings.concat(scan_migration_chains)
      end

      findings
    end

    private

    def scan_migration_chains
      chain_findings = []
      now = ::Time.current

      ::System::MigrationChain.where(account_id: @account.id).find_each do |chain|
        if chain.status == "in_flight" && chain_stalled?(chain, now: now)
          hop = chain.current_hop_migration
          chain_findings << build_chain_finding(
            :migration_chain_stalled, chain, peer_id: hop&.destination_peer_id,
            message: "Multi-hop migration chain has been in_flight without progress " \
                     "for longer than #{CHAIN_STALL_THRESHOLD.inspect}. " \
                     "Hop position #{chain.current_hop_index} (destination peer " \
                     "#{hop&.destination_peer_id || 'unknown'}) is wedged. " \
                     "Cancel and recompose, or manually advance after fixing the destination."
          )
        end

        if chain.status == "failed" && chain.failed_at && chain.failed_at > (now - CHAIN_FAILURE_VISIBILITY)
          chain_findings << build_chain_finding(
            :migration_chain_failed, chain, peer_id: nil,
            message: "Multi-hop migration chain failed at hop position " \
                     "#{chain.current_hop_index}. UUID currently lives at the " \
                     "destination of hop #{chain.current_hop_index - 1}. " \
                     "#{chain.error_message.to_s[0, 240]}"
          )
        end
      end

      chain_findings
    end

    def chain_stalled?(chain, now:)
      anchor =
        chain.audit_log
          .filter_map { |e| ::Time.zone.parse(e["at"].to_s) rescue nil }
          .max || chain.started_at
      return false unless anchor
      anchor < (now - CHAIN_STALL_THRESHOLD)
    end

    def build_chain_finding(kind, chain, peer_id:, message:)
      {
        kind: kind,
        severity: SEVERITY_BY_KIND.fetch(kind, :medium),
        federation_peer_id: peer_id,
        message: message,
        payload: {
          account_id: chain.account_id,
          migration_chain_id: chain.id,
          status: chain.status,
          current_hop_index: chain.current_hop_index,
          total_hops: chain.total_hops,
          operation: chain.operation,
          root_resource_kind: chain.root_resource_kind,
          root_resource_id: chain.root_resource_id,
          started_at: chain.started_at&.iso8601,
          failed_at: chain.failed_at&.iso8601,
          error_message: chain.error_message
        }
      }
    end

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
