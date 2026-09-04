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
    # source_key is a FALLBACK for an agent an operator renamed. Since HIER-P2I
    # it rescues MORE than it used to: FleetAutonomyService.tick! and
    # CveResponderService.tick! resolve their own agent through this class by
    # KEY rather than with a bare `resolve_for(name:)`, so a renamed Fleet
    # Autonomy still owns its rows, still gates its lanes and still ticks —
    # where before the rename killed the tick outright and the fallback only
    # rescued a renamed SPECIALIST (SDWAN Manager, say). Account-filtered and
    # override-first like the primary path, so it cannot pick a global twin
    # over the account's own row.
    #
    # CANONICAL PRINCIPALS NEVER EXECUTE (HIER-P2I, proposal §5 ruling 8). The
    # fleet agents are seeded GLOBAL (account_id NULL), and a global row is a
    # TEMPLATE: Ai::Tools::BaseTool refuses it as an acting principal, so a
    # tick that gated under the canonical would refuse every remediation it
    # tried. When the account has no row of its own the answer is therefore
    # the account's CLONE of the canonical — minted on first use by the core
    # seam Ai::Agents::AccountPrincipalResolver, which also re-homes the
    # account's policy rows from the canonical's id onto the clone's, so the
    # reconciler sees them present and the gate reads them on the SAME tick.
    # Because writer and reader both come through here, the clone is where
    # the rows land and where the gate looks, which is the whole point of
    # this class.
    #
    # `mint:` is what keeps a REPORT a report. Minting is a write — an agent, a
    # lineage edge, a trust score, a delegation policy and a policy re-home per
    # key — and PolicyDeclarations::AGENT_IDENTITIES has eleven keys, so a
    # `drift` run (read-only by contract, callable from a health check or a CI
    # assertion) that resolved through the minting path would materialise up to
    # eleven principals on a fresh account. `drift` therefore asks with
    # `mint: false` and answers for the canonical, naming what WOULD act; the
    # writers — the reconcile pass, the fleet tick, the CVE tick, the per-owner
    # gates — ask with the default and get the principal that actually executes.
    class AgentResolver
      def self.resolve(account_id:, agent_key:, mint: true)
        key = agent_key.to_s
        identity = PolicyDeclarations::AGENT_IDENTITIES[key]

        by_identity = identity && ::Ai::Agent.resolve_for(account_id, name: identity[:name],
                                                                        agent_type: identity[:agent_type])
        resolved = by_identity ||
                   ::Ai::Agent.for_account(account_id).where(source_key: key).account_override_first.first
        return resolved if resolved.nil? || !resolved.global?
        return resolved unless mint

        account = ::Account.find_by(id: account_id)
        return resolved if account.nil?

        ::Ai::Agents::AccountPrincipalResolver.acting(resolved, account: account)
      end
    end
  end
end
