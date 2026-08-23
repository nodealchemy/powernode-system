# frozen_string_literal: true

module Sdwan
  module Executors
    # Executor for `sdwan.ovn_acl_create` (IMP-97c7b4123d8f).
    #
    # ACLs are the multi-tenant isolation mechanism, and this path
    # auto-activates: ungated, one call both wrote the rule and made it live.
    class CreateOvnAcl < ::System::Executors::Base
      ACTION_CATEGORY = "sdwan.ovn_acl_create"

      protected

      def perform
        switch = resolve_scoped(::Sdwan::OvnLogicalSwitch, params[:logical_switch_id])
        acl = switch.acls.create!(
          account: switch.account,
          name: params[:name],
          direction: params[:direction].to_s,
          priority: params[:priority].present? ? params[:priority].to_i : ::Sdwan::OvnAcl::DEFAULT_PRIORITY,
          match: params[:match],
          action: params[:acl_action].to_s
        )
        # Auto-activate so the compiler emits it in the same call, mirroring
        # SdwanOvnApplyAclExecutor. Now behind the gate rather than in front.
        acl.mark_active!
        { acl_id: acl.id, name: acl.name }
      end

      def summarize
        "Create OVN ACL #{params[:name]} (#{params[:acl_action]} #{params[:match]})"
      end

      def impact = "Adds an isolation rule and makes it live in the compiled plan"
    end
  end
end
