# frozen_string_literal: true

require "rails_helper"

# E2 (campaign 01a08c9b) gave declare_action a `destructive:` flag, which the
# MCP catalog advertises as destructiveHint. The extension's 40 destroy-shaped
# verbs are those Mcp::Principal::DESTRUCTIVE_TOOL_PATTERNS already refuses to
# an instance principal. Until each declares the flag, the catalog's
# classification rests on the deny-overlay floor alone.
#
# EQUALITY, not inclusion. The set of destructive verbs across these six tool
# classes must be exactly the 40 below. A verb dropped from the list and a
# destroy-shaped verb added without the flag both red this file, so the
# declaration cannot drift from the overlay silently in either direction.
RSpec.describe "system extension destructive declarations" do
  DESTRUCTIVE_VERBS = {
    Ai::Tools::SystemFleetTool => %w[
      system_terminate_instance system_delete_cve system_delete_instance_pool system_delete_module
      system_delete_node system_delete_provider system_delete_template system_delete_volume
      system_destroy_instance system_delete_volume_snapshot system_drain_instance
      system_drain_instance_pool system_instance_hold system_instance_release_hold
      system_reap_agent_fleet system_reap_instance system_reboot_instance system_recycle_pool
      system_replace_instance system_rotate_vault_transit_pepper system_stop_instance
      system_terminate_ci_worker system_upgrade_boot_image
    ],
    Ai::Tools::SdwanTool => %w[
      system_sdwan_delete_firewall_rule system_sdwan_delete_ipfix_collector
      system_sdwan_delete_network system_sdwan_delete_ovn_acl system_sdwan_delete_ovn_deployment
      system_sdwan_delete_ovn_logical_switch system_sdwan_delete_ovn_logical_switch_port
      system_sdwan_delete_port_mapping system_sdwan_delete_route_policy
      system_sdwan_delete_virtual_ip system_sdwan_revoke_access_grant
      system_sdwan_revoke_federation_peer system_sdwan_revoke_user_device
    ],
    Ai::Tools::SystemAcmeTool => %w[system_acme_revoke_certificate],
    Ai::Tools::SystemArchitectureCatalogTool => %w[system_delete_architecture],
    Ai::Tools::SystemIngressTool => %w[system_delete_service],
    Ai::Tools::SystemPackageRepositoryTool => %w[system_delete_package_repository]
  }.freeze

  def declared_destructive(klass)
    klass.declared_actions.select { |_name, decl| decl[:destructive] }.keys
  end

  it "pins exactly the 40 verbs E2 listed" do
    expect(DESTRUCTIVE_VERBS.values.flatten.size).to eq(40)
    expect(DESTRUCTIVE_VERBS.values.flatten.uniq.size).to eq(40)
  end

  DESTRUCTIVE_VERBS.each do |klass, verbs|
    it "#{klass.name.demodulize} declares exactly its destroy-shaped verbs destructive" do
      expect(declared_destructive(klass)).to match_array(verbs)
    end
  end

  it "leaves a read verb and a mutating, non-destructive verb undeclared" do
    declared = Ai::Tools::SystemFleetTool.declared_actions

    expect(declared.fetch("system_list_instances")[:destructive]).to be(false)
    expect(declared.fetch("system_replenish_instance_pool")).to include(mutating: true, destructive: false)
  end
end
