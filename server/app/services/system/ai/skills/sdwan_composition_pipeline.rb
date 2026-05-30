# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Shared SDWAN network+peer composition primitives, factored out of the
      # two executors that stand up an Sdwan::Network and enroll a set of
      # System::NodeInstance peers on it:
      #
      #   - ConfigureSdwanForProjectExecutor — project overlay (+ optional VIP)
      #   - SdwanFederationComposeExecutor    — federation overlay (hub/spoke +
      #     routing-protocol-aware FRR route-policy layer)
      #
      # The two skills diverge meaningfully above this line (missions + VIPs vs.
      # hub roles + endpoints + route policies), so they are NOT collapsed into
      # one executor. This module captures only the pieces that were byte-for-byte
      # identical between them: the account-scoped instance preflight, the
      # partial-run bookkeeping flag, and the reverse-order peer+network teardown
      # used by both rollbacks. Including executors call these helpers and layer
      # their own specifics on top — keeping one authoritative copy of the shared
      # contract instead of two divergent ones.
      #
      # Contract: includers MUST expose `@account` (an Account with #id), which
      # every BaseSkillExecutor subclass sets in its initializer.
      module SdwanCompositionPipeline
        # Account-scoped NodeInstance lookup. Returns the relation of instances
        # (joined through their node) that belong to @account, restricted to the
        # supplied ids. Callers verify completeness via #missing_instance_ids so
        # we never half-build a network on a stranger's instance.
        def account_scoped_instances(ids)
          ::System::NodeInstance.joins(:node)
                                .where(system_nodes: { account_id: @account.id })
                                .where(id: ids)
        end

        # The ids that were requested but did not resolve to an account-owned
        # instance. `found` may be an array of instances or a hash keyed by id.
        def missing_instance_ids(requested_ids, found)
          found_ids = found.is_a?(Hash) ? found.keys : Array(found).map(&:id)
          requested_ids - found_ids
        end

        # A composition run is "partial" when it hit at least one failure but
        # still managed to persist something (the network or any peer) — i.e.
        # there is durable state a rollback would need to unwind.
        def partial_run?(failures:, peer_ids:, network_id:)
          failures.any? && (Array(peer_ids).any? || network_id.present?)
        end

        # Reverse-order teardown shared by both executors' rollbacks: destroy
        # each peer (newest enrollment first) then the network. Destroying the
        # network cascades to any surviving peers via dependent: :destroy, so the
        # explicit per-peer pass is belt-and-braces that also preserves
        # audit-trail granularity and tolerates rows already gone. Appends
        # {resource:, id:, error:} hashes to `errors` for any destroy that raises
        # and returns the same `errors` array for chaining.
        def teardown_peers_then_network(sdwan_network_id:, sdwan_peer_ids:, errors:)
          Array(sdwan_peer_ids).reverse_each do |peer_id|
            peer = ::Sdwan::Peer.where(account_id: @account.id).find_by(id: peer_id)
            next unless peer

            begin
              peer.destroy!
            rescue StandardError => e
              errors << { resource: "sdwan_peer", id: peer_id, error: e.message }
            end
          end

          if sdwan_network_id.present?
            network = ::Sdwan::Network.where(account_id: @account.id).find_by(id: sdwan_network_id)
            if network
              begin
                network.destroy!
              rescue StandardError => e
                errors << { resource: "sdwan_network", id: sdwan_network_id, error: e.message }
              end
            end
          end

          errors
        end
      end
    end
  end
end
