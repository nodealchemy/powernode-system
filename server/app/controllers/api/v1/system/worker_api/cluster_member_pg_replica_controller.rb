# frozen_string_literal: true

module Api
  module V1
    module System
      module WorkerApi
        # Worker-callable endpoint that materializes the PG streaming
        # replication slot + credential for a cluster_member spawn
        # child. Invoked by `ClusterMemberPgReplicaSetupJob` enqueued
        # from `System::SpawnPlatformService` when spawn_mode ==
        # "cluster_member".
        #
        # POST /api/v1/system/worker_api/cluster_member/pg_replica_setup
        #   Auth: X-Worker-Token (worker JWT)
        #   Body: { peer_id: "<uuid>" }
        #   Response: { data: { ok, peer_id, slot_name, credential_id,
        #                       already_prepared } }
        #
        # The endpoint locates the peer + account, verifies spawn_mode,
        # and delegates to PgReplicaSetupService. Failures surface as
        # 422 with a clear reason so the worker can decide whether to
        # retry (transient errors) or escalate (config issues).
        #
        # Plan reference: Decentralized Federation §H + P6.4.
        class ClusterMemberPgReplicaController < BaseController
          def create
            peer_id = params[:peer_id]
            return render_error("peer_id required", status: :unprocessable_entity) if peer_id.blank?

            peer = ::System::FederationPeer.find_by(id: peer_id)
            return render_error("peer not found", status: :not_found) unless peer

            unless peer.spawn_mode == "cluster_member"
              return render_error(
                "peer #{peer_id} is not a cluster_member spawn (mode=#{peer.spawn_mode.inspect})",
                status: :unprocessable_entity
              )
            end

            result = ::System::ClusterMember::PgReplicaSetupService.new(peer: peer).run!

            if result.ok?
              render_success(
                ok: true,
                peer_id: peer.id,
                slot_name: result.slot_name,
                credential_id: result.credential_id,
                already_prepared: result.already_prepared
              )
            else
              render_error(
                "PG replica setup failed: #{result.error}",
                status: :unprocessable_entity
              )
            end
          rescue StandardError => e
            ::Rails.logger.error("[ClusterMemberPgReplicaController] #{e.class}: #{e.message}")
            render_error("PG replica setup raised: #{e.message}",
                         status: :internal_server_error)
          end
        end
      end
    end
  end
end
