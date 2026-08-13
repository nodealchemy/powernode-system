# frozen_string_literal: true

module Sdwan
  module Executors
    # Executor for `system.sdwan_user_device_revoke`, scoped to ONE
    # Sdwan::UserDevice. Dispatched via Ai::AutonomyGate from both
    # Api::V1::System::Sdwan::UserDevicesController#revoke (soft revoke, keeps
    # the row for audit) and #destroy (hard delete, `destroy_row: true`).
    #
    # Device verbs deliberately do NOT reuse Sdwan::Executors::RevokeAccessGrant:
    # AccessGrant#revoke! cascades to every device on the grant, which is correct
    # for a grant-level revoke and catastrophic for one lost phone — a grant holds
    # many devices, and its revocation is one-way (access must be re-granted and
    # every device re-issued).
    #
    # The destroy happens HERE rather than in the controller's on_proceed lambda
    # because `system.sdwan_user_device_revoke` resolves to require_approval:
    # Ai::GatedActions#gate! renders the approval stub on its :pending branch and
    # never calls on_proceed, so a DELETE approved later would otherwise leave the
    # device row in place.
    class RevokeUserDevice < ::System::Executors::Base
      protected

      def perform
        device  = scoped_device
        payload = { device_id: device.id, grant_id: device.sdwan_access_grant_id, revoked: true }

        if destroy_row?
          device.destroy!
          payload.merge(destroyed: true)
        else
          device.revoke!(reason: params[:reason])
          payload.merge(destroyed: false)
        end
      end

      def summarize
        "#{destroy_row? ? 'Delete' : 'Revoke'} SDWAN user device #{device_label || params[:device_id]}"
      end

      # Surfaced on the approval card. The hub PULLS its config
      # (NodeApi::SdwanController#show_config compiles on demand from
      # `network.user_devices.active`), so the cut takes effect at the next pull
      # rather than the instant this runs.
      def impact
        "Device loses VPN access at the hub's next config pull; the user's other devices and the access grant are unaffected"
      end

      private

      # A deferred operation runs long after the request that created it, so the
      # grant/device pairing recorded in params is re-validated against current
      # state: if the device has been re-parented onto another grant, or either
      # row is gone, this raises instead of acting on the wrong device.
      #
      # This is NOT an authorization check — both ids come from the stored
      # params. Account ownership is enforced upstream by the controller's
      # set_network/set_grant/set_device guards, matching the convention the
      # other SDWAN trust-boundary executors follow.
      def scoped_device
        ::Sdwan::AccessGrant.find(params[:grant_id]).user_devices.find(params[:device_id])
      end

      # Scoped like scoped_device so a preview can't surface a label from
      # outside the named grant. Nil when the pairing no longer resolves.
      def device_label
        scoped_device.label
      rescue ActiveRecord::RecordNotFound
        nil
      end

      def destroy_row?
        ActiveModel::Type::Boolean.new.cast(params[:destroy_row]) || false
      end
    end
  end
end
