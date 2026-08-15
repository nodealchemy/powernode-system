# frozen_string_literal: true

module Sdwan
  module Executors
    class RevokeAccessGrant < ::System::Executors::Base
      protected

      def perform
        reject_device_scoped_params!
        grant = ::Sdwan::AccessGrant.find(params[:grant_id])
        # Both callers plumb `reason` into params — AccessGrantsController#revoke
        # from the request body, Ai::Tools::SdwanTool#revoke_access_grant from the
        # MCP action that documents it as "recorded on the grant". Dropping it here
        # left AccessGrant#revocation_reason nil on every gated revoke; the
        # device-scoped sibling (Sdwan::Executors::RevokeUserDevice) has always
        # forwarded it.
        #
        # Called unconditionally: AccessGrant defines revoke!, so the former
        # `respond_to?(:revoke!)` guard had no reachable else-arm. Its federation
        # sibling's identical fallback was deleted in 6f2d70c5 for naming a column
        # system_federation_peers does not have — this one was worse, because
        # status/revoked_at DO exist here: it would have succeeded, marking the
        # grant revoked while skipping revoke!'s device cascade and dropping the
        # reason, leaving every device live on the fabric under a revoked grant.
        grant.revoke!(reason: params[:reason])
        { grant_id: grant.id, revoked: true }
      end

      def summarize = "Revoke SDWAN access grant #{params[:grant_id]}"
      def impact    = "User loses VPN access immediately; existing sessions terminate"

      private

      # grant.revoke! cascades to EVERY device on the grant, so this executor
      # must never serve a device-scoped verb — those belong to
      # Sdwan::Executors::RevokeUserDevice.
      #
      # The guard is needed because Ai::DeferredOperation stores executor_class
      # as a string and constantizes it at approval time: a device revoke gated
      # before the device verbs were split off still names this class, and would
      # cascade when an operator approves it. Failing loudly beats silently
      # revoking a user's entire access. The one legitimate caller
      # (AccessGrantsController#revoke) passes only grant_id and reason.
      def reject_device_scoped_params!
        return if params[:device_id].blank?

        raise ArgumentError,
              "RevokeAccessGrant received device_id=#{params[:device_id]}: device-scoped revocation " \
              "must use Sdwan::Executors::RevokeUserDevice (a grant revoke cascades to every device)"
      end
    end
  end
end
