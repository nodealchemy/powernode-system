# frozen_string_literal: true

module System
  # Orchestrates the parent-side of a platform spawn. Three spawn
  # modes per Locked Decision #4:
  #
  #   - managed_child:    parent retains operator-scope FederationGrant
  #                        on child; intervention policies cascade.
  #   - autonomous_peer:  child is a peer; no auto-grants; equal post-handshake.
  #   - cluster_member:   child shares PG primary via streaming replication;
  #                        Redis pointed at parent's VIP.
  #
  # Parent-side flow:
  #   1. Create FederationPeer row in `proposed` status with
  #      spawn_role=parent + spawn_mode set
  #   2. Generate single-use acceptance_token (TTL 7 days)
  #   3. Build virtio-fw-cfg payload for the child's first-run handler
  #   4. Hand the payload to a NodeInstance provisioning provider
  #      (kept behind an injectable boundary for tests + future
  #      provider-specific implementations: LocalQemuProvider, etc.)
  #   5. Return the peer + payload so the caller can show the
  #      spawn token to the operator (one-time-shown)
  #
  # Child-side flow (NOT this service's concern):
  #   - The provisioned child's first-run handler reads the
  #     virtio-fw-cfg payload, POSTs the acceptance_token to the
  #     parent's federation_api/accept, completes the mTLS handshake.
  #
  # Plan reference: Decentralized Federation §H + P6.
  class SpawnPlatformService
    class SpawnError < StandardError; end

    Result = Struct.new(:ok?, :error, :federation_peer, :spawn_payload,
                        :acceptance_token, keyword_init: true)

    SPAWN_MODES = %w[managed_child autonomous_peer cluster_member].freeze

    # Default acceptance-token TTL — short window because spawn-and-accept
    # is typically minutes-to-hours, not days. Operator can override.
    DEFAULT_TOKEN_TTL = 7.days.to_i

    class << self
      def spawn!(account:, spawn_mode:, spawn_target:, parent_url:,
                 initiated_by_user: nil, token_ttl_seconds: DEFAULT_TOKEN_TTL,
                 provisioner: nil)
        new(account: account, provisioner: provisioner).spawn!(
          spawn_mode: spawn_mode,
          spawn_target: spawn_target,
          parent_url: parent_url,
          initiated_by_user: initiated_by_user,
          token_ttl_seconds: token_ttl_seconds
        )
      end
    end

    def initialize(account:, provisioner: nil)
      @account = account
      @provisioner = provisioner
    end

    # @param spawn_target [Hash] provider-specific fields (template_id,
    #   region, instance_size, etc.) passed through to the provisioner
    # @param parent_url [String] reachable URL for the child to POST
    #   back to (typically the parent's public hub URL)
    def spawn!(spawn_mode:, spawn_target:, parent_url:,
               initiated_by_user: nil, token_ttl_seconds: DEFAULT_TOKEN_TTL)
      validate_mode!(spawn_mode)
      validate_target!(spawn_target)

      peer = create_parent_peer_record!(spawn_mode, parent_url)
      acceptance_token = peer.generate_acceptance_token!(ttl_seconds: token_ttl_seconds)

      # For cluster_member spawns, materialize the PG replication slot +
      # credential before the child boots. The worker job is async so
      # provisioning + slot prep run in parallel; by the time the child
      # accepts (a few minutes later), the slot is already in `ready`
      # state and the AcceptController can include cluster_pg metadata
      # in its response. Plan: P6.4.
      enqueue_cluster_pg_setup!(peer) if spawn_mode.to_s == "cluster_member"

      payload = build_spawn_payload(peer, acceptance_token, parent_url, spawn_target, initiated_by_user)

      # Hand off to provisioner. Returns whatever the provisioner
      # decides to expose; we just pass it through. For v1, the
      # provisioner is injected (Provider-specific impls land in P6+).
      provision_response = provision_child!(payload, spawn_target)

      peer.update!(
        metadata: peer.metadata.merge(
          "provisioner_response" => provision_response.is_a?(Hash) ? provision_response : { "raw" => provision_response.to_s }
        )
      )

      Result.new(
        ok?: true,
        federation_peer: peer,
        spawn_payload: payload,
        acceptance_token: acceptance_token
      )
    rescue SpawnError => e
      Result.new(ok?: false, error: e.message)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok?: false, error: "Invalid peer config: #{e.message}")
    rescue StandardError => e
      Rails.logger.error("[System::SpawnPlatformService] #{e.class}: #{e.message}")
      Result.new(ok?: false, error: e.message)
    end

    private

    def validate_mode!(mode)
      return if SPAWN_MODES.include?(mode.to_s)
      raise SpawnError, "Unknown spawn_mode #{mode.inspect}; supported: #{SPAWN_MODES.inspect}"
    end

    def validate_target!(target)
      return if target.is_a?(Hash) && target[:template_id].present?
      raise SpawnError, "spawn_target must be a hash with :template_id"
    end

    def create_parent_peer_record!(spawn_mode, parent_url)
      ::System::FederationPeer.create!(
        account: @account,
        peer_kind: "platform",
        spawn_role: "parent",
        spawn_mode: spawn_mode.to_s,
        status: "proposed",
        remote_instance_url: parent_url,
        remote_instance_id: ::SecureRandom.uuid,
        endpoints: [],
        extension_slugs: [],
        capabilities: {},
        sync_cursor: {},
        metadata: { "spawn_initiated_at" => Time.current.iso8601 }
      )
    end

    # virtio-fw-cfg payload the child's first-run handler reads.
    # Fields:
    #   - parent_url: reachable URL for the child to POST to
    #   - acceptance_token: single-use credential (matches digest on peer row)
    #   - spawn_mode: tells the child how to configure itself
    #   - parent_peer_id: the peer row id on parent side (for correlation)
    #   - cluster_pg: only for cluster_member mode; future addition
    def build_spawn_payload(peer, token, parent_url, target, initiated_by_user)
      base = {
        "parent_url" => parent_url,
        "acceptance_token" => token,
        "spawn_mode" => peer.spawn_mode,
        "parent_peer_id" => peer.id,
        "child_template_id" => target[:template_id],
        "contract_version" => "v1"
      }
      base["initiated_by_user_id"] = initiated_by_user.id if initiated_by_user
      base["region"] = target[:region] if target[:region]
      base
    end

    # Calls the injected provisioner with the spawn payload. Returns
    # whatever the provisioner produces (typically an opaque dict
    # with instance_id, status_url, etc.). When no provisioner is
    # injected, returns a recorded-only result — the operator must
    # manually attach the NodeInstance later. This keeps the service
    # testable without provider integration AND supports the
    # out-of-band spawn flow.
    def provision_child!(payload, spawn_target)
      return { "provisioner" => "none", "manual_attach_required" => true } unless @provisioner
      @provisioner.provision!(payload: payload, spawn_target: spawn_target)
    end

    # Enqueue the worker job that materializes the PG replication slot +
    # credential for a cluster_member spawn. Falls back to a synchronous
    # in-band setup when the worker queue is unreachable (test
    # environment or worker-not-running scenarios) so the cluster_pg
    # state stays consistent without requiring the worker pipeline to
    # be live during specs.
    def enqueue_cluster_pg_setup!(peer)
      worker_klass = "ClusterMemberPgReplicaSetupJob"
      if defined?(::Sidekiq::Client) && Object.const_defined?(worker_klass)
        ::Sidekiq::Client.push(
          "class" => worker_klass,
          "queue" => "system",
          "args" => [ peer.id ]
        )
      else
        # Local fallback — invoke the service in-process. Useful for
        # tests and for the no-worker-yet bootstrap window.
        ::System::ClusterMember::PgReplicaSetupService.new(peer: peer).run!
      end
    rescue StandardError => e
      ::Rails.logger.warn(
        "[System::SpawnPlatformService] cluster_pg enqueue failed for peer #{peer.id}: #{e.message}"
      )
    end
  end
end
