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
      #      composes spawn + provisioning + (optional) federation +
      #      PlatformDeployment record. Returns the deployment envelope
      #      including the federation acceptance_token (if federated)
      #      and the new node_instance_id.
      #
      # Composition: this skill is intentionally thin. The heavy lifting
      # is in the orchestrator. The skill exists so concierge can render
      # the wizard card naturally as part of a conversation.
      #
      # Plan reference: chat-driven platform deployment (D2).
      class PlatformDeployExecutor
        MODES = %w[standalone federated].freeze

        def self.descriptor
          {
            name: "platform_deploy",
            description: "Deploy a new Powernode platform. Pass mode='standalone' for a sovereign platform or mode='federated' for one that handshakes back with this platform on first boot. With no params, returns a wizard payload describing the form the operator should fill in.",
            category: "system",
            inputs: {
              mode: { type: "string", required: false,
                      description: "Deployment mode: standalone | federated. Omit to receive a wizard payload." },
              name: { type: "string", required: false,
                      description: "Human-readable name for the new platform / deployment." },
              template_slug: { type: "string", required: false, default: "powernode-hub",
                               description: "NodeTemplate slug to use (default: powernode-hub)." },
              parent_url: { type: "string", required: false,
                            description: "Required for federated mode — reachable URL of THIS platform that the child posts back to." },
              spawn_mode: { type: "string", required: false,
                            description: "Required for federated mode — one of: managed_child, autonomous_peer, cluster_member." },
              region: { type: "string", required: false,
                        description: "Optional provider region preference." },
              instance_size: { type: "string", required: false,
                               description: "Optional provider instance type preference." },
              service_role: { type: "string", required: false, default: "api",
                              description: "Service role for the PlatformDeployment row (default: api)." },
              public_dns_hostname: { type: "string", required: false,
                                     description: "Optional public DNS hostname for the new platform." },
              token_ttl_seconds: { type: "integer", required: false,
                                   description: "Acceptance-token TTL for federated spawns (default: 7 days)." }
            },
            outputs: {
              ok: :boolean,
              card: :object,
              deployment: :object,
              acceptance_token: :string,
              spawn_payload: :object
            },
            requires_approval: false,
            blast_radius: :high
          }
        end

        def initialize(account:, agent: nil, user: nil)
          @account = account
          @agent = agent
          @user = user
        end

        def execute(mode: nil, **params)
          # No mode → render the wizard card so the operator can fill in the form
          # in chat. Card carries the catalog of templates + spawn modes so the
          # UI doesn't have to refetch.
          return wizard_response if mode.blank?

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
            parent_url: params[:parent_url].presence,
            spawn_mode: params[:spawn_mode].presence,
            token_ttl_seconds: params[:token_ttl_seconds].presence&.to_i,
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

          success(
            mode: result.mode,
            node_instance_id: result.node_instance_id,
            federation_peer_id: result.federation_peer_id,
            platform_deployment_id: result.platform_deployment_id,
            acceptance_token: result.acceptance_token,
            spawn_payload: result.spawn_payload,
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
              defaults: {
                template_slug: "powernode-hub",
                mode: "standalone",
                spawn_mode: "managed_child",
                token_ttl_seconds: 7 * 86_400
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
          if result.mode == "federated" && result.acceptance_token.present?
            steps << "Capture the acceptance_token NOW — it's shown only once. The child platform's first-run handler will present it to /federation_api/accept to complete the handshake."
          end
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

        def success(payload)
          { success: true, requires_approval: false, data: payload }
        end

        def failure(msg)
          { success: false, error: msg }
        end
      end
    end
  end
end
