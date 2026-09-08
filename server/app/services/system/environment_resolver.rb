# frozen_string_literal: true

module System
  # The system extension's answer to core's `environment_resolver` seam
  # (Ai::EnvironmentResolution, Environment campaign increment 3): given the
  # params of a gated operation, which plane does it act on?
  #
  # Reads the fleet rows this extension owns — instance, node, template, pool —
  # under the ACCOUNT scope, so a foreign id resolves to nothing rather than to
  # another tenant's environment. The first key present wins; keys are the
  # spellings the fleet tool, the controllers and the skill executors actually
  # use for their executor params.
  class EnvironmentResolver
    INSTANCE_KEYS = %w[instance_id node_instance_id].freeze
    NODE_KEYS     = %w[node_id].freeze
    TEMPLATE_KEYS = %w[template_id node_template_id].freeze
    POOL_KEYS     = %w[instance_pool_id pool_id].freeze
    # SDWAN objects carry no environment of their own; they resolve THROUGH
    # the instances they touch. A peer is one instance; a network is every
    # peer's instance, and an action on the network is placed in the
    # STRICTEST of those planes (protected first, then highest tier) — a
    # network that spans dev and the control plane is a control-plane network
    # for gating purposes.
    PEER_KEYS     = %w[peer_id sdwan_peer_id].freeze
    NETWORK_KEYS  = %w[network_id sdwan_network_id].freeze

    def self.call(account:, params:)
      new(account, params).call
    end

    def initialize(account, params)
      @account = account
      @params = (params || {}).to_h.with_indifferent_access
    end

    # Plural spellings the skill executors use (`instance_ids:` on the boot-
    # image drift rollout, rolling module upgrade, relocate workload, ...).
    # A batch is placed in the STRICTEST plane it touches.
    PLURAL_KEYS = {
      %w[instance_ids node_instance_ids] => ::System::NodeInstance,
      %w[node_ids]                       => ::System::Node,
      %w[template_ids node_template_ids] => ::System::NodeTemplate,
      %w[instance_pool_ids pool_ids]     => ::System::InstancePool
    }.freeze
    # The REST task route (System::Task) names its subject polymorphically.
    OPERABLE_MODELS = {
      "System::NodeInstance" => ::System::NodeInstance,
      "System::Node"         => ::System::Node
    }.freeze

    def call
      lookup(INSTANCE_KEYS, ::System::NodeInstance) ||
        lookup(NODE_KEYS, ::System::Node) ||
        lookup(TEMPLATE_KEYS, ::System::NodeTemplate) ||
        lookup(POOL_KEYS, ::System::InstancePool) ||
        through_plural ||
        through_task_attributes ||
        through_peer ||
        through_network
    end

    private

    def through_plural
      PLURAL_KEYS.each do |keys, model|
        ids = Array(first_present(keys)).map(&:to_s).reject(&:blank?)
        next if ids.empty?

        environments = ::Ai::Environment.where(
          id: model.where(account_id: @account.id, id: ids).select(:environment_id)
        ).to_a
        return strictest(environments) if environments.any?
      end
      nil
    rescue ActiveRecord::StatementInvalid
      nil
    end

    def through_task_attributes
      attrs = @params[:task_attributes]
      attrs = attrs.to_h.with_indifferent_access if attrs.respond_to?(:to_h)
      return nil unless attrs.is_a?(Hash)

      model = OPERABLE_MODELS[attrs[:operable_type].to_s]
      id = attrs[:operable_id]
      return nil if model.nil? || id.blank?

      model.where(account_id: @account.id).find_by(id: id.to_s)&.environment
    rescue ActiveRecord::StatementInvalid
      nil
    end

    def strictest(environments)
      environments.max_by { |e| [ e.protected? ? 1 : 0, e.tier ] }
    end

    def through_peer
      id = first_present(PEER_KEYS)
      return nil if id.blank?

      ::Sdwan::Peer.where(account_id: @account.id).includes(node_instance: :environment)
                   .find_by(id: id)&.node_instance&.environment
    rescue ActiveRecord::StatementInvalid
      nil
    end

    def through_network
      id = first_present(NETWORK_KEYS)
      return nil if id.blank?

      network = ::Sdwan::Network.where(account_id: @account.id).find_by(id: id)
      return nil unless network

      environments = ::Ai::Environment.where(
        id: ::System::NodeInstance.where(id: network.peers.select(:node_instance_id)).select(:environment_id)
      ).to_a
      strictest(environments)
    rescue ActiveRecord::StatementInvalid
      nil
    end

    def first_present(keys)
      keys.map { |k| @params[k] }.find(&:present?)
    end

    def lookup(keys, model)
      id = first_present(keys)
      return nil if id.blank?

      row = model.where(account_id: @account.id).find_by(id: id.to_s)
      row&.environment
    rescue ActiveRecord::StatementInvalid
      # A non-UUID value makes the id predicate unrepresentable; that is
      # "unknown", not an error the gate should surface.
      nil
    end
  end
end
