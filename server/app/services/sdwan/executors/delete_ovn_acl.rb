# frozen_string_literal: true

module Sdwan
  module Executors
    # Executor for `sdwan.ovn_acl_delete` (IMP-97c7b4123d8f).
    #
    # Retracting an ACL relaxes isolation, so it carries the delete tier.
    class DeleteOvnAcl < ::System::Executors::Base
      ACTION_CATEGORY = "sdwan.ovn_acl_delete"

      protected

      def perform
        acl = resolve_scoped(::Sdwan::OvnAcl, params[:acl_id])
        name = acl.name
        acl.destroy!
        { deleted: true, acl_id: params[:acl_id], name: name }
      end

      def summarize = "Delete OVN ACL #{(scoped_label_record(::Sdwan::OvnAcl, params[:acl_id])&.name || params[:acl_id])}"
      def impact    = "Retracts an isolation rule from the compiled plan"
    end
  end
end
