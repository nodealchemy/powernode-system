# frozen_string_literal: true

module Api
  module V1
    module System
      module FederationApi
        # Federation mTLS Phase 2 (symmetric) — serves OUR current internal-CA
        # bundle so an authenticated peer can refresh its stored trust anchor
        # for us when our CA rotates (the SPIFFE bundle-endpoint pattern). The
        # CA chain is public key material, so no secret is exposed; mTLS auth
        # (inherited from BaseController) ensures only enrolled peers fetch it.
        #
        # GET /api/v1/system/federation_api/trust_bundle
        # Returns: { ca_bundle_pem, generated_at }
        class TrustBundleController < BaseController
          def index
            render_success(
              ca_bundle_pem: ::System::InternalCaService.ca_chain_pem,
              generated_at: Time.current.iso8601
            )
          end
        end
      end
    end
  end
end
