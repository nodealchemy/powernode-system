# frozen_string_literal: true

module Sdwan
  module Executors
    class CreateUserDevice < ::System::Executors::Base
      # Single source of this action's autonomy category (IMP-249e01a804e5).
      # Nothing reaches this executor today — no gate site and no composer name
      # it, only specs — so there is no surface to read the declaration yet.
      # The seeded policy row and the engine registration are still pinned to
      # it by spec/services/sdwan/executors/action_category_coherence_spec.rb,
      # so whichever surface gates this verb first has a declaration to read
      # rather than a literal to invent.
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
