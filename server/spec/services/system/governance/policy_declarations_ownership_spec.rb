# frozen_string_literal: true

require "rails_helper"

# HIER-P2A — policy ownership moves WITHOUT changing any verb.
#
# The 14 SDWAN remediation keys leave FLEET_AUTONOMY_POLICIES for the SDWAN
# Manager AGENT set (the operator set keeps its 43 CRUD keys and gains none of
# them); system.gitops_drift_remediate joins GITOPS_RECONCILER_POLICIES and
# system.disk_image_publication_investigate joins DISK_IMAGE_MANAGER_POLICIES.
# What stays on Fleet Autonomy is grouped into named sub-hashes so a later
# increment can lift a whole domain with a one-line change.
RSpec.describe System::Governance::PolicyDeclarations, "ownership (HIER-P2A)" do
  let(:d) { described_class }

  let(:sdwan_remediation_keys) do
    %w[
      system.federation_peer_remediate
      system.sdwan_peer_remediate
      system.sdwan_key_rotate
      system.sdwan_failover
      system.sdwan_user_device_revoke
      system.sdwan_bgp_session_remediate
      system.sdwan_vip_failover
      system.sdwan_credential_refresh
      system.sdwan_service_health_investigate
      system.sdwan_ovn_deployment_investigate
      system.sdwan_bgp_observation_investigate
      system.sdwan_apply_investigate
      system.sdwan_user_device_config_investigate
      system.federation_acceptance
    ]
  end

  # The verbs as they were declared on Fleet Autonomy before the move. A move
  # that changed a verb would be a governance change hiding inside a
  # relocation.
  let(:verbs_before) do
    {
      "system.federation_peer_remediate" => "notify_and_proceed",
      "system.sdwan_peer_remediate" => "notify_and_proceed",
      "system.sdwan_key_rotate" => "auto_approve",
      "system.sdwan_failover" => "require_approval",
      "system.sdwan_user_device_revoke" => "require_approval",
      "system.sdwan_bgp_session_remediate" => "notify_and_proceed",
      "system.sdwan_vip_failover" => "require_approval",
      "system.sdwan_credential_refresh" => "notify_and_proceed",
      "system.sdwan_service_health_investigate" => "notify_and_proceed",
      "system.sdwan_ovn_deployment_investigate" => "notify_and_proceed",
      "system.sdwan_bgp_observation_investigate" => "notify_and_proceed",
      "system.sdwan_apply_investigate" => "notify_and_proceed",
      "system.sdwan_user_device_config_investigate" => "notify_and_proceed",
      "system.federation_acceptance" => "require_approval",
      "system.gitops_drift_remediate" => "notify_and_proceed",
      "system.disk_image_publication_investigate" => "notify_and_proceed"
    }
  end

  def set(key) = d::POLICY_SETS.find { |s| s[:key] == key }

  describe "the SDWAN split" do
    it "moves the 14 remediation keys onto the SDWAN Manager agent set" do
      expect(d::SDWAN_MANAGER_POLICIES.keys).to include(*sdwan_remediation_keys)
      expect(d::FLEET_AUTONOMY_POLICIES.keys & sdwan_remediation_keys).to be_empty
      expect(set("sdwan-manager")[:policies]).to equal(d::SDWAN_MANAGER_POLICIES)
    end

    it "keeps the operator set at exactly the 43 CRUD keys" do
      operator = set("sdwan-operator")[:policies]
      expect(operator.keys).to all(start_with("sdwan."))
      expect(operator.size).to eq(43)
      expect(operator.keys & sdwan_remediation_keys).to be_empty
      expect(operator).to eq(d::SDWAN_OPERATOR_POLICIES)
    end

    it "sizes the agent set as CRUD + remediation" do
      expect(d::SDWAN_MANAGER_POLICIES.size).to eq(d::SDWAN_OPERATOR_POLICIES.size + sdwan_remediation_keys.size)
      expect(d::SDWAN_MANAGER_POLICIES.size).to eq(57)
    end
  end

  describe "the gitops and disk-image moves" do
    it "declares gitops_drift_remediate on the GitOps Reconciler" do
      expect(d::GITOPS_RECONCILER_POLICIES).to include("system.gitops_drift_remediate" => "notify_and_proceed")
      expect(d::FLEET_AUTONOMY_POLICIES).not_to have_key("system.gitops_drift_remediate")
      expect(d::GITOPS_RECONCILER_POLICIES.size).to eq(4)
    end

    it "declares disk_image_publication_investigate on the Disk Image Manager" do
      expect(d::DISK_IMAGE_MANAGER_POLICIES).to include("system.disk_image_publication_investigate" => "notify_and_proceed")
      expect(d::FLEET_AUTONOMY_POLICIES).not_to have_key("system.disk_image_publication_investigate")
      expect(d::DISK_IMAGE_MANAGER_POLICIES.size).to eq(7)
    end
  end

  it "changes no verb in the move" do
    all = d::POLICY_SETS.select { |s| s[:scope] == "agent" }
                        .flat_map { |s| s[:policies].to_a }.to_h
    verbs_before.each do |category, verb|
      expect(all[category]).to eq(verb), "#{category} was #{verb} before the move, is #{all[category].inspect} after"
    end
  end

  describe "what stays on Fleet Autonomy" do
    it "leaves replica_promote and service_backends_update where they were" do
      expect(d::FLEET_AUTONOMY_POLICIES).to include("system.replica_promote" => "require_approval",
                                                    "system.service_backends_update" => "require_approval")
    end

    it "groups the storage, ingress, supply-chain and capacity keys under named sub-hashes merged into the set" do
      groups = {
        "STORAGE_POLICY_KEYS" => d::STORAGE_POLICY_KEYS,
        "INGRESS_POLICY_KEYS" => d::INGRESS_POLICY_KEYS,
        "SUPPLY_CHAIN_POLICY_KEYS" => d::SUPPLY_CHAIN_POLICY_KEYS,
        "CAPACITY_POLICY_KEYS" => d::CAPACITY_POLICY_KEYS
      }

      groups.each do |name, group|
        expect(group).not_to be_empty, "#{name} is empty"
        expect(d::FLEET_AUTONOMY_POLICIES.to_a).to include(*group.to_a), "#{name} is not merged into FLEET_AUTONOMY_POLICIES"
      end

      keys = groups.values.flat_map(&:keys)
      expect(keys.uniq.size).to eq(keys.size), "a key is declared in two sub-hashes"

      expect(d::STORAGE_POLICY_KEYS.keys).to match_array(%w[system.storage_assignment_reconcile system.restore_volume])
      expect(d::INGRESS_POLICY_KEYS.keys).to match_array(%w[
        system.acme_certificate_provision system.expose_service_local
        system.expose_service_public_tcp system.expose_service_publicly
      ])
      expect(d::SUPPLY_CHAIN_POLICY_KEYS.keys).to match_array(%w[
        system.package_repository.sync system.package_module.create system.package_module.refresh
        system.architecture.propose system.architecture.create system.architecture.update
        system.architecture.delete
      ])
    end

    it "is 56 keys smaller by the 16 that moved" do
      expect(d::FLEET_AUTONOMY_POLICIES.size).to eq(56 - 16)
    end
  end

  describe ".owner_of" do
    it "names the agent whose agent-scoped set declares the category" do
      expect(d.owner_of("system.sdwan_peer_remediate")).to eq("sdwan-manager")
      expect(d.owner_of("system.gitops_drift_remediate")).to eq("gitops-reconciler")
      expect(d.owner_of("system.disk_image_publication_investigate")).to eq("disk-image-manager")
      expect(d.owner_of("system.cert_rotate")).to eq("fleet-autonomy")
      expect(d.owner_of("project.adapt")).to eq("fleet-autonomy")
      expect(d.owner_of("system.cve_remediate")).to eq("cve-responder")
    end

    it "returns nil for a category no agent set declares (operator-only or unknown)" do
      expect(d.owner_of("system.volume_snapshot_delete")).to be_nil
      expect(d.owner_of("system.never_declared")).to be_nil
    end

    it "is unambiguous — no category is declared on two different agents" do
      by_category = Hash.new { |h, k| h[k] = [] }
      d::POLICY_SETS.select { |s| s[:scope] == "agent" }.each do |s|
        s[:policies].each_key { |c| by_category[c] << s[:agent_key] }
      end
      ambiguous = by_category.select { |_, agents| agents.uniq.size > 1 }
      expect(ambiguous).to eq({})
    end
  end
end
