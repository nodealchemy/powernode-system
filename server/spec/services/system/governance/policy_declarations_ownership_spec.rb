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
    # HIER-P2DECL moved system.service_backends_update to the Ingress Manager
    # (the decision P2A deferred); replica_promote is remediation core and stays.
    it "leaves replica_promote where it was" do
      expect(d::FLEET_AUTONOMY_POLICIES).to include("system.replica_promote" => "require_approval")
      expect(d::FLEET_AUTONOMY_POLICIES).not_to have_key("system.service_backends_update")
    end

    # The four groups P2A carved out are still named constants; since
    # HIER-P2DECL each is the CORE of its manager's set rather than merged
    # back into Fleet Autonomy's.
    it "keeps the storage, ingress, supply-chain and capacity groups as named sub-hashes, now lifted OFF the set" do
      groups = {
        "STORAGE_POLICY_KEYS" => d::STORAGE_POLICY_KEYS,
        "INGRESS_POLICY_KEYS" => d::INGRESS_POLICY_KEYS,
        "SUPPLY_CHAIN_POLICY_KEYS" => d::SUPPLY_CHAIN_POLICY_KEYS,
        "CAPACITY_POLICY_KEYS" => d::CAPACITY_POLICY_KEYS
      }

      groups.each do |name, group|
        expect(group).not_to be_empty, "#{name} is empty"
        expect(d::FLEET_AUTONOMY_POLICIES.keys & group.keys).to eq([]), "#{name} is still on FLEET_AUTONOMY_POLICIES"
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

    # 56 before P2A, 40 after its 16 moves, 19 after HIER-P2DECL's 21 more
    # (5 capacity + 2 storage + 4 ingress + 7 supply chain + 1
    # service_backends_update + 2 topology).
    it "is 56 keys smaller by the 16 P2A moved and the 21 wave 1 moved" do
      expect(d::FLEET_AUTONOMY_POLICIES.size).to eq(56 - 16 - 21)
    end
  end

  describe ".owner_of" do
    it "names the agent whose agent-scoped set declares the category" do
      expect(d.owner_of("system.sdwan_peer_remediate")).to eq("sdwan-manager")
      expect(d.owner_of("system.gitops_drift_remediate")).to eq("gitops-reconciler")
      expect(d.owner_of("system.disk_image_publication_investigate")).to eq("disk-image-manager")
      expect(d.owner_of("system.cert_rotate")).to eq("fleet-autonomy")
      expect(d.owner_of("project.adapt")).to eq("capacity-manager") # fleet-autonomy until HIER-P2DECL
      expect(d.owner_of("system.cve_remediate")).to eq("cve-responder")
    end

    # Since HIER-P2DECL every operator set has an agent twin, so the only
    # categories with no agent owner are the manual system.task.* rows and
    # names nobody declares.
    it "returns nil for a category no agent set declares (manual operations or unknown)" do
      expect(d.owner_of("system.task.terminate")).to be_nil
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

# HIER-P2DECL (Phase 2 wave 1) — the four operations managers, the topology
# owner and the operator-set twins. Operator rulings 2026-09-03: Fleet Autonomy
# is split into Capacity / Storage / Ingress / Supply Chain managers, the
# System Topology Designer takes the topology set, and every operator-only set
# is paired with the agent set that carries the same keys. Declarations only —
# the agents themselves were seeded in wave 2 (HIER-P2B/P2C/P2D/P2E), and
# every example here is about the constants, never about a row.
RSpec.describe System::Governance::PolicyDeclarations, "wave 1 managers (HIER-P2DECL)" do
  let(:d) { described_class }

  def set(key) = d::POLICY_SETS.find { |s| s[:key] == key }
  def agent_sets = d::POLICY_SETS.select { |s| s[:scope] == "agent" && s[:agent_key] }

  describe "the five lifted sets" do
    it "Capacity Manager = the capacity keys + instance pools + provisioning + platform scaling + cordon (22)" do
      expect(d::CAPACITY_MANAGER_POLICIES.keys).to match_array(
        d::CAPACITY_POLICY_KEYS.keys + d::INSTANCE_POOL_POLICIES.keys + d::PROVISIONING_POLICIES.keys +
        d::PLATFORM_SCALING_POLICIES.keys + d::INSTANCE_CORDON_OPERATOR_POLICIES.keys
      )
      expect(d::CAPACITY_MANAGER_POLICIES.size).to eq(22)
      expect(set("capacity-manager")).to include(agent_key: "capacity-manager", scope: "agent",
                                                  condition_overrides: d::PROVISIONING_CONDITION_OVERRIDES)
      expect(set("capacity-manager")[:policies]).to equal(d::CAPACITY_MANAGER_POLICIES)
    end

    it "Storage Manager = the storage keys + the snapshot delete (3)" do
      expect(d::STORAGE_MANAGER_POLICIES.keys).to match_array(
        d::STORAGE_POLICY_KEYS.keys + %w[system.volume_snapshot_delete]
      )
      expect(set("storage-manager")[:policies]).to equal(d::STORAGE_MANAGER_POLICIES)
    end

    it "Ingress Manager = the ingress keys + service_backends_update, which travels with the ingress writer (5)" do
      expect(d::INGRESS_MANAGER_POLICIES.keys).to match_array(
        d::INGRESS_POLICY_KEYS.keys + %w[system.service_backends_update]
      )
      expect(d::INGRESS_MANAGER_POLICIES["system.service_backends_update"]).to eq("require_approval")
      expect(set("ingress-manager")[:policies]).to equal(d::INGRESS_MANAGER_POLICIES)
    end

    it "Supply Chain Manager = the packages + architecture keys (7)" do
      expect(d::SUPPLY_CHAIN_MANAGER_POLICIES).to eq(d::SUPPLY_CHAIN_POLICY_KEYS)
      expect(d::SUPPLY_CHAIN_MANAGER_POLICIES.size).to eq(7)
      expect(set("supply-chain-manager")[:policies]).to equal(d::SUPPLY_CHAIN_MANAGER_POLICIES)
    end

    it "Topology Designer = the two topology keys + sdwan_federation_compose, declared require_approval at last (3)" do
      expect(d::TOPOLOGY_DESIGNER_POLICIES).to eq(
        "system.multi_tenant_isolation"    => "require_approval",
        "system.service_discovery_compose" => "require_approval",
        "system.sdwan_federation_compose"  => "require_approval"
      )
      expect(set("topology-designer")[:policies]).to equal(d::TOPOLOGY_DESIGNER_POLICIES)
    end

    it "leaves Fleet Autonomy the node_lifecycle / remediation core (19), no longer merged with the groups" do
      expect(d::FLEET_AUTONOMY_POLICIES.size).to eq(19)
      moved = d::CAPACITY_MANAGER_POLICIES.keys + d::STORAGE_MANAGER_POLICIES.keys +
              d::INGRESS_MANAGER_POLICIES.keys + d::SUPPLY_CHAIN_MANAGER_POLICIES.keys +
              d::TOPOLOGY_DESIGNER_POLICIES.keys
      expect(d::FLEET_AUTONOMY_POLICIES.keys & moved).to eq([])
      expect(d::FLEET_AUTONOMY_POLICIES).to include(
        "system.cert_rotate", "system.instance_reboot", "system.instance_reprovision",
        "system.instance_terminate", "system.replica_promote", "system.observation",
        "system.fulfill_capability_request"
      )
    end

    it "replaces the instance-pool-agent and provisioning sets with the capacity set" do
      expect(set("instance-pool-agent")).to be_nil
      expect(set("provisioning")).to be_nil
      expect(agent_sets.select { |s| s[:agent_key] == "fleet-autonomy" }.map { |s| s[:key] })
        .to eq(%w[fleet-autonomy])
    end
  end

  it "changes no verb in the move" do
    before = {
      "system.instance_replace" => "require_approval", "system.instance_reap" => "require_approval",
      "system.region_expansion" => "require_approval", "system.capacity_resize" => "require_approval",
      "system.relocate_workload" => "require_approval",
      "system.instance_pool_replenish" => "auto_approve", "system.instance_pool_update" => "notify_and_proceed",
      "project.scale_horizontal" => "auto_approve", "project.adapt" => "notify_and_proceed",
      "system.platform.scale_out" => "auto_approve", "system.platform.scale_in" => "require_approval",
      "system.instance_cordon" => "require_approval",
      "system.storage_assignment_reconcile" => "notify_and_proceed", "system.restore_volume" => "require_approval",
      "system.volume_snapshot_delete" => "require_approval",
      "system.expose_service_publicly" => "require_approval", "system.service_backends_update" => "require_approval",
      "system.package_repository.sync" => "auto_approve", "system.architecture.propose" => "auto_approve",
      "system.architecture.delete" => "require_approval",
      "system.multi_tenant_isolation" => "require_approval", "system.service_discovery_compose" => "require_approval"
    }
    all = agent_sets.flat_map { |s| s[:policies].to_a }.to_h
    before.each do |category, verb|
      expect(all[category]).to eq(verb), "#{category} was #{verb} before the move, is #{all[category].inspect} after"
    end
  end

  describe "identities and ownership" do
    it "declares the five new agents (the managers as monitors, the Topology Designer as the existing assistant)" do
      expect(d::AGENT_IDENTITIES).to include(
        "capacity-manager"     => { name: "Capacity Manager",         agent_type: "monitor" },
        "storage-manager"      => { name: "Storage Manager",          agent_type: "monitor" },
        "ingress-manager"      => { name: "Ingress Manager",          agent_type: "monitor" },
        "supply-chain-manager" => { name: "Supply Chain Manager",     agent_type: "monitor" },
        "topology-designer"    => { name: "System Topology Designer", agent_type: "assistant" }
      )
      # Eleven extension-seeded identities plus the Platform Architect — a CORE
      # canonical declared here as the owner of the governance-gap lane
      # (HIER-P3; CORE_CANONICAL_KEYS) but seeded, and delegation-governed, by core.
      expect(d::AGENT_IDENTITIES.size).to eq(12)
      expect(d::AGENT_IDENTITIES["platform-architect"]).to eq(name: "Platform Architect", agent_type: "assistant")
      expect(d::CORE_CANONICAL_KEYS).to eq(%w[platform-architect])
      expect(d::CORE_CANONICAL_KEYS - d::AGENT_IDENTITIES.keys).to eq([])
    end

    it "answers owner_of with the new owners" do
      expect(d.owner_of("system.instance_replace")).to eq("capacity-manager")
      expect(d.owner_of("system.instance_pool_create")).to eq("capacity-manager")
      expect(d.owner_of("project.adapt")).to eq("capacity-manager")
      expect(d.owner_of("system.platform.scale_out")).to eq("capacity-manager")
      expect(d.owner_of("system.instance_cordon")).to eq("capacity-manager")
      expect(d.owner_of("system.storage_assignment_reconcile")).to eq("storage-manager")
      expect(d.owner_of("system.volume_snapshot_delete")).to eq("storage-manager")
      expect(d.owner_of("system.expose_service_local")).to eq("ingress-manager")
      expect(d.owner_of("system.service_backends_update")).to eq("ingress-manager")
      expect(d.owner_of("system.package_repository.sync")).to eq("supply-chain-manager")
      expect(d.owner_of("system.architecture.create")).to eq("supply-chain-manager")
      expect(d.owner_of("system.sdwan_federation_compose")).to eq("topology-designer")
      expect(d.owner_of("system.multi_tenant_isolation")).to eq("topology-designer")
      expect(d.owner_of("system.cert_rotate")).to eq("fleet-autonomy")
      expect(d.owner_of("system.instance_reprovision")).to eq("fleet-autonomy")
    end

    # Every agent-declared key exactly once across the agent sets — the
    # stronger form of P2A's "no category on two agents": a key declared TWICE
    # on the SAME agent (two sets, one agent_key) would pass that and still
    # reconcile two rows.
    it "declares every key exactly once across the agent sets" do
      keys = agent_sets.flat_map { |s| s[:policies].keys }
      dupes = keys.tally.select { |_, n| n > 1 }.keys
      expect(dupes).to eq([])
    end
  end

  describe "operator twins" do
    # Every operator-only set is paired with the agent set that carries the
    # same keys. The pairing is DECLARED (OPERATOR_TWINS) so a new operator
    # set cannot land unpaired, and checked against the sets themselves so the
    # declaration cannot lie.
    it "pairs every agent-less set in POLICY_SETS with an agent set holding all of its keys" do
      operator_sets = d::POLICY_SETS.reject { |s| s[:agent_key] }
      expect(operator_sets.map { |s| s[:key] }).to match_array(d::OPERATOR_TWINS.keys)

      operator_sets.each do |op|
        twin = set(d::OPERATOR_TWINS.fetch(op[:key]))
        expect(twin).to be_present, "#{op[:key]}'s twin #{d::OPERATOR_TWINS[op[:key]]} is not a POLICY_SETS entry"
        expect(twin[:scope]).to eq("agent")
        expect(twin[:agent_key]).to eq(twin[:key])
        missing = op[:policies].keys - twin[:policies].keys
        expect(missing).to eq([]), "#{op[:key]} declares #{missing.inspect} that its twin #{twin[:key]} does not"
        op[:policies].each do |category, verb|
          expect(twin[:policies][category]).to eq(verb), "#{category}: operator #{verb}, twin #{twin[:policies][category]}"
        end
      end
    end

    it "names the rulings' pairings" do
      expect(d::OPERATOR_TWINS).to eq(
        "sdwan-operator"           => "sdwan-manager",
        "runtime-operator"         => "runtime-manager",
        "instance-pool-operator"   => "capacity-manager",
        "platform-scaling"         => "capacity-manager",
        "instance-cordon-operator" => "capacity-manager",
        "volume-snapshot-operator" => "storage-manager"
      )
    end

    it "keeps the operator rows themselves (the twins are additions, not replacements)" do
      expect(set("instance-pool-operator")[:policies]).to eq(d::INSTANCE_POOL_OPERATOR_POLICIES)
      expect(set("platform-scaling")[:policies]).to eq(d::PLATFORM_SCALING_POLICIES)
      expect(set("volume-snapshot-operator")[:policies]).to eq(d::VOLUME_SNAPSHOT_OPERATOR_POLICIES)
      expect(set("instance-cordon-operator")[:policies]).to eq(d::INSTANCE_CORDON_OPERATOR_POLICIES)
      expect(set("runtime-operator")[:policies]).to eq(d::RUNTIME_OPERATOR_POLICIES)
      expect(set("sdwan-operator")[:policies]).to eq(d::SDWAN_OPERATOR_POLICIES)
    end
  end

  it "aliases the four managers for binds_to" do
    aliases = System::Ai::Skills::SkillBindings::AGENT_ALIASES
    expect(aliases).to include(
      "capacity_manager"     => "Capacity Manager",
      "storage_manager"      => "Storage Manager",
      "ingress_manager"      => "Ingress Manager",
      "supply_chain_manager" => "Supply Chain Manager"
    )
    # Every alias target is a declared identity name (a typo here binds to nobody).
    expect(aliases.values - d::AGENT_IDENTITIES.values.map { |i| i[:name] })
      .to eq([ "System Concierge" ])
  end

  it "lists the new managers and the Topology Designer in the Autonomy panel's agent roster" do
    names = System::AutonomyActions::SYSTEM_AGENT_NAMES
    expect(names).to include("Capacity Manager", "Storage Manager", "Ingress Manager",
                             "Supply Chain Manager", "System Topology Designer")
    # The roster IS the set of declared agent-set owners — nothing more, nothing less.
    declared = agent_sets.map { |s| d::AGENT_IDENTITIES.fetch(s[:agent_key])[:name] }.uniq
    expect(names).to match_array(declared)
  end
end
