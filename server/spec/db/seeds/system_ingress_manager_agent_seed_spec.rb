# frozen_string_literal: true

require "rails_helper"

# HIER-P2D — the Ingress Manager seed. Pins the wave-2 acceptance contract:
#   1. a GLOBAL seeded canonical (find_or_initialize_global_agent — never adopts
#      a stray account row), monitor type, routing-shaped description,
#      reasoning-tier model requirement, a tool_access.tool_families list that
#      HIER-P1B's ToolAllowlist scopes to the ingress surface;
#   2. its POLICY_SETS set (INGRESS_MANAGER_POLICIES) written on the seeding
#      account, so PolicyReconciler finds nothing missing and no longer skips
#      the set as "agent absent";
#   3. attached under System Concierge by system_agent_hierarchy.rb with the
#      P1 leaf delegation (conservative / depth 2 / no delegate types);
#   4. the ingress executors re-bound to it (acme provision leaves Fleet
#      Autonomy, which no sensor routes to that executor) while System
#      Concierge keeps its operator-chat door;
#   5. trust score, approval chain, idempotency.
RSpec.describe "system_ingress_manager_agent seed" do
  def load_seed!(file)
    silence_warnings do
      load Rails.root.join("..", "extensions", "system", "server", "db", "seeds", file)
    end
  end

  let!(:account)  { create(:account, name: "Powernode Admin") }
  let!(:user)     { create(:user, account: account, email: "admin@powernode.org") }
  let!(:provider) { create(:ai_provider, account: account, provider_type: "anthropic", is_active: true) }

  let(:agent) { Ai::Agent.global.find_by(name: "Ingress Manager") }
  let(:declared) { System::Governance::PolicyDeclarations::INGRESS_MANAGER_POLICIES }

  describe "the seeded agent" do
    before { load_seed!("system_ingress_manager_agent.rb") }

    it "creates a GLOBAL monitor canonical named 'Ingress Manager' keyed ingress-manager" do
      expect(agent).to be_present
      expect(agent.account_id).to be_nil
      expect(agent.is_system).to be true
      expect(agent.source_key).to eq("ingress-manager")
      expect(agent.slug).to eq("ingress-manager")
      expect(agent.agent_type).to eq("monitor")
      expect(agent.status).to eq("active")
    end

    it "matches the identity PolicyDeclarations declares for its key" do
      identity = System::Governance::PolicyDeclarations::AGENT_IDENTITIES.fetch("ingress-manager")
      expect(agent.name).to eq(identity[:name])
      expect(agent.agent_type).to eq(identity[:agent_type])
      expect(System::Governance::AgentResolver.resolve(account_id: account.id, agent_key: "ingress-manager")&.id)
        .to eq(agent.id)
    end

    it "carries a ROUTING description (trigger + exclusion naming the siblings) within the export budget" do
      expect(agent.description.length).to be <= Ai::ClaudeExport::RoutingDescription::MAX_CHARS
      expect(agent.description).to match(/Use when/)
      expect(agent.description).to match(/Do not use for/)
      expect(agent.description).to include("SDWAN Manager")
      expect(agent.description).to include("Capacity Manager")
    end

    it "carries the operating prompt: publish runbook, drained-backend semantics, health-check opt-in, the ACME split, hand-offs" do
      prompt = agent.system_prompt.to_s
      expect(prompt).to match(/Ingress Manager/)
      expect(prompt).to include("/svc/<slug>")
      expect(prompt).to include("draining")
      expect(prompt).to include("health_check_enabled")
      expect(prompt).to include("system.acme_cert_rotate")
      expect(prompt).to include("Fleet Autonomy")
      expect(prompt).to include("SDWAN Manager")
      expect(prompt).to include("Capacity Manager")
      expect(prompt).to include("system_set_service_backends")
    end

    it "requests a reasoning-tier model via model_requirements (no pinned provider/model)" do
      requirements = agent.mcp_metadata.dig("model_config", "model_requirements")
      expect(requirements).to eq("tier" => "reasoning")
      expect(agent.mcp_metadata.dig("model_config", "model")).to be_blank
      expect(agent.mcp_metadata.dig("model_config", "provider")).to be_blank
    end

    # HIER-P1B derives the Claude Code `tools:` allowlist (and the runtime
    # bridge derives the LLM tool list) from tool_access.tool_families. The
    # list is asserted against the REGISTRY, not just as a literal: a family
    # that matches nothing fails open to the full registry, which is exactly
    # the misconfiguration the assertion exists to catch.
    it "scopes tool_access.tool_families to the ingress surface — and every family matches a registered action" do
      families = agent.mcp_metadata.dig("tool_access", "tool_families")
      expect(families).to eq(%w[
        system_list_services system_get_service system_create_service
        system_set_service_backends
        system_expose_service system_unexpose_service
        system_acme_provision_certificate system_acme_get_certificate
        system_sdwan_list_virtual_ips system_sdwan_get_virtual_ip system_sdwan_list_vip_assignments
        system_reverse_proxy_compose
        discover_skills get_skill_context search_knowledge query_learnings
      ])

      registry = Ai::ClaudeExport::ToolAllowlist::Registry.snapshot
      families.each do |family|
        matched = registry.action_names.select { |n| n == family || n.start_with?("#{family}_") }
        expect(matched).not_to be_empty, "tool family #{family} matches no registered action"
      end

      actions = Ai::ClaudeExport::ToolAllowlist.platform_actions_for(agent, registry: registry)
      expect(actions).not_to eq(Ai::ClaudeExport::ToolAllowlist::UNSCOPED)
      expect(actions).to include(
        "system_expose_service_local", "system_expose_service_publicly", "system_expose_service_public_tcp",
        "system_unexpose_service_local", "system_unexpose_service_public_tcp",
        "system_set_service_backends", "system_acme_provision_certificate", "system_acme_get_certificate",
        "system_list_services", "system_get_service",
        "system_sdwan_list_virtual_ips", "system_sdwan_get_virtual_ip", "system_reverse_proxy_compose"
      )
      # Adjacent domains stay with their owners: VIP lifecycle (SDWAN Manager),
      # instance capacity (Capacity Manager), service deletion (operator door).
      expect(actions).not_to include(
        "system_sdwan_create_virtual_ip", "system_sdwan_failover_virtual_ip",
        "system_provision_instance", "system_delete_service"
      )
    end

# A family entry matches by exact name OR `<family>_` prefix, so a BARE
# family silently widens the agent past its declared set. Every ACME verb
# this agent must not hold (renew / revoke / create_dns_credential) is
# `mutating: true` with NO action_category and appears in no POLICY_SETS
# entry — nothing downstream would gate it — and `system_update_service`
# can repoint a live exposed service's backend and regen the proxy, which
# is the blast radius the gated `system_set_service_backends` exists to
# control. Assert the SCOPED action list, not the family literal.
it "admits no ungated write outside the declared set (no ACME renew/revoke/DNS credential, no service update/delete)" do
  registry = Ai::ClaudeExport::ToolAllowlist::Registry.snapshot
  actions  = Ai::ClaudeExport::ToolAllowlist.platform_actions_for(agent, registry: registry)

  expect(actions).not_to include(
    "system_acme_renew_certificate", "system_acme_revoke_certificate",
    "system_acme_create_dns_credential", "system_update_service", "system_delete_service"
  )
  expect(actions).to include("system_acme_provision_certificate", "system_acme_get_certificate")
end

# Historical (pre-HIER-P2H): the exporter re-added BOOTSTRAP_ACTIONS while the
# RUNTIME bridge added nothing. Since HIER-P2H both union
# Ai::Tools::BootstrapVerbs::ACTIONS, so a families list that omits the
# discovery/knowledge tools no longer removes the tools BASE_GUARDRAILS orders
# the agent to call ("query platform
# guidance (search_knowledge tag:guidance-*)", "Reuse first: …
# discover_skills"). Exercise the bridge's own matcher over the real
# registry names rather than re-deriving the family semantics here.
it "keeps the guardrail-mandated discovery/knowledge tools in the RUNTIME bridge's scoped list" do
  bridge = Ai::AgentToolBridgeService.new(agent: agent, account: account)
  definitions = Ai::Tools::PlatformApiToolRegistry.all_tools.keys.map { |name| { name: name.to_s } }
  scoped = bridge.send(:scope_to_tool_families, definitions).map { |d| d[:name] }

  expect(scoped.size).to be < definitions.size
  expect(scoped).to include(
    "search_knowledge", "discover_skills", "get_skill_context", "query_learnings",
    "system_expose_service_local", "system_set_service_backends"
  )
  expect(scoped).not_to include("system_acme_revoke_certificate", "system_update_service")
end

    it "bootstraps a monitored trust score at 0.70" do
      score = Ai::AgentTrustScore.find_by(agent_id: agent.id)
      expect(score).to be_present
      expect(score.tier).to eq("monitored")
      expect(score.overall_score.to_f.round(2)).to eq(0.70)
    end

    it "owns exactly INGRESS_MANAGER_POLICIES on the seeding account, at the agent shape" do
      rows = Ai::InterventionPolicy
        .where(account: account, ai_agent_id: agent.id, scope: "agent", is_active: true)
        .pluck(:action_category, :policy).to_h
      expect(rows).to eq(declared)
      expect(rows.keys).to contain_exactly(
        "system.service_backends_update", "system.acme_certificate_provision",
        "system.expose_service_local", "system.expose_service_public_tcp", "system.expose_service_publicly"
      )
    end

    it "leaves PolicyReconciler nothing to write for the ingress set (no longer skipped as agent absent)" do
      reconciler = System::Governance::PolicyReconciler.new(account: account)
      report = reconciler.drift
      expect(report.skipped_sets.grep(/\Aingress-manager/)).to be_empty
      expect(report.missing.select { |row| row.set_key == "ingress-manager" }).to be_empty

      result = reconciler.reconcile!
      expect(result.created_categories.to_a & declared.keys).to eq([])
    end

    it "creates its own approval chain: 4h, reject on timeout, infra-control approver" do
      chain = Ai::ApprovalChain.find_by(account: account, name: "Ingress Manager Actions")
      expect(chain).to be_present
      expect(chain.status).to eq("active")
      expect(chain.trigger_type).to eq("autonomy_action")
      expect(chain.timeout_hours).to eq(4)
      expect(chain.timeout_action).to eq("reject")
      expect(chain.steps.first["approvers"]).to eq([ { "type" => "permission", "value" => "system.infra_tasks.control" } ])
    end

    it "is idempotent across re-runs (no duplicate global row, no policy churn)" do
      expect { load_seed!("system_ingress_manager_agent.rb") }
        .not_to change { Ai::Agent.global.where(name: "Ingress Manager").count }.from(1)
      expect(Ai::InterventionPolicy.where(account: account, ai_agent_id: agent.id).count).to eq(declared.size)
      expect(Ai::ApprovalChain.where(account: account, name: "Ingress Manager Actions").count).to eq(1)
    end
  end

  # Canonical rule (operator ruling 2026-09-03 §5): a seed never adopts a
  # stray account-scoped agent as the canonical.
  describe "canonical rule" do
    it "refuses to seed over an ACCOUNT-scoped 'Ingress Manager' when no global row exists" do
      create(:ai_agent, account: account, name: "Ingress Manager", agent_type: "monitor")

      expect { load_seed!("system_ingress_manager_agent.rb") }
        .to raise_error(System::Seeds::AgentSetupHelpers::CanonicalAgentConflict, /ingress-manager/)
      expect(Ai::Agent.global.where(name: "Ingress Manager")).to be_empty
    end
  end

  describe "hierarchy seat (system_agent_hierarchy.rb after the seed)" do
    let(:root) { Ai::Agent.global.find_by(name: "System Concierge") }

    before do
      load_seed!("system_concierge_agent.rb")
      load_seed!("system_ingress_manager_agent.rb")
      load_seed!("system_agent_hierarchy.rb")
    end

    it "hangs under System Concierge with one active seed edge and the P1 leaf delegation" do
      edges = Ai::AgentLineage.for_child(agent.id).active
      expect(edges.pluck(:parent_agent_id)).to eq([ root.id ])
      expect(edges.first.spawn_reason).to eq("seed")
      expect(agent.reload.parent_agent_id).to eq(root.id)

      policy = Ai::DelegationPolicy.resolve_for(agent_id: agent.id, account_id: account.id)
      expect(policy).to be_present
      expect(policy.inheritance_policy).to eq("conservative")
      expect(policy.max_depth).to eq(2)
      expect(policy.allowed_delegate_types).to eq([])
    end

    it "is no longer reported as 'ingress-manager(agent absent)' by the hierarchy drift report" do
      report = System::Governance::HierarchyReconciler.new(account: account).drift
      expect(report.skipped).not_to include("ingress-manager(agent absent)")
      expect(report.missing_edges).to be_empty
      expect(report.missing_policies).to be_empty
    end
  end

  # The four ingress executors bind to this agent (the acme executor leaves
  # Fleet Autonomy: no SIGNAL_BINDINGS entry routes to
  # AcmeCertificateProvisionExecutor — the sensor-routed system.acme_cert_rotate
  # lane fires PlatformMaintenanceExecutor, which stays Fleet Autonomy's), and
  # System Concierge keeps them for operator chat.
  describe "skill bindings" do
    before(:all) do
      glob = Rails.root.join("../extensions/system/server/app/services/system/ai/skills/**/*_executor.rb")
      Dir.glob(glob).each { |f| require_dependency f }
    end

    INGRESS_SKILL_SLUGS = %w[
      system-expose-service-local system-expose-service-publicly
      system-expose-service-public-tcp system-acme-certificate-provision
    ].freeze

    it "registers every ingress executor to the Ingress Manager AND System Concierge, none to Fleet Autonomy" do
      registry = System::Ai::Skills::SkillBindings.discover
      INGRESS_SKILL_SLUGS.each do |slug|
        owners = registry.select { |e| e[:skill_slug] == slug }.map { |e| e[:agent_name] }
        expect(owners).to contain_exactly("Ingress Manager", "System Concierge"), "#{slug} owners=#{owners.inspect}"
      end
      binding = System::Fleet::DecisionEngine::SIGNAL_BINDINGS.fetch("system.acme_cert_expiring")
      expect(binding[:skill]).not_to eq(System::Ai::Skills::AcmeCertificateProvisionExecutor)
      expect(System::Fleet::DecisionEngine::SIGNAL_BINDINGS.values.map { |b| b[:skill] })
        .not_to include(System::Ai::Skills::AcmeCertificateProvisionExecutor)
    end

    it "materialises the four Ai::AgentSkill rows through system_skill_bindings_seed.rb" do
      %w[system_skills_seed.rb system_provisioning_skills_seed.rb system_dr_skills_seed.rb
         system_concierge_agent.rb system_ingress_manager_agent.rb system_skill_bindings_seed.rb].each { |f| load_seed!(f) }

      bound = Ai::AgentSkill.where(ai_agent_id: agent.id, is_active: true).joins(:skill).pluck("ai_skills.slug")
      expect(bound).to match_array(INGRESS_SKILL_SLUGS)
    end
  end

  # The moved rows are written by THIS seed and not by the Fleet Autonomy seed
  # — asserted from the rows each seed leaves, not from the declarations.
  describe "the ingress rows' home" do
    it "are written here and NOT by the Fleet Autonomy seed" do
      load_seed!("fleet_autonomy_agent.rb")
      fleet = Ai::Agent.global.find_by(name: "Fleet Autonomy")
      expect(fleet).to be_present
      expect(Ai::InterventionPolicy.where(account: account, ai_agent_id: fleet.id, action_category: declared.keys)).to be_empty

      load_seed!("system_ingress_manager_agent.rb")
      expect(Ai::InterventionPolicy.where(account: account, ai_agent_id: agent.id, action_category: declared.keys).count)
        .to eq(declared.size)
    end
  end
end
