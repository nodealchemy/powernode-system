# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Skill: complete a federation handshake from a single-use
      # acceptance token. Approval-gated wrapper around
      # System::Federation::FederationAcceptanceService — the same
      # orchestration the bootstrap-token HTTP endpoint runs, exposed as a
      # skill so an operator (via the System Concierge) or the SDWAN
      # Manager autonomy loop can drive an accept after a peer has been
      # proposed.
      #
      # Use this when an operator says "accept the federation peer using
      # token <X>", "complete the handshake with the child platform", or
      # otherwise wants to finish a federation peering whose acceptance
      # token they hold.
      #
      # The full accept chain runs synchronously (accept! → enroll! →
      # ensure grant → node_enrollment → SDWAN attach → governance scan).
      # Federation peering is sensitive, so the skill is approval-gated.
      #
      # Plan reference: Decentralized Federation §C + P3.3 + Phase 3a.
      class FederationAcceptanceExecutor < BaseSkillExecutor
        skill_descriptor(
          name: "federation_acceptance",
          description: "Complete a federation handshake from a single-use acceptance token — runs the full accept chain (accept transition, platform enroll, managed-child operator grant, node_api bootstrap-token issuance, SDWAN overlay attach, and a federation governance health scan). Use when an operator wants to finish peering with a proposed federation peer whose acceptance token they hold.",
          category: "federation",
          requires_approval: true,
          inputs: {
            acceptance_token: { type: "string", required: true,
                                description: "The single-use acceptance token plaintext (from the propose step). Consumed on success." },
            contract_version: { type: "integer", required: true,
                                description: "Contract version to agree on. Must be one of the supported versions (currently [1])." },
            capabilities: { type: "object", required: false,
                            description: "Forward-compat capability advertisement exchanged with the peer." },
            extension_slugs: { type: "array", required: false,
                               description: "Extension slugs the peer carries (e.g. ['trading'])." },
            endpoints: { type: "array", required: false,
                         description: "Peer endpoints: array of { url, scope, priority, cidr_hint? }." }
          },
          outputs: {
            peer_id:                 :string,
            status:                  :string,
            peer_kind:               :string,
            contract_version_agreed: :integer,
            accepted_at:             :string,
            handshake_at:            :string,
            node_enrollment:         :object,
            sdwan_attach:            :object,
            governance:              :object,
            warnings:                [ :string ]
          },
          blast_radius: :high
        )

        binds_to "SDWAN Manager", "System Concierge"

        protected

        def perform(acceptance_token:, contract_version:, capabilities: {},
                    extension_slugs: [], endpoints: [], **_extra)
          result = ::System::Federation::FederationAcceptanceService.call(
            token: acceptance_token,
            contract_version: contract_version,
            capabilities: capabilities,
            extension_slugs: extension_slugs,
            endpoints: endpoints
          )

          return failure(result.error) unless result.ok?

          success(result.payload)
        end
      end
    end
  end
end
