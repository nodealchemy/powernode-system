# frozen_string_literal: true

module System
  module Executors
    module DiskImage
      class PromotePublication < ::System::Executors::Base
        protected

        def perform
          pub = ::System::DiskImagePublication.find(params[:publication_id])
          if pub.respond_to?(:promote!)
            pub.promote!
          else
            pub.update!(active: true, promoted_at: Time.current)
          end
          { publication_id: pub.id, promoted: true }
        end

        def summarize
          pub = ::System::DiskImagePublication.find_by(id: params[:publication_id])
          pub ? "Promote disk image #{pub.try(:tag) || pub.id} to active" : "Promote disk image"
        end

        def impact = "All new node provisions will boot from this image"
      end
    end
  end
end
