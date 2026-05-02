# frozen_string_literal: true

module Api
  module V1
    module Internal
      module System
        # Base controller for internal System API endpoints accessed by worker service
        # These endpoints handle infrastructure management operations
        class BaseController < Api::V1::Internal::InternalBaseController
          private

          def set_account
            @account = Account.find(params[:account_id])
          rescue ActiveRecord::RecordNotFound
            render_not_found("Account")
          end
        end
      end
    end
  end
end
