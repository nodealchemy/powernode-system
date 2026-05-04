# frozen_string_literal: true

require "openssl"
require "json"

module System
  # Phase B — Docker runtime auto-registration.
  #
  # When a `docker-engine` NodeModule is assigned to a NodeInstance, this
  # service materializes the platform-side bookkeeping:
  #
  #   1. Verifies the NodeInstance has at least one SDWAN peer with an
  #      assigned overlay /128 — daemon API binds there exclusively per
  #      Phase B Decision 1 (no public Docker socket exposure).
  #   2. Issues the platform's *client* mTLS pair via InternalCaService
  #      so the platform can call the daemon. The CA chain matches the
  #      one the agent will trust when validating the daemon's *server*
  #      cert (also signed by InternalCaService, in a separate flow
  #      driven by the agent CSR over heartbeat).
  #   3. Creates a `Devops::DockerHost` row with `provisioning_state:
  #      'managed'`, FK back to the NodeInstance, and api_endpoint
  #      `tcp://[<overlay-/128>]:2376`. The host starts in `pending`
  #      status — promoted to `connected` by `mark_daemon_ready!`
  #      once the agent reports the daemon is listening.
  #   4. Persists the client keypair to Vault via
  #      `Security::VaultCredentialProvider` (credential type
  #      `:docker_daemon_tls`); the same payload is also stored in the
  #      DockerHost.encrypted_tls_credentials column so the existing
  #      `Devops::Docker::ApiClient` (which reads from the DB) keeps
  #      working without a Vault round-trip on the hot path.
  #
  # Idempotent: calling `provision!` twice for the same NodeInstance
  # returns the existing host — the FK has a partial unique index, so
  # concurrent calls race-safe to a single row.
  #
  # The reverse — `decommission!` — soft-deletes the managed host and
  # purges its TLS material from Vault. The associated NodeInstance is
  # untouched; module unassignment + this call are independent
  # operations the operator (or autonomy executor) sequences.
  class DockerDaemonProvisionerService
    class ProvisionError < StandardError; end
    class MissingSdwanPeerError < ProvisionError; end
    class DaemonAlreadyProvisionedError < ProvisionError; end

    # 90 days, matching the InternalCaService default. Rotation is the
    # operator's responsibility for now — Phase 2 may surface a
    # `system_rotate_docker_tls` MCP action that re-issues + pushes the
    # new cert to the agent.
    CLIENT_CERT_TTL_SECONDS = 90 * 24 * 3600
    DAEMON_API_PORT = 2376

    def self.provision!(node_instance:, account: nil)
      new(node_instance: node_instance, account: account).provision!
    end

    def self.decommission!(docker_host:)
      new(docker_host: docker_host).decommission!
    end

    def initialize(node_instance: nil, docker_host: nil, account: nil)
      @node_instance = node_instance
      @docker_host = docker_host
      @account = account || node_instance&.account || docker_host&.account ||
                 raise(ArgumentError, "either node_instance or docker_host must be provided")
    end

    # ──────────────────────────────────────────────────────────────────
    # Public entry points
    # ──────────────────────────────────────────────────────────────────

    def provision!
      raise ArgumentError, "node_instance required for provision!" unless @node_instance

      existing = Devops::DockerHost.managed.find_by(node_instance_id: @node_instance.id)
      return existing if existing # idempotent — caller already provisioned

      overlay_address = resolve_overlay_address!
      tls_material = issue_client_tls_pair!
      api_endpoint = "tcp://[#{overlay_address}]:#{DAEMON_API_PORT}"

      ActiveRecord::Base.transaction do
        host = Devops::DockerHost.create!(
          account: @account,
          name: managed_host_name,
          api_endpoint: api_endpoint,
          environment: "production",
          status: "pending",
          provisioning_state: "managed",
          node_instance_id: @node_instance.id,
          tls_verify: true,
          encrypted_tls_credentials: tls_material.to_json,
          metadata: {
            provisioned_at: Time.current.utc.iso8601,
            provisioner: "System::DockerDaemonProvisionerService",
            overlay_address: overlay_address,
            cert_serial: tls_material[:client_cert_serial],
            cert_not_after: tls_material[:client_cert_not_after]
          }
        )

        store_in_vault!(host: host, tls_material: tls_material)

        Rails.logger.info(
          "[DockerDaemonProvisionerService] provisioned managed host " \
          "host_id=#{host.id} node_instance_id=#{@node_instance.id} " \
          "endpoint=#{api_endpoint}"
        )
        host
      end
    end

    # Promoted by the heartbeat receiver once the agent reports the
    # daemon is listening + serving its CA-signed server cert. Until
    # this is called, the host stays in `pending` and platform → daemon
    # API calls would fail (which is the expected gate).
    def mark_daemon_ready!(host: nil, docker_version: nil)
      h = host || @docker_host
      raise ArgumentError, "host required for mark_daemon_ready!" unless h

      h.update!(
        status: "connected",
        docker_version: docker_version || h.docker_version,
        last_synced_at: Time.current,
        consecutive_failures: 0,
        metadata: (h.metadata || {}).merge(
          "daemon_ready_at" => Time.current.utc.iso8601
        )
      )
      h
    end

    def decommission!
      raise ArgumentError, "docker_host required for decommission!" unless @docker_host
      raise ProvisionError, "cannot decommission an external host" unless @docker_host.managed?

      ActiveRecord::Base.transaction do
        purge_from_vault!(host: @docker_host)
        host_id = @docker_host.id
        @docker_host.destroy!
        Rails.logger.info(
          "[DockerDaemonProvisionerService] decommissioned managed host host_id=#{host_id}"
        )
      end
      true
    end

    # ──────────────────────────────────────────────────────────────────
    # Internals
    # ──────────────────────────────────────────────────────────────────

    private

    def resolve_overlay_address!
      # Pick the first peer that has an assigned address. NodeInstances
      # generally have a single overlay attachment; if multi-network
      # ever ships, we'd add a parameter to pick the right one.
      peer = ::Sdwan::Peer.where(node_instance_id: @node_instance.id)
                          .where.not(assigned_address: nil)
                          .order(:created_at)
                          .first
      unless peer
        raise MissingSdwanPeerError,
              "NodeInstance #{@node_instance.id} has no SDWAN peer with an " \
              "assigned overlay address — assign an Sdwan::Peer before " \
              "provisioning the docker-engine module"
      end
      # `assigned_address` is stored in CIDR form (`<v6>/128`); the URL
      # form bracketing doesn't tolerate the prefix length, so strip it.
      peer.assigned_address.to_s.split("/").first
    end

    def issue_client_tls_pair!
      key = OpenSSL::PKey.generate_key("ED25519")
      csr = OpenSSL::X509::Request.new
      csr.version = 0
      csr.subject = OpenSSL::X509::Name.parse(client_cert_subject)
      csr.public_key = key
      csr.sign(key, nil) # Ed25519 — digest must be nil

      result = ::System::InternalCaService.issue_certificate(
        csr_pem: csr.to_pem,
        ttl_seconds: CLIENT_CERT_TTL_SECONDS,
        common_name: client_cert_common_name
      )

      {
        ca_chain_pem: result[:ca_chain_pem],
        client_cert_pem: result[:cert_pem],
        # Ed25519 keys (modern OpenSSL API) require explicit
        # private_to_pem — `to_pem` is only defined on legacy RSA/EC
        # keys and disambiguating the private/public half is a runtime
        # error otherwise.
        client_key_pem: key.private_to_pem,
        client_cert_serial: result[:serial],
        client_cert_not_after: result[:not_after]&.utc&.iso8601
      }
    end

    def store_in_vault!(host:, tls_material:)
      provider = ::Security::VaultCredentialProvider.new(account_id: @account.id)
      provider.store_credential(
        credential_type: :docker_daemon_tls,
        credential_id: host.id,
        data: tls_material.transform_keys(&:to_s)
      )
    rescue StandardError => e
      # Non-fatal — the DB-side encrypted_tls_credentials column already
      # has the same payload, so the host stays usable. Log loudly so
      # operators can investigate.
      Rails.logger.warn(
        "[DockerDaemonProvisionerService] vault store failed for " \
        "host_id=#{host.id}: #{e.class}: #{e.message}"
      )
    end

    def purge_from_vault!(host:)
      provider = ::Security::VaultCredentialProvider.new(account_id: @account.id)
      return unless provider.respond_to?(:delete_credential)

      provider.delete_credential(
        credential_type: :docker_daemon_tls,
        credential_id: host.id
      )
    rescue StandardError => e
      Rails.logger.warn(
        "[DockerDaemonProvisionerService] vault purge failed for " \
        "host_id=#{host.id}: #{e.class}: #{e.message}"
      )
    end

    def managed_host_name
      base = @node_instance.name.presence || "instance-#{@node_instance.id[0, 8]}"
      "#{base}-docker"
    end

    def client_cert_subject
      "/CN=#{client_cert_common_name}"
    end

    def client_cert_common_name
      "platform-docker-client-#{@account.id}"
    end
  end
end
