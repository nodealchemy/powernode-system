# frozen_string_literal: true

module System
  module ClusterMember
    # Cluster_member spawn variant — sets up PostgreSQL streaming
    # replication so the child's pg-replica module can hot-standby
    # from this platform's primary.
    #
    # Idempotent: re-running for an already-prepared peer is a no-op
    # (existing slot + credential are kept).
    #
    # Flow:
    #   1. Create a physical replication slot on the primary
    #      (SELECT pg_create_physical_replication_slot(...))
    #   2. Generate replication-user credentials (username + 32-byte
    #      base64 password) — stored in Vault under
    #      `cluster_member_pg_replica` keyed by FederationPeer.id
    #   3. Stamp peer.metadata.cluster_pg = { slot_name, primary_host,
    #      primary_port, credential_id, state: "ready" }
    #
    # The credential plaintext is delivered to the child exactly once
    # via the AcceptController response (P6.5 will wire delivery on
    # the wire). Within this service, the plaintext lives only in
    # memory for the duration of the call and inside Vault thereafter.
    #
    # Plan reference: Decentralized Federation §H + P6.4.
    class PgReplicaSetupService
      class SetupError < StandardError; end

      Result = Struct.new(:ok?, :slot_name, :credential_id, :error,
                          :already_prepared, keyword_init: true)

      # Configuration knobs surfaced via env so test/non-production
      # deployments can opt out of the real SQL execution. Real
      # production deployments leave these alone (defaults match
      # the platform's own PG primary).
      DEFAULT_PRIMARY_PORT = 5432

      def initialize(peer:, sql_executor: nil, vault: nil, logger: nil)
        @peer = peer
        @sql_executor = sql_executor || method(:execute_sql)
        @vault = vault || ::Security::VaultCredentialProvider.new(account_id: peer.account_id)
        @logger = logger || ::Rails.logger
      end

      def run!
        return reject!("peer.spawn_mode must be cluster_member") unless @peer.spawn_mode == "cluster_member"
        return reject!("peer.spawn_role must be parent") unless @peer.spawn_role == "parent"

        if already_prepared?
          @logger.info("[ClusterMember::PgReplicaSetupService] peer #{@peer.id} already prepared; skipping")
          existing = @peer.metadata["cluster_pg"] || {}
          return Result.new(
            ok?: true,
            slot_name: existing["slot_name"],
            credential_id: existing["credential_id"],
            already_prepared: true
          )
        end

        slot_name = build_slot_name
        credentials = build_credentials
        primary_host = resolve_primary_host
        primary_port = resolve_primary_port

        # Create the physical slot first. If the SQL fails we abort
        # before generating Vault state — keeps cleanup simple.
        create_replication_slot!(slot_name)

        # Then create the replication user + grant. Same SQL-executor
        # surface so the test seam is uniform.
        create_replication_user!(credentials)

        # Vault stash. Keyed by peer.id so a peer-level revoke can
        # tear down credentials cleanly later.
        @vault.store_credential(
          credential_type: :cluster_member_pg_replica,
          credential_id: @peer.id,
          data: credentials.merge(
            slot_name: slot_name,
            primary_host: primary_host,
            primary_port: primary_port
          ),
          record: @peer
        )

        # Peer metadata is the operator-visible record of "what
        # cluster_pg state has been provisioned." Credentials are NOT
        # echoed here — they live in Vault only.
        @peer.update!(
          metadata: @peer.metadata.merge(
            "cluster_pg" => {
              "slot_name" => slot_name,
              "primary_host" => primary_host,
              "primary_port" => primary_port,
              "credential_id" => @peer.id,
              "username" => credentials[:username],
              "state" => "ready",
              "prepared_at" => Time.current.iso8601
            }
          )
        )

        emit_event!(slot_name)

        Result.new(
          ok?: true,
          slot_name: slot_name,
          credential_id: @peer.id,
          already_prepared: false
        )
      rescue SetupError => e
        Result.new(ok?: false, error: e.message)
      rescue StandardError => e
        @logger.error("[ClusterMember::PgReplicaSetupService] #{e.class}: #{e.message}")
        Result.new(ok?: false, error: e.message)
      end

      private

      def already_prepared?
        cluster_pg = @peer.metadata["cluster_pg"]
        cluster_pg.is_a?(Hash) && cluster_pg["state"] == "ready" && cluster_pg["slot_name"].present?
      end

      # PostgreSQL slot names are constrained to <= 63 chars, lower-case,
      # alphanumeric + underscore. Peer IDs are UUIDv7s (hex with dashes);
      # we strip dashes and take the first 32 chars to stay well under
      # the limit while preserving uniqueness.
      def build_slot_name
        compact = @peer.id.to_s.delete("-").first(32)
        "powernode_repl_#{compact}"
      end

      def build_credentials
        {
          username: "powernode_repl_#{@peer.id.to_s.delete('-').first(16)}",
          password: ::SecureRandom.base64(32)
        }
      end

      def resolve_primary_host
        # In v1 the cluster_member assumes the child reaches the parent's
        # primary over an established SDWAN VIP. The operator wires the
        # actual VIP into the peer metadata at spawn time; we honor it
        # if present and fall back to an env hint otherwise. The
        # default "primary.platform.local" is a placeholder the
        # operator MUST override before the child can stream.
        @peer.metadata.dig("cluster_pg", "primary_host") ||
          ENV["POWERNODE_PG_PRIMARY_HOST"] ||
          "primary.platform.local"
      end

      def resolve_primary_port
        port = @peer.metadata.dig("cluster_pg", "primary_port") || ENV["POWERNODE_PG_PRIMARY_PORT"]
        (port.presence || DEFAULT_PRIMARY_PORT).to_i
      end

      def create_replication_slot!(slot_name)
        sql = "SELECT pg_create_physical_replication_slot($1, true)"
        @sql_executor.call(sql, [ slot_name ])
      rescue ActiveRecord::StatementInvalid => e
        # Slot already exists is a benign race — log and proceed.
        if e.message.include?("already exists")
          @logger.info("[ClusterMember::PgReplicaSetupService] slot #{slot_name} already exists; reusing")
          return
        end
        raise SetupError, "replication slot create failed: #{e.message}"
      end

      def create_replication_user!(credentials)
        # CREATE ROLE with REPLICATION + LOGIN. The username is
        # parameterized but PG doesn't allow bind params in DDL, so
        # we strictly validate against an alphanumeric-underscore
        # regex first. The password goes through proper escaping.
        username = credentials[:username]
        unless username.match?(/\A[a-z][a-z0-9_]{2,63}\z/)
          raise SetupError, "invalid replication username #{username.inspect}"
        end

        # Quote the password by escaping single quotes. PG's CREATE
        # ROLE ... PASSWORD '<pw>' uses single quotes; double them up.
        password_quoted = credentials[:password].gsub("'", "''")
        sql = <<~SQL.squish
          CREATE ROLE #{username}
          WITH LOGIN REPLICATION PASSWORD '#{password_quoted}'
          VALID UNTIL 'infinity'
        SQL
        @sql_executor.call(sql)
      rescue ActiveRecord::StatementInvalid => e
        if e.message.include?("already exists")
          @logger.info("[ClusterMember::PgReplicaSetupService] role exists; reusing")
          return
        end
        raise SetupError, "replication role create failed: #{e.message}"
      end

      # Default sql executor — runs against the app's primary PG
      # connection. Tests inject a recorder/stub via the constructor.
      def execute_sql(sql, binds = [])
        if binds.any?
          ::ActiveRecord::Base.connection.exec_query(sql, "PgReplicaSetup", binds.map { |v| [ nil, v ] })
        else
          ::ActiveRecord::Base.connection.execute(sql)
        end
      end

      def reject!(reason)
        @logger.warn("[ClusterMember::PgReplicaSetupService] rejected: #{reason}")
        Result.new(ok?: false, error: reason)
      end

      def emit_event!(slot_name)
        return unless defined?(::System::Fleet::EventBroadcaster)
        ::System::Fleet::EventBroadcaster.emit!(
          account: @peer.account,
          kind: "platform.cluster_member.pg_replica_ready",
          severity: "low",
          source: "cluster_member_pg_replica_setup",
          payload: {
            peer_id: @peer.id,
            slot_name: slot_name,
            primary_host: resolve_primary_host
          }
        )
      rescue StandardError => e
        @logger.warn("[ClusterMember::PgReplicaSetupService] event emit failed: #{e.message}")
      end
    end
  end
end
