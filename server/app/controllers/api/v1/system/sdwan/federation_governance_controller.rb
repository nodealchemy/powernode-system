# frozen_string_literal: true

# Operator-facing federation governance scan — the REST twin of the MCP tool
# `system_sdwan_federation_scan` (Ai::Tools::SdwanTool#federation_scan).
#
# Both surfaces call the SAME scanner, Sdwan::FederationGovernance.scan, and
# return the same envelope. That is the point of this controller: before
# IMP-65f479ad8484 the operator console re-implemented two of the scanner's
# finding kinds (expired_trust_jwt, stale_accepted_without_handshake) in
# TypeScript while MCP served all of them, so the console could report "no
# findings" on an account where an agent saw critical ones. One scanner, two
# surfaces.
#
# Read-only: the scan writes nothing and is therefore NOT autonomy-gated. It is
# permission-gated on system.sdwan.federation.read — the same permission the
# sibling federation read endpoints (FederationPeersController#index/#show) and
# the MCP arm (SdwanTool::TOOL_PERMISSIONS) use — because the findings project peer status, remote instance URLs and
# prefix advertisements for every federation peer in the account.
#
# Tenancy: the scanner is account-scoped by construction. It is handed
# current_account and every query inside it filters on that account_id, exactly
# as the MCP arm hands it @account.
module Api
  module V1
    module System
      module Sdwan
        class FederationGovernanceController < ::Api::V1::System::BaseController
          before_action :set_account

          def scan
            require_permission("system.sdwan.federation.read")

            findings = ::Sdwan::FederationGovernance.scan(account: @account)

            render_success(
              findings: findings,
              finding_count: findings.size,
              severity_summary: findings.group_by { |f| f[:severity] }.transform_values(&:size)
            )
          end
        end
      end
    end
  end
end
