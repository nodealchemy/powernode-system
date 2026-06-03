# frozen_string_literal: true

module System
  # Deploys an inference runtime (ollama) onto a GPU node and makes it consumable
  # (AI/MCP workload substrate L1 — see docs/design/ai-mcp-workload-substrate.md):
  #
  #   1. assign the gpu-nvidia-runtime + inference-ollama modules to the node
  #   2. resolve the inference endpoint (explicit override > SDWAN VIP > instance addr)
  #   3. register/point an ollama Ai::Provider at that endpoint (platform-agent use)
  #   4. (optional, best-effort) publish the endpoint as an SDWAN ServiceOffering so
  #      other node instances consume it cross-cluster
  #
  # Idempotent: re-deploying to the same node/endpoint reuses assignments + provider.
  class InferenceDeploymentService
    GPU_MODULE       = "gpu-nvidia-runtime"
    INFERENCE_MODULE = "inference-ollama"
    DEFAULT_PORT     = 11_434

    class DeploymentError < StandardError; end

    Result = ::Struct.new(
      :instance_id, :node_id, :module_assignment_ids, :provider_id,
      :endpoint, :model, :offering_id, keyword_init: true
    )

    def self.deploy!(account:, **kwargs)
      new(account: account).deploy!(**kwargs)
    end

    def initialize(account:)
      @account = account
    end

    # @param instance [System::NodeInstance] the GPU node to host inference
    # @param model [String, nil] model tag (defaults to the module's default_model)
    # @param endpoint_override [String, nil] explicit URL (e.g. an existing ollama for smoke)
    # @param sdwan_network_id / vip_cidr [String, nil] optional SDWAN publication
    # @param creator [User, nil] provider owner (defaults to an account user)
    def deploy!(instance:, model: nil, endpoint_override: nil, sdwan_network_id: nil, vip_cidr: nil)
      raise DeploymentError, "instance is required" unless instance.is_a?(::System::NodeInstance)

      node = instance.node
      raise DeploymentError, "instance #{instance.id} has no node" unless node

      gpu = find_module!(GPU_MODULE)
      inf = find_module!(INFERENCE_MODULE)
      assignments = [ gpu, inf ].map { |m| assign_module!(node, m) }

      inf_cfg = inf.config.to_h.fetch("inference", {})
      port    = (inf_cfg["api_port"] || DEFAULT_PORT).to_i
      model ||= inf_cfg["default_model"]

      offering_id = nil
      endpoint = endpoint_override.to_s.strip.presence
      if endpoint.nil? && sdwan_network_id.present? && vip_cidr.present?
        composed = compose_offering(instance: instance, sdwan_network_id: sdwan_network_id, vip_cidr: vip_cidr, port: port)
        if composed
          offering_id = composed[:offering_id]
          endpoint = http_url(composed[:vip_address], port)
        end
      end
      endpoint ||= http_url(instance.try(:private_ip_address).presence || instance.try(:public_ip_address), port)
      raise DeploymentError, "could not resolve an inference endpoint (provide endpoint_override, SDWAN network+vip, or an instance address)" if endpoint.blank?

      provider = upsert_provider!(endpoint: endpoint, model: model)

      Result.new(
        instance_id: instance.id, node_id: node.id,
        module_assignment_ids: assignments.map(&:id), provider_id: provider.id,
        endpoint: endpoint, model: model, offering_id: offering_id
      )
    end

    private

    attr_reader :account

    def find_module!(name)
      ::System::NodeModule.find_by(account: account, name: name) ||
        raise(DeploymentError, "module '#{name}' not in catalog — run its seed first")
    end

    def assign_module!(node, mod)
      ::System::NodeModuleAssignment.find_or_create_by!(node: node, node_module: mod) do |a|
        a.enabled  = true
        a.priority = (mod.priority || 100)
      end
    end

    def http_url(host, port)
      host = host.to_s.strip
      return nil if host.empty?

      host.include?(":") ? "http://[#{host}]:#{port}" : "http://#{host}:#{port}"
    end

    # Best-effort SDWAN publication. Returns nil (and logs) when the SDWAN context
    # is incomplete, so a deploy without a network still succeeds (provider-only).
    def compose_offering(instance:, sdwan_network_id:, vip_cidr:, port:)
      peer_id = instance.try(:sdwan_peer_id)
      return nil if peer_id.blank?

      result = ::System::Ai::Skills::ServiceDiscoveryComposerExecutor.new(account: account).perform(
        service_name: "ollama-#{instance.name}",
        service_slug: "ollama-#{instance.id.to_s.delete('-')[0, 12]}",
        sdwan_network_id: sdwan_network_id, backend_peer_id: peer_id,
        backend_port: port, vip_cidr: vip_cidr, protocol: "http"
      )
      return nil unless result.is_a?(Hash) && result[:success]

      { offering_id: result.dig(:data, :offering_id), vip_address: result.dig(:data, :vip_address) }
    rescue StandardError => e
      ::Rails.logger.warn("[InferenceDeploymentService] service discovery skipped: #{e.class}: #{e.message}")
      nil
    end

    # Register (or repoint) an ollama Ai::Provider at the deployed endpoint, keyed
    # by (provider_type, api_endpoint) so re-deploys are idempotent.
    def upsert_provider!(endpoint:, model:)
      model ||= "llama3.1:8b"
      provider = account.ai_providers.find_or_initialize_by(provider_type: "ollama", api_endpoint: endpoint)
      provider.name           = provider.name.presence || "Ollama @ #{endpoint}"
      provider.slug           = provider.slug.presence || provider_slug(endpoint)
      provider.api_base_url   = endpoint
      provider.is_active      = true
      provider.priority_order = provider.priority_order.to_i.positive? ? provider.priority_order : 10
      provider.capabilities       = provider.capabilities.presence       || %w[text_generation chat]
      provider.supported_models   = provider.supported_models.presence   || [ { "id" => model, "name" => model } ]
      provider.configuration_schema = provider.configuration_schema.presence || { "default_model" => model }
      provider.save!
      provider
    end

    def provider_slug(endpoint)
      "ollama-#{endpoint.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/(^-|-$)/, '')}"[0, 50]
    end
  end
end
