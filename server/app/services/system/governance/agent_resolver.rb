# frozen_string_literal: true

module System
  module Governance
    # ONE resolution rule for "which Ai::Agent row is <agent_key> on this
    # account", shared by the writer and the reader of every agent-scoped
    # policy row.
    #
    # PolicyReconciler WRITES rows against the agent this returns, and the
    # fleet tick (FleetAutonomyService#for_owner) READS policy rows against the
    # agent this returns. Two copies of the rule — however similar — is the
    # defect class the reconciler's own header records: a bare
    # `find_by(source_key:)` wrote rows against the GLOBAL agent while the gate
    # asked the account's OVERRIDE, and the drift report said "present" forever.
    #
    # Resolution is `Ai::Agent.resolve_for` — override-aware, an account's own
    # clone of a seeded agent WINS over the global row (`account_override_first`)
    # — keyed by the identity PolicyDeclarations::AGENT_IDENTITIES records for
    # the key, exactly as FleetAutonomyService.tick! resolves its own agent.
    #
    # source_key is a FALLBACK only, for an agent an operator renamed. It
    # rescues less than it appears to: the tick still resolves its OWN agent by
    # name, so a renamed Fleet Autonomy has already killed its tick; what the
    # fallback buys is that a renamed SPECIALIST (SDWAN Manager, say) still
    # owns its rows and still gates its lanes. Account-filtered and
    # override-first like the primary path, so it cannot pick a global twin
    # over the account's own row.
    class AgentResolver
      def self.resolve(account_id:, agent_key:)
        key = agent_key.to_s
        identity = PolicyDeclarations::AGENT_IDENTITIES[key]

        by_identity = identity && ::Ai::Agent.resolve_for(account_id, name: identity[:name],
                                                                        agent_type: identity[:agent_type])
        return by_identity if by_identity

        ::Ai::Agent.for_account(account_id).where(source_key: key).account_override_first.first
      end
    end
  end
end
