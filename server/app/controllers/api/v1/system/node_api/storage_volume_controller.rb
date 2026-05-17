# frozen_string_literal: true

module Api
  module V1
    module System
      module NodeApi
        # Agent-facing endpoint exposing the durable-storage binding the
        # PlatformDeploymentOrchestrator stamped onto NodeInstance.config.
        # Authenticated via the instance JWT; current_instance is provided
        # by BaseController.
        #
        # The on-node Go agent calls this once per reconcile tick and
        # passes the response to mount.ReconcileStorageVolume, which is
        # idempotent — already-mounted state returns immediately.
        #
        # Returns `{ storage_volume: nil }` when no volume is bound,
        # which the agent treats as "nothing to reconcile" (the empty
        # binding branch in ReconcileStorageVolume).
        #
        # Plan reference: E8 / E8.2 — bridging the orchestrator's
        # NodeInstance.config["storage_volume"] producer side into the
        # reconciler's consumer side.
        class StorageVolumeController < BaseController
          # GET /api/v1/system/node_api/storage_volume
          def show
            binding = current_instance.config&.dig("storage_volume")
            render_success(storage_volume: binding)
          end
        end
      end
    end
  end
end
