# frozen_string_literal: true

module System
  module Executors
    module DiskImage
      class RollbackPublication < ::System::Executors::Base
        protected

        def perform
          target_pub = ::System::DiskImagePublication.find(params[:target_publication_id])
          if target_pub.respond_to?(:promote!)
            target_pub.promote!
          else
            target_pub.update!(active: true, promoted_at: Time.current)
          end
          { rolled_back_to: target_pub.id }
        end

        def summarize = "Roll back disk image to #{params[:target_publication_id]}"
        def impact    = "Reverts active publication — affects all new node provisions"
      end
    end
  end
end
