# frozen_string_literal: true

module Sdwan
  module Executors
    class RevokeAccessGrant < ::System::Executors::Base
      protected

      def perform
        grant = ::Sdwan::AccessGrant.find(params[:grant_id])
        if grant.respond_to?(:revoke!)
          grant.revoke!
        else
          grant.update!(status: "revoked", revoked_at: Time.current)
        end
        { grant_id: grant.id, revoked: true }
      end

      def summarize = "Revoke SDWAN access grant #{params[:grant_id]}"
      def impact    = "User loses VPN access immediately; existing sessions terminate"
    end
  end
end
