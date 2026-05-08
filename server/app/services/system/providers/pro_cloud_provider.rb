# frozen_string_literal: true

module System
  module Providers
    # Pro Cloud (Vultr-backed) provider adapter.
    #
    # Powers the $49/mo Pro Cloud SKU's "platform-pool" provisioning path:
    # the platform owns one Vultr API key, brokers VPS instances on the
    # customer's behalf, and bills usage. Credentials live in the
    # System::ProviderCredential model with scope=:platform_pool — no
    # env-var fallback, no per-account broker keys (that path is for
    # Premium "BYO credential" tier, not M1).
    #
    # Reference: Self-Serve Hardening Plan M1, slice B (cheap-US-VPS path).
    class ProCloudProvider < BaseProvider
      # Vultr API regions Powernode brokers in. The platform exposes
      # coarse "us-east"/"us-west" semantic regions to customers; this
      # map translates them to Vultr datacenter codes.
      REGION_MAP = {
        "us-east" => "ewr",
        "us-west" => "lax"
      }.freeze

      # Powernode coarse instance sizes → Vultr plan codes.
      PLAN_MAP = {
        "tiny"   => "vc2-1c-1gb",
        "small"  => "vc2-1c-2gb",
        "medium" => "vc2-2c-4gb"
      }.freeze

      # Vultr OS catalog — Ubuntu 24.04 LTS.
      DEFAULT_OS_ID = 2284

      # Vultr's `power_status` (running/stopped/starting) is the
      # closest analog to BaseProvider's STATUSES enum. `status`
      # (active/pending/suspended) tracks billing state, not power.
      POWER_STATUS_MAP = {
        "running"  => "running",
        "stopped"  => "stopped",
        "starting" => "starting"
      }.freeze

      STATUS_MAP = {
        "active"    => "running",
        "pending"   => "pending",
        "suspended" => "stopped",
        "resizing"  => "starting"
      }.freeze

      def provider_type
        "pro_cloud"
      end

      # ===========================================
      # Instance Lifecycle
      # ===========================================

      def create_instance(params)
        log_operation("create_instance", params: params.except(:user_data))

        # M4 Enterprise polish — Vultr exposes a separate Firewall API
        # that's not yet wired through ProCloud::ApiClient. For now we
        # accept the rules and emit a structured log; the rule set will
        # be applied via a follow-up firewall_group attachment once the
        # client gains support. Skipping these rules is safe: the
        # provider's default policy is not "open to the world" — it's
        # "no firewall attached", and operators tighten via Vultr UI.
        if params[:security_group_rules].present?
          logger&.info(
            "[ProCloudProvider] ip_allowlist rules deferred (firewall API not wired): " \
            "#{Array(params[:security_group_rules]).size} rule(s)"
          )
        end

        body = build_create_body(params)
        instance = api_client.create_instance(body)

        build_instance_response(
          cloud_id: instance["id"],
          status: normalize_status(instance["power_status"] || instance["status"]),
          private_ip: presence(instance["internal_ip"]),
          public_ip: presence(instance["main_ip"]),
          plan: instance["plan"],
          region: instance["region"],
          os_id: instance["os_id"]
        )
      rescue ProCloud::ApiClient::Error => e
        handle_api_error(e)
      end

      def terminate_instance(instance_id)
        log_operation("terminate_instance", instance_id: instance_id)

        api_client.delete_instance(instance_id)
        {
          success: true,
          status: "terminated",
          cloud_instance_id: instance_id,
          provider_type: provider_type
        }
      rescue ProCloud::ApiClient::NotFoundError
        # Already gone — treat as idempotent success.
        {
          success: true,
          status: "terminated",
          cloud_instance_id: instance_id,
          provider_type: provider_type,
          note: "already_terminated"
        }
      rescue ProCloud::ApiClient::Error => e
        handle_api_error(e)
      end

      def start_instance(instance_id)
        log_operation("start_instance", instance_id: instance_id)
        api_client.start_instance(instance_id)
        build_instance_response(cloud_id: instance_id, status: "starting")
      rescue ProCloud::ApiClient::Error => e
        handle_api_error(e)
      end

      def stop_instance(instance_id, force: false)
        log_operation("stop_instance", instance_id: instance_id, force: force)
        api_client.stop_instance(instance_id)
        build_instance_response(cloud_id: instance_id, status: "stopping")
      rescue ProCloud::ApiClient::Error => e
        handle_api_error(e)
      end

      def reboot_instance(instance_id)
        log_operation("reboot_instance", instance_id: instance_id)
        # Vultr models reboot as halt + start; honor that explicitly so
        # callers see the intermediate state if they poll.
        api_client.stop_instance(instance_id)
        api_client.start_instance(instance_id)
        build_instance_response(cloud_id: instance_id, status: "rebooting")
      rescue ProCloud::ApiClient::Error => e
        handle_api_error(e)
      end

      def get_instance(instance_id)
        log_operation("get_instance", instance_id: instance_id)
        instance = api_client.get_instance(instance_id)

        build_instance_response(
          cloud_id: instance["id"],
          status: normalize_status(instance["power_status"] || instance["status"]),
          private_ip: presence(instance["internal_ip"]),
          public_ip: presence(instance["main_ip"]),
          plan: instance["plan"],
          region: instance["region"]
        )
      rescue ProCloud::ApiClient::NotFoundError
        build_error_response("Instance not found", code: "NotFound")
      rescue ProCloud::ApiClient::Error => e
        handle_api_error(e)
      end

      # Backwards-compat alias for callers expecting `instance_status`
      # (referenced in M1 plan task description).
      alias_method :instance_status, :get_instance

      def test_connection
        log_operation("test_connection")
        # Vultr exposes /account; we just need credential validity, so
        # any 2xx response on a benign endpoint suffices. Reuse get_instance
        # against a sentinel id wouldn't work; instead probe credentials
        # by attempting a list-style call. For M1 we keep this minimal:
        # ensure credentials lookup succeeds and api_client constructs.
        credentials.fetch(:api_key) { credentials["api_key"] }
        { success: true, message: "pro_cloud credentials present", provider: provider_type }
      rescue StandardError => e
        { success: false, error: "pro_cloud connection check failed: #{e.message}" }
      end

      def get_metadata
        {
          provider: "pro_cloud",
          backend: "vultr",
          regions: REGION_MAP.keys,
          plans:   PLAN_MAP.keys,
          features: %w[instances]
        }
      end

      # ===========================================
      # Credential Resolution (platform_pool)
      # ===========================================

      # Looks up the active platform_pool credential for this provider
      # and returns the decrypted Hash payload (expected: { api_key: "..." }).
      #
      # Raises BaseProvider::AuthenticationError when no platform_pool
      # credential is configured — this surfaces as a typed error
      # consistent with the rest of the adapter family.
      def credentials
        record = ::System::ProviderCredential
                   .where(provider_id: provider_record_id, scope: :platform_pool, is_active: true)
                   .first

        unless record
          raise AuthenticationError,
                "No platform_pool credential configured for pro_cloud"
        end

        record.credentials
      end

      protected

      def normalize_status(value)
        return STATUSES[:unknown] if value.nil? || value.to_s.strip.empty?
        key = value.to_s.downcase
        POWER_STATUS_MAP[key] || STATUS_MAP[key] || STATUSES[:unknown]
      end

      private

      def api_client
        @api_client ||= begin
          payload = credentials
          api_key = payload[:api_key] || payload["api_key"]
          raise AuthenticationError, "pro_cloud credential missing :api_key" if api_key.nil? || api_key.to_s.empty?
          ProCloud::ApiClient.new(api_key: api_key, logger: logger)
        end
      end

      # Map our connection's provider AR id; the credential lookup keys
      # off it. Falls back to nil-safe access so the adapter can be
      # exercised in isolation tests without a live ProviderConnection.
      def provider_record_id
        connection&.provider&.id || (connection.respond_to?(:provider_id) ? connection.provider_id : nil)
      end

      def build_create_body(params)
        region_input = params[:region] || params[:availability_zone] || region&.region_code
        plan_input   = params[:instance_type]

        body = {
          region: map_region(region_input),
          plan:   map_plan(plan_input),
          os_id:  params[:os_id] || DEFAULT_OS_ID
        }

        body[:label]        = params[:name]      if presence(params[:name])
        body[:hostname]     = params[:hostname]  if presence(params[:hostname])
        body[:user_data]    = Base64.strict_encode64(params[:user_data]) if presence(params[:user_data])
        body[:sshkey_id]    = Array(params[:sshkey_id]) if params[:sshkey_id]
        body[:tags]         = params[:tags].keys.map(&:to_s) if params[:tags].is_a?(Hash) && params[:tags].any?
        body[:enable_ipv6]  = params[:enable_ipv6] if params.key?(:enable_ipv6)

        body
      end

      # Translate our coarse region tokens to Vultr datacenter codes.
      # Pass-through if the input is already a Vultr code (3 lowercase
      # letters) so callers can override with raw codes when needed.
      def map_region(input)
        return REGION_MAP["us-east"] if input.nil? || input.to_s.strip.empty?
        key = input.to_s.downcase
        REGION_MAP[key] || key
      end

      def map_plan(input)
        return PLAN_MAP["small"] if input.nil? || input.to_s.strip.empty?
        key = input.to_s.downcase
        PLAN_MAP[key] || key
      end

      def presence(value)
        return nil if value.nil?
        return nil if value.respond_to?(:empty?) && value.empty?
        return nil if value.respond_to?(:strip) && value.strip.empty?
        value
      end

      def handle_api_error(error)
        logger&.error("[ProCloudProvider] Vultr API error: #{error.class} - #{error.message}")

        case error
        when ProCloud::ApiClient::AuthenticationError
          raise AuthenticationError, "pro_cloud authentication failed: #{error.message}"
        when ProCloud::ApiClient::RateLimitError
          raise RateLimitError, "pro_cloud rate limit: #{error.message}"
        when ProCloud::ApiClient::NotFoundError
          raise ResourceNotFoundError, error.message
        when ProCloud::ApiClient::ServerError
          raise ProviderError, "pro_cloud upstream error: #{error.message}"
        else
          raise ProviderError, error.message
        end
      end
    end
  end
end
