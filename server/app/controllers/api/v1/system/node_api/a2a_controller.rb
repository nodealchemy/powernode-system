# frozen_string_literal: true

module Api
  module V1
    module System
      module NodeApi
        # AI/MCP workload substrate L2.5 (A2A) — node-facing advertisement of the
        # account's capability-token signing public key(s). The on-node A2A MCP
        # server pulls these on startup + periodically and registers them in its
        # verifier by handle, so it can verify inbound capability tokens OFFLINE.
        # Mirrors how SDWAN advertises constellation public keys to agents.
        #
        # GET /api/v1/system/node_api/a2a/capability_keys
        #   Auth: instance (BaseController). Only public keys are returned.
        #   Response: { keys: [{ handle, public_key_b64, algorithm }],
        #               revocations: { subs: [...], jtis: [...] } }
        #
        # F2-04 — `revocations` rides the same pull the agent already makes:
        # tokens are verified offline, so revoked grants / disabled peers
        # must reach the verifier this way or outstanding tokens stay valid
        # until exp.
        class A2aController < BaseController
          def capability_keys
            keys = ::System::PeerCapabilityTokenSigner.advertised_keys_for(current_account)
            revocations = ::System::PeerCapabilityRevocation.advertised_for(current_account)
            render_success(keys: keys, revocations: revocations)
          rescue StandardError => e
            Rails.logger.error("[NodeApi::A2a#capability_keys] #{e.class}: #{e.message}")
            render_error("capability key advertisement failed: #{e.message}", status: :internal_server_error)
          end
        end
      end
    end
  end
end
