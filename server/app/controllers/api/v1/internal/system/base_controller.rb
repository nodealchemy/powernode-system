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

          # Scope an account-owned relation to the mTLS-authenticated worker's
          # account. Mirrors core's rule for the JWT-authenticated worker API
          # (Api::V1::Worker::WorkerBaseController#account_scoped): the single
          # globally-unique system worker (workers.is_system) processes every
          # account's work by design and receives the relation unconstrained,
          # while an account worker is confined to its own account.
          #
          # Filters on this API come from caller-supplied params, so without
          # this an account worker that knows another account's operable id
          # reads — and through the write actions, mutates — that account's rows.
          def account_scoped(relation)
            return relation if @current_worker&.system?

            relation.where(account_id: @current_worker&.account_id)
          end
        end
      end
    end
  end
end
