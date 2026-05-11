# frozen_string_literal: true

module System
  module Executors
    module DiskImage
      class UpdateRetention < ::System::Executors::Base
        protected

        def perform
          platform = ::System::NodePlatform.find(params[:platform_id])
          platform.update!(disk_image_retention_count: params[:retention_count])
          { platform_id: platform.id, retention_count: platform.disk_image_retention_count }
        end

        def summarize = "Update disk image retention to #{params[:retention_count]}"
      end
    end
  end
end
