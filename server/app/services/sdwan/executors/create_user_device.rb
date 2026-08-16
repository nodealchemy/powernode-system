# frozen_string_literal: true

module Sdwan
  module Executors
    class CreateUserDevice < ::System::Executors::Base
      # Single source of this action's autonomy category (IMP-249e01a804e5).
      # No gate site references it today — this executor is composed directly
      # rather than dispatched through Ai::AutonomyGate — but the seeded policy
      # row and the engine registration are pinned to it by
      # spec/services/sdwan/executors/action_category_coherence_spec.rb, so the
      # first surface to gate this verb has a declaration to read.
      ACTION_CATEGORY = "sdwan.user_device_create"

      protected

      def perform
        grant = resolve_scoped(::Sdwan::AccessGrant, params[:grant_id])
        device = grant.user_devices.create!(attrs)
        { device_id: device.id, grant_id: grant.id }
      end

      def summarize = "Issue SDWAN VPN device config"
    end
  end
end
