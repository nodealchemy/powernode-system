# frozen_string_literal: true

# Skill executor for system.sdwan_credential_refresh. Invoked by the
# DecisionEngine when an SdwanCredentialExpirySensor signal proceeds
# through the gate (IMP-df40782d3f4d).
#
# An expiring MembershipCredential means the agent is NOT pulling —
# Sdwan::TopologyCompiler refreshes the MC (ensure_fresh!) on every
# compile, so a healthy pull loop never lets one age into the sensor's
# window. The remediation is therefore to re-issue the CREDENTIAL
# server-side so a fresh envelope is ready the moment the agent pulls
# again. This executor deliberately never touches the WireGuard keypair:
# rotating the key revokes the active pubkey, hubs drop it on their next
# compile, and the still-connected-but-not-polling peer — exactly the
# peer whose MC is aging out — loses a WORKING tunnel. Key rotation
# remains bound to the drift signal (system.sdwan_peer_drift →
# SdwanPeerRemediateExecutor).
#
# Idempotent: MembershipCredentialSigner.ensure_fresh! returns the
# current active MC when it is still inside its refresh window, so a
# duplicate signal (or a dedup race) issues nothing new. The superseded
# row's envelope stays time-valid on the wire (revocation is by
# withholding refresh — no CRL), so the refresh is invisible to the
# data plane.
module System
  module Ai
    module Skills
      class SdwanCredentialRefreshExecutor < BaseSkillExecutor
        skill_descriptor(
          name: "sdwan_credential_refresh",
          description: "Re-issue an SDWAN peer's expiring membership credential server-side, without touching the WireGuard keypair",
          category: "sdwan",
          inputs: {
            peer_id: { type: "string", required: true,
                       description: "Sdwan::Peer whose membership credential is expiring" },
            dry_run: { type: "boolean", required: false, default: false,
                       description: "Plan-only mode — report the current credential and whether a refresh would issue" }
          },
          outputs: {
            resolved: :boolean,
            membership_credential_id: :string,
            revision: :integer,
            not_after: :string
          }
        )

        binds_to "SDWAN Manager"

        protected

        def perform(peer_id:, dry_run: false)
          peer = ::Sdwan::Peer.joins(:network)
                              .where(system_sdwan_networks: { account_id: @account.id })
                              .find_by(id: peer_id)
          return failure("peer not found in account") unless peer

          current = ::Sdwan::MembershipCredential
                      .live
                      .where(sdwan_peer_id: peer.id, sdwan_network_id: peer.sdwan_network_id)
                      .order(revision: :desc)
                      .first

          if dry_run
            return success(
              resolved: false,
              dry_run: true,
              current_credential_id: current&.id,
              current_revision: current&.revision,
              current_not_after: current&.not_after&.utc&.iso8601,
              would_issue: current.nil? || !current.usable? || current.refresh_due?
            )
          end

          # ensure_fresh! signs with the Vault-held constellation key and
          # supersedes the previous active row transactionally. It emits
          # sdwan.credential_issued / sdwan.credential_refresh_failed
          # FleetEvents itself — no second audit emit here.
          mc = ::Sdwan::MembershipCredentialSigner.ensure_fresh!(peer: peer)

          success(
            resolved: true,
            membership_credential_id: mc.id,
            revision: mc.revision,
            not_after: mc.not_after.utc.iso8601,
            superseded_credential_id: (current&.id unless current&.id == mc.id)
          )
        rescue ::Sdwan::MembershipCredentialSigner::SigningError => e
          # e.g. the peer has no active WireGuard key, or the constellation
          # signing key is unavailable — surface as a failed remediation so
          # the fingerprint persists and the F3-11 streak escalates it.
          failure("credential refresh failed: #{e.message}")
        end
      end
    end
  end
end
