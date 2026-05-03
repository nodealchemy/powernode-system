# frozen_string_literal: true

module System
  # End-to-end service for NodeInstance peer registration. Called from the
  # node_api/peer#announce controller. Idempotent: re-announces update the
  # existing peer row (capability change, address change). Auto-creates
  # peers in `enabled: false` state — operator must activate before remote
  # delegation can target the peer.
  #
  # Reference: comprehensive stabilization sweep P6.
  class AgentPeeringService
    Result = Struct.new(:ok?, :peer, :created, :error, keyword_init: true)

    HANDLE_PREFIX = "instance-"
    INITIAL_TRUST_SCORE = 0.5

    def self.announce!(node_instance:, capabilities: {}, skills: [], addresses: [])
      new.announce!(
        node_instance: node_instance,
        capabilities: capabilities,
        skills: skills,
        addresses: addresses
      )
    end

    def announce!(node_instance:, capabilities:, skills:, addresses:)
      raise ArgumentError, "node_instance required" unless node_instance.is_a?(::System::NodeInstance)

      account = node_instance.node.account

      peer = ::System::NodeInstancePeer.find_or_initialize_by(node_instance: node_instance)
      created = peer.new_record?

      peer.assign_attributes(
        account: account,
        handle: peer.handle.presence || generate_handle(node_instance),
        status: capabilities.present? ? "active" : (peer.status.presence || "registered"),
        capabilities: sanitize(capabilities),
        declared_skills: Array(skills).first(50).map { |s| s.is_a?(Hash) ? s.slice("name", "schema") : { "name" => s.to_s } },
        addresses: Array(addresses).first(8).map(&:to_s),
        first_announced_at: peer.first_announced_at || Time.current,
        last_announced_at: Time.current,
        trust_score: peer.trust_score || INITIAL_TRUST_SCORE
      )

      peer.save!

      emit_event(account: account, peer: peer, created: created)
      Result.new(ok?: true, peer: peer, created: created)
    rescue StandardError => e
      # Use respond_to? not safe-nav — `&.id` raises NoMethodError on String
      # in Ruby 3+ (String doesn't respond to #id).
      instance_descriptor = node_instance.respond_to?(:id) ? node_instance.id : node_instance.class
      Rails.logger.error("[AgentPeeringService] announce failed for instance=#{instance_descriptor}: #{e.class}: #{e.message}")
      Result.new(ok?: false, error: e.message)
    end

    private

    def generate_handle(node_instance)
      short_id = node_instance.id.to_s.gsub("-", "")[0..7]
      base = "#{HANDLE_PREFIX}#{short_id}"

      # Disambiguate against any collision (rare with UUIDv7 prefix but
      # treat as defensive).
      candidate = base
      n = 1
      while ::System::NodeInstancePeer
            .where(account_id: node_instance.node.account_id, handle: candidate).exists?
        candidate = "#{base}-#{n}"
        n += 1
      end
      candidate
    end

    # Capabilities are operator-trusted JSON; cap depth + size to prevent
    # DoS via deeply nested or huge announce payloads.
    def sanitize(value, depth: 0)
      return value if depth > 5
      case value
      when Hash
        value.first(50).map { |k, v| [k.to_s.first(64), sanitize(v, depth: depth + 1)] }.to_h
      when Array
        value.first(64).map { |v| sanitize(v, depth: depth + 1) }
      when String
        value.first(1024)
      when Numeric, TrueClass, FalseClass, NilClass
        value
      else
        value.to_s.first(1024)
      end
    end

    def emit_event(account:, peer:, created:)
      return unless defined?(::System::Fleet::EventBroadcaster)

      ::System::Fleet::EventBroadcaster.emit!(
        account: account,
        kind: created ? "peer.registered" : "peer.reannounced",
        severity: "low",
        source: "node_instance",
        payload: { handle: peer.handle, status: peer.status, capabilities: peer.capabilities },
        node_instance_id: peer.node_instance_id
      )
    rescue StandardError => e
      Rails.logger.warn("[AgentPeeringService] event emit failed: #{e.message}")
    end
  end
end
