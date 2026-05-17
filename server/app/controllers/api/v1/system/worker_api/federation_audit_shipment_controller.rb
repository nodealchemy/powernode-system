# frozen_string_literal: true

module Api
  module V1
    module System
      module WorkerApi
        # P9.2 — Worker-callable WORM audit shipment endpoint.
        #
        # FederationAuditShipmentJob POSTs here daily; the controller
        # invokes ::Federation::AuditShipmentService.run! which sweeps
        # every active federation peer's audit excerpt older than 30d,
        # seals it into JSON-Lines + sha256, and records the receipt
        # in system_federation_audit_shipments.
        #
        # POST /api/v1/system/worker_api/federation/audit_shipment
        #   Auth: X-Worker-Token (handled by BaseController)
        #   Body (optional): { account_id }
        #   Response: { data: { swept_peers, shipped, events, failures } }
        class FederationAuditShipmentController < BaseController
          def create
            account = scoped_account
            result = ::Federation::AuditShipmentService.run!(account: account)
            render_success(
              swept_peers: result.swept_peers,
              shipped:     result.shipped,
              events:      result.events,
              failures:    result.failures
            )
          rescue StandardError => e
            Rails.logger.error(
              "[FederationAuditShipmentController] sweep failed: #{e.class}: #{e.message}"
            )
            render_error("federation_audit_shipment_failed: #{e.message}",
                         :internal_server_error)
          end

          private

          def scoped_account
            id = params[:account_id].presence
            id && ::Account.find_by(id: id)
          end
        end
      end
    end
  end
end
