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
    # The callable core's blast_radius_estimator seam resolves to.
    module BlastRadius
      def self.call(account:, params:)
        ::System::EnvironmentResolver.blast_radius(account: account, params: params)
      end
    end

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
    # A VIP lives on ONE network, so it is placed exactly where an action on
    # that network is placed. Sdwan::VipFailoverExecutor names only the VIP.
    VIRTUAL_IP_KEYS = %w[virtual_ip_id sdwan_virtual_ip_id].freeze
    # A certificate carries no plane and no instance. It resolves through what
    # TERMINATES it: the services holding it as their local_certificate, then
    # those services' VIPs (their own and their backends'), then those VIPs'
    # networks. A cert fronting a static backend_host with no VIP anywhere
    # resolves to nothing, which is honest — there is no fleet row to place.
    CERTIFICATE_KEYS = %w[certificate_id acme_certificate_id].freeze
    # A federation peer is the one SDWAN-adjacent row that carries an
    # environment_id of its own (it represents a whole remote cell, not an
    # instance in this one), so it is read directly. The column is optional:
    # an unplaced peer still resolves to nothing.
    FEDERATION_PEER_KEYS = %w[federation_peer_id].freeze

    def self.call(account:, params:)
      new(account, params).call
    end

    def initialize(account, params)
      @account = account
      @params = self.class.flatten_params(params)
    end

    # A gated tool action parks its params packed as
    # {tool_class, action, tool_params: {...}} (Ai::Executors::DeferredToolCall);
    # the subject ids live under tool_params. Read through them, with the
    # top level winning on a clash.
    def self.flatten_params(params)
      base = (params || {}).to_h.with_indifferent_access
      inner = base[:tool_params]
      inner = inner.to_h.with_indifferent_access if inner.respond_to?(:to_h)
      inner.is_a?(Hash) ? inner.merge(base) : base
    end

    # An explicit target plane on the params — the promotion verbs name the
    # environment a version is promoted INTO. Combined with the subject's
    # plane by #call (strictest wins).
    ENVIRONMENT_KEYS = %w[environment environment_id environment_slug].freeze

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

    # An explicit plane is a FLOOR, never an override: the action is placed in
    # the strictest of the named plane and the plane its subject sits in, so
    # naming `environment: "dev"` on a prod instance still gates in prod.
    def call
      explicit = explicit_environment
      subject = subject_environment
      return subject if explicit.nil?
      return explicit if subject.nil?

      strictest([ explicit, subject ])
    end

    def subject_environment
      lookup(INSTANCE_KEYS, ::System::NodeInstance) ||
        lookup(NODE_KEYS, ::System::Node) ||
        lookup(TEMPLATE_KEYS, ::System::NodeTemplate) ||
        lookup(POOL_KEYS, ::System::InstancePool) ||
        through_plural ||
        through_task_attributes ||
        through_peer ||
        through_network ||
        through_virtual_ip ||
        through_certificate ||
        through_federation_peer
    end

    # The blast radius of a params set: how many instances it touches. Core's
    # `blast_radius_estimator` seam (Ai::EnvironmentResolution.blast_radius).
    # Singular ids count 1 (an instance) or the live instances under a node /
    # template / pool; plural ids count the matching rows; a network counts
    # its peers' instances. nil when the params name nothing this extension
    # can count.
    def self.blast_radius(account:, params:)
      p = flatten_params(params)
      first = ->(keys) { keys.map { |k| p[k] }.find(&:present?) }
      live = ::System::NodeInstance.where(account_id: account.id).where.not(status: "terminated")

      if (id = first.(INSTANCE_KEYS)).present?
        return live.where(id: id.to_s).count
      end
      if (module_id = p[:module_id]).present?
        # The ladder verbs: every live instance in the named plane (or the
        # whole account when none is named) whose node carries the module —
        # by node assignment or through its template.
        scope = live
        if (env_key = first.(ENVIRONMENT_KEYS)).present?
          env = ::Ai::Environment.find_for_account(account.id, env_key.to_s)
          scope = env ? scope.where(environment_id: env.id) : scope.none
        end
        by_assignment = ::System::NodeModuleAssignment.where(node_module_id: module_id.to_s).select(:node_id)
        by_template = ::System::Node.where(account_id: account.id,
                                           node_template_id: ::System::TemplateModule.where(node_module_id: module_id.to_s).select(:node_template_id))
                                    .select(:id)
        return scope.where(node_id: by_assignment).or(scope.where(node_id: by_template)).count
      end
      if (id = first.(NODE_KEYS)).present?
        return live.where(node_id: ::System::Node.where(account_id: account.id, id: id.to_s).select(:id)).count
      end
      if (id = first.(TEMPLATE_KEYS)).present?
        nodes = ::System::Node.where(account_id: account.id, node_template_id: id.to_s).select(:id)
        return live.where(node_id: nodes).count
      end
      if (id = first.(POOL_KEYS)).present?
        return live.where(instance_pool_id: id.to_s).count
      end
      PLURAL_KEYS.each do |keys, model|
        ids = Array(first.(keys)).map(&:to_s).reject(&:blank?)
        next if ids.empty?

        return case model.name
               when "System::NodeInstance" then live.where(id: ids).count
               when "System::Node" then live.where(node_id: ids).count
               when "System::NodeTemplate"
                 live.where(node_id: ::System::Node.where(account_id: account.id, node_template_id: ids).select(:id)).count
               when "System::InstancePool" then live.where(instance_pool_id: ids).count
               end
      end
      if (id = first.(PEER_KEYS)).present?
        return live.where(id: ::Sdwan::Peer.where(account_id: account.id, id: id.to_s)
                                           .select(:node_instance_id)).count
      end
      if (id = first.(NETWORK_KEYS)).present?
        network = ::Sdwan::Network.where(account_id: account.id).find_by(id: id.to_s)
        return network ? instances_behind_networks(account, live, [ id ]) : nil
      end
      if (id = first.(VIRTUAL_IP_KEYS)).present?
        vip = ::Sdwan::VirtualIp.where(account_id: account.id).find_by(id: id.to_s)
        return vip ? instances_behind_networks(account, live, [ vip.sdwan_network_id ]) : nil
      end
      if (id = first.(CERTIFICATE_KEYS)).present?
        networks = certificate_network_ids(account, id.to_s)
        return networks.empty? ? nil : instances_behind_networks(account, live, networks)
      end
      # DELIBERATELY unmeasured: FEDERATION_PEER_KEYS. A federation-peer
      # remediation acts on the LINK to a remote cell, so counting local
      # instances would name rows the action does not touch, and counting the
      # remote cell's is not this account's to count. nil means "no ceiling
      # applies" (Ai::EnvironmentResolution#blast_radius) — the peer's own
      # plane still drives every other escalation rule, which is the part that
      # protects the control plane here.
      nil
    rescue ActiveRecord::StatementInvalid
      nil
    end

    # The VIPs a certificate is terminated on, as network ids: services holding
    # it as their local_certificate, then those services' own backend_vip plus
    # every member backend's, then those VIPs' networks.
    def self.certificate_network_ids(account, certificate_id)
      services = ::Sdwan::Service.where(account_id: account.id, local_certificate_id: certificate_id)
      vip_ids = services.pluck(:backend_vip_id) +
                ::Sdwan::ServiceBackend.where(account_id: account.id,
                                              sdwan_service_id: services.select(:id)).pluck(:backend_vip_id)
      vip_ids = vip_ids.compact.uniq
      return [] if vip_ids.empty?

      ::Sdwan::VirtualIp.where(account_id: account.id, id: vip_ids).pluck(:sdwan_network_id).compact.uniq
    end

    def self.instances_behind_networks(account, live, network_ids)
      ids = Array(network_ids).compact.map(&:to_s).reject(&:blank?)
      return 0 if ids.empty?

      live.where(id: ::Sdwan::Peer.where(account_id: account.id, sdwan_network_id: ids)
                                  .select(:node_instance_id)).count
    end

    private

    def explicit_environment
      value = first_present(ENVIRONMENT_KEYS)
      return nil if value.blank?

      # Named but unknown is FAIL CLOSED: falling through to the subject keys
      # would gate the action in a plane the caller did not name.
      ::Ai::Environment.find_for_account(@account.id, value.to_s) ||
        raise(::Ai::EnvironmentResolution::ResolverError, "environment '#{value}' is not in this account")
    end

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

      return nil unless ::Sdwan::Network.where(account_id: @account.id).exists?(id: id)

      strictest_across_networks([ id ])
    rescue ActiveRecord::StatementInvalid
      nil
    end

    def through_virtual_ip
      id = first_present(VIRTUAL_IP_KEYS)
      return nil if id.blank?

      vip = ::Sdwan::VirtualIp.where(account_id: @account.id).find_by(id: id.to_s)
      vip && strictest_across_networks([ vip.sdwan_network_id ])
    rescue ActiveRecord::StatementInvalid
      nil
    end

    def through_certificate
      id = first_present(CERTIFICATE_KEYS)
      return nil if id.blank?

      strictest_across_networks(self.class.certificate_network_ids(@account, id.to_s))
    rescue ActiveRecord::StatementInvalid
      nil
    end

    def through_federation_peer
      id = first_present(FEDERATION_PEER_KEYS)
      return nil if id.blank?

      ::System::FederationPeer.where(account_id: @account.id).includes(:environment)
                              .find_by(id: id.to_s)&.environment
    rescue ActiveRecord::StatementInvalid
      nil
    end

    # An action reaching several networks is placed in the STRICTEST plane any
    # of their peers' instances sits in — protected first, then highest tier.
    def strictest_across_networks(network_ids)
      ids = Array(network_ids).compact.map(&:to_s).reject(&:blank?)
      return nil if ids.empty?

      environments = ::Ai::Environment.where(
        id: ::System::NodeInstance.where(
          id: ::Sdwan::Peer.where(account_id: @account.id, sdwan_network_id: ids).select(:node_instance_id)
        ).select(:environment_id)
      ).to_a
      strictest(environments)
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
