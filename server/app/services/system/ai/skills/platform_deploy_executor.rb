# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Skill: deploy a new Powernode platform.
      #
      # Two execution shapes:
      #
      #   1. "wizard" — operator asks vaguely ("spin up a new platform").
      #      Returns a chat-card payload describing the form fields the
      #      operator should fill in. No state is mutated. The frontend
      #      renders a PlatformDeploymentWizard card; submitting it
      #      calls this skill again with full params.
      #
      #   2. "deploy" — all required params present. Delegates to
      #      System::PlatformDeploymentOrchestrator.deploy! which
      #      composes provisioning + PlatformDeployment record. Returns
      #      the deployment envelope and the new node_instance_id.
      #
      # Standalone only. Federated deployment is refused here
      # (IMP-c0687cfb3a05): it mints a single-use acceptance token, and
      # everything this skill returns is agent-facing.
      #
      # This refusal is NOT redundant with the one on Ai::Tools::SystemFleetTool.
      # The tool is not this executor's only caller: the skill is bound to
      # System Concierge, so Ai::Missions::MissionComposer can select it into a
      # plan and Ai::SkillCompositionRunner resolves and invokes it directly —
      # bypassing the tool, and landing the result in the step's
      # metadata["last_outputs"]. Both entry points have to refuse.
      #
      # Federated spawns go through
      # Api::V1::System::Platform::DeploymentsController#create, which runs the
      # same orchestrator and renders the token to an HTTP response.
      #
      # Composition: this skill is intentionally thin. The heavy lifting
      # is in the orchestrator. The skill exists so concierge can render
      # the wizard card naturally as part of a conversation.
      #
      # Plan reference: chat-driven platform deployment (D2).
      class PlatformDeployExecutor < BaseSkillExecutor
        # MODES stays complete: the wizard payload advertises both modes to the
        # OPERATOR form, which submits to POST /api/v1/system/platform/deployments
        # (PlatformDeploymentWizardCard → provisioningApi.createPlatformDeployment).
        # Only this skill's own deploy branch refuses federated.
        MODES = %w[standalone federated].freeze
        FEDERATED_MODE = "federated"

        skill_descriptor(
          name: "platform_deploy",
          description: "Deploy a new Powernode platform. Pass mode='standalone' for a sovereign platform. With no params, returns a wizard payload describing the form the operator should fill in. mode='federated' is NOT available here — it mints a single-use acceptance token that this surface cannot deliver; operators deploy federated platforms over POST /api/v1/system/platform/deployments, which reveals the token once in its HTTP response.",
          category: "system",
          inputs: {
            mode: { type: "string", required: false,
                    description: "Deployment mode: standalone. Omit to receive a wizard payload. 'federated' is refused here with the operator path to use instead." },
            name: { type: "string", required: false,
                    description: "Human-readable name for the new platform / deployment." },
            template_slug: { type: "string", required: false, default: "powernode-hub",
                             description: "NodeTemplate slug to use (default: powernode-hub)." },
            parent_url: { type: "string", required: false,
                          description: "Federated-only — reachable URL of THIS platform that the child posts back to. Supply it on the operator API path; federated mode is refused here." },
            spawn_mode: { type: "string", required: false,
                          description: "Federated-only — one of: managed_child, autonomous_peer, cluster_member. Supply it on the operator API path; federated mode is refused here." },
            region: { type: "string", required: false,
                      description: "Optional provider region preference." },
            instance_size: { type: "string", required: false,
                             description: "Optional provider instance type preference." },
            service_role: { type: "string", required: false, default: "api",
                            description: "Service role for the PlatformDeployment row (default: api)." },
            public_dns_hostname: { type: "string", required: false,
                                   description: "Optional public DNS hostname for the new platform." }
          },
          outputs: {
            ok: :boolean,
            card: :object,
            deployment: :object
          }
        )

        binds_to "concierge"

        protected

        def perform(mode: nil, **params)
          # No mode → render the wizard card so the operator can fill in the form
          # in chat. Card carries the catalog of templates + spawn modes so the
          # UI doesn't have to refetch.
          return wizard_response if mode.blank?

          # IMP-c0687cfb3a05 — refuse before the orchestrator runs, so no
          # FederationPeer row is created, no token is minted, and no child is
          # provisioned against a secret this surface cannot hand back.
          # Normalizing (rather than comparing to the literal MODES entry)
          # refuses a superset of what would reach the mint.
          if mode.to_s.strip.downcase == FEDERATED_MODE
            return failure(
              "federated deployment is not available through the platform_deploy skill: it mints " \
              "a single-use federation acceptance token, and this skill's result is handed to the " \
              "model provider and persisted with the conversation, so the plaintext cannot be " \
              "delivered here. Deploy federated platforms over the operator API instead — " \
              "POST /api/v1/system/platform/deployments (permission system.platform.deploy) runs " \
              "the same orchestrator and reveals the acceptance_token exactly once in its HTTP " \
              "response."
            )
          end

          unless MODES.include?(mode.to_s)
            return failure("Unknown mode: #{mode.inspect}; allowed: #{MODES.inspect}")
          end

          if params[:name].blank?
            return failure("name is required for deployment")
          end

          template_slug = params[:template_slug].presence || "powernode-hub"
          deploy_params = {
            name: params[:name].to_s,
            template_slug: template_slug,
            region: params[:region].presence,
            instance_size: params[:instance_size].presence,
            service_role: params[:service_role].presence || "api",
            public_dns_hostname: params[:public_dns_hostname].presence,
            # Storage volume integration (VOL.1+)
            volume_id: params[:volume_id].presence,
            skip_volume: params[:skip_volume] == true,
            record_deployment: true
          }.compact

          result = ::System::PlatformDeploymentOrchestrator.deploy!(
            account: @account,
            mode: mode.to_s,
            params: deploy_params,
            initiated_by_user: @user
          )

          unless result.ok?
            return failure("Deploy failed: #{result.error}")
          end

          # No acceptance_token / spawn_payload keys: both carried the federated
          # spawn's plaintext token, and this envelope is agent-facing
          # (IMP-c0687cfb3a05). The federated branch is refused above, so
          # neither has a value to carry any more.
          success(
            mode: result.mode,
            node_instance_id: result.node_instance_id,
            federation_peer_id: result.federation_peer_id,
            platform_deployment_id: result.platform_deployment_id,
            storage_volume: result.storage_volume,
            next_steps: build_next_steps(result, deploy_params)
          )
        end

        private

        # Returns a chat-card payload describing the form the operator
        # should fill in. The agent_tool_bridge / chat surface will turn
        # this into a `platform_deployment_wizard` ChatCard once the
        # frontend renderer lands (D3). For now this gives concierge a
        # structured response it can paraphrase into a follow-up prompt.
        def wizard_response
          templates = ::System::NodeTemplate.where(account_id: @account.id)
                                             .where("name LIKE ?", "powernode-hub%")
                                             .order(:name)
                                             .pluck(:name, :description)

          # Storage affordances — read from platform shared memory so
          # operators can tune recommendations without redeploying.
          recs = ::System::Platform::StorageRecommendations.fetch(account: @account)
          stateful_roles = recs["stateful_role_mounts"].keys
          recommended_sizes = recs["recommended_size_gb_by_role"]

          available_volumes = ::System::ProviderVolume
                                .where(account: @account, status: "available", node_instance_id: nil)
                                .order(:size_gb, :created_at)
                                .limit(50)
                                .map do |v|
            {
              id: v.id,
              name: v.name,
              size_gb: v.size_gb,
              provider_region_id: v.provider_region_id,
              created_at: v.created_at.iso8601
            }
          end

          success(
            card: {
              kind: "platform_deployment_wizard",
              phase: "form",
              fields: form_field_spec,
              modes: MODES.map { |m| { value: m, label: mode_label(m), help: mode_help(m) } },
              templates: templates.map { |n, d| { value: n, label: n, description: d } },
              spawn_modes: ::System::SpawnPlatformService::SPAWN_MODES.map do |m|
                { value: m, label: m.tr("_", " ") }
              end,
              # Operator-tunable storage recommendations (sourced from
              # shared memory; key = powernode.storage_recommendations)
              storage: {
                stateful_roles: stateful_roles,
                mount_points: recs["stateful_role_mounts"],
                recommended_size_gb_by_role: recommended_sizes,
                available_volumes: available_volumes,
                updated_at: recs["updated_at"]
              },
              # No token_ttl_seconds default: this skill no longer declares it
              # as an input (IMP-c0687cfb3a05), and nothing reads it — the
              # wizard card consumes template_slug/mode/spawn_mode only. The
              # REST deploy path still accepts a TTL; it just isn't defaulted
              # from here.
              defaults: {
                template_slug: "powernode-hub",
                mode: "standalone",
                spawn_mode: "managed_child"
              }
            }
          )
        end

        def form_field_spec
          [
            { name: "mode", type: "select", required: true,
              help: "Standalone = sovereign platform. Federated = peers with this platform on first boot." },
            { name: "name", type: "string", required: true,
              help: "Human-readable name for the deployment." },
            { name: "template_slug", type: "select", required: true,
              help: "NodeTemplate to provision from. powernode-hub is the canonical single-node platform." },
            { name: "service_role", type: "select", required: false,
              options: %w[api worker frontend postgres redis reverse-proxy satellite-runtime] },
            { name: "public_dns_hostname", type: "string", required: false,
              help: "Optional. ACME cert is issued automatically post-boot if set." },
            { name: "spawn_mode", type: "select", required: false,
              help: "Required for federated mode." },
            { name: "parent_url", type: "string", required: false,
              help: "Required for federated mode — this platform's reachable URL." }
          ]
        end

        def mode_label(mode)
          { "standalone" => "Standalone", "federated" => "Federated" }[mode]
        end

        def mode_help(mode)
          case mode
          when "standalone"
            "Fully sovereign platform. No FederationPeer relationship. New platform creates its own admin on first boot."
          when "federated"
            "Spawned as a federation peer. Handshakes back to this platform on first boot. Choose managed_child to retain operator-scope grant, autonomous_peer for equal peering, cluster_member for HA PG replica."
          end
        end

        def build_next_steps(result, params)
          steps = []
          if result.storage_volume.is_a?(Hash) && result.storage_volume[:error].nil? && result.storage_volume[:volume_id]
            sv = result.storage_volume
            steps << "Volume #{sv[:volume_name]} (#{sv[:size_gb]} GB) attached at #{sv[:device_name]} — the on-node agent will mount it at #{sv[:mount_point]} during first boot."
          elsif ::System::Platform::StorageRecommendations.stateful_role?(account: @account, role: params[:service_role]) && result.storage_volume.nil?
            steps << "Service role #{params[:service_role]} is stateful but no volume was attached — create + attach a ProviderVolume of at least #{::System::Platform::StorageRecommendations.recommended_size_gb(account: @account, role: params[:service_role])} GB before workload start, or data will live on ephemeral disk."
          end
          if params[:public_dns_hostname].present?
            steps << "Point #{params[:public_dns_hostname]} DNS at the new node's public IP. The child's AcmeCertificateRenewalJob will issue a Let's Encrypt cert within ~5 minutes of boot."
          else
            steps << "No public DNS configured — the new platform serves on its private IP / SDWAN VIP. Configure DNS + ACME later if external access is needed."
          end
          steps << "Watch deployment status in /app/system/compute/platform/scaling. The new instance shows as `starting` initially, then `provisioning` → `running` once the provider acks."
          steps
        end
      end
    end
  end
end
