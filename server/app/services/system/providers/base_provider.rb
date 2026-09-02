# frozen_string_literal: true

module System
  module Providers
    # Abstract base class for cloud provider adapters
    # All provider implementations must inherit from this class and implement the abstract methods
    #
    # This provides a unified interface for cloud operations across AWS, GCP, Azure, OpenStack, etc.
    # Each provider normalizes responses to a common format for consistent handling.
    class BaseProvider
      class ProviderError < StandardError; end
      class NotImplementedError < ProviderError; end
      class AuthenticationError < ProviderError; end
      class RateLimitError < ProviderError; end
      class ResourceNotFoundError < ProviderError; end
      class QuotaExceededError < ProviderError; end

      # Common instance statuses (normalized across providers)
      STATUSES = {
        pending: "pending",
        starting: "starting",
        running: "running",
        stopping: "stopping",
        stopped: "stopped",
        rebooting: "rebooting",
        terminating: "terminating",
        terminated: "terminated",
        failed: "failed",
        unknown: "unknown"
      }.freeze

      # Provisioning resilience — fail-fast HTTP timeout convention.
      #
      # Every auth/token + SDK/HTTP connection on the provisioning path MUST
      # carry an explicit connect + read timeout. Without one, an unreachable
      # auth/control-plane endpoint blocks for the Net::HTTP/SDK default
      # (~60-600s) per call and stalls fleet-wide provisioning. These constants
      # centralize the 10s-connect / 60s-read values that Proxmox/ProCloud and
      # the Azure ARM connection already follow; adapters reference them (Faraday
      # via #apply_http_timeouts, aws-sdk via http_open_timeout/http_read_timeout,
      # fog via connection_options, google via config.timeout) instead of
      # hand-rolling literals.
      DEFAULT_CONNECT_TIMEOUT = 10
      DEFAULT_READ_TIMEOUT    = 60

      attr_reader :connection, :region, :logger, :last_authentication_error

      # === Optional SDK availability (APO-7) ===============================
      #
      # Some adapters are written against a cloud SDK gem that is NOT in the
      # core bundle (aws-sdk-ec2, google-cloud-compute, fog-openstack). The
      # adapter code is complete, but every call would raise a bare NameError
      # on a build without the gem — which reaches an MCP caller as an
      # internal error rather than as a refusal it can act on.
      #
      # An adapter that needs a gem declares the gem name and the constant
      # that proves it is loaded; System::Providers::Registry then hides the
      # adapter and refuses in front of the caller. Adapters that run on the
      # core bundle alone (proxmox, mock, local_qemu, pro_cloud, and azure —
      # a hand-rolled faraday REST client, see AzureProvider) inherit the
      # defaults and are always available.

      # @return [String, nil] Gem that must be bundled for this adapter to
      #   work, or nil when the adapter needs no optional gem.
      def self.required_sdk_gem
        nil
      end

      # @return [String, nil] Fully qualified constant whose presence proves
      #   the SDK is loaded, or nil when no gem is required.
      def self.sdk_constant
        nil
      end

      # @return [Boolean] True when this adapter can actually run here.
      def self.sdk_available?
        const_path = sdk_constant
        return true if const_path.nil?

        Object.const_defined?(const_path)
      end

      # Initialize provider with connection credentials
      #
      # @param connection [System::ProviderConnection] The provider connection with credentials
      # @param region [System::ProviderRegion, nil] Optional region override
      def initialize(connection, region: nil)
        @connection = connection
        # provider_regions lives on Provider, not ProviderConnection — go
        # through the belongs_to. Nil-safe so providers without regions
        # (proxmox, local_qemu) yield @region = nil.
        @region = region || connection.provider&.provider_regions&.first
        @logger = Rails.logger
      end

      # Build a transient adapter instance carrying the supplied credential
      # hash, without requiring a persisted ProviderConnection. Used by
      # System::CredentialValidationService (M2 BYOC) to test credentials
      # before persistence to System::ProviderCredential.
      #
      # The transient instance has @connection / @region nil — adapter
      # subclasses that need additional ivar setup can override this method.
      #
      # @param credentials [Hash] Plaintext credential payload (string-keyed)
      # @return [BaseProvider] Transient adapter instance
      def self.with_credentials(credentials)
        instance = allocate
        normalized = (credentials || {}).each_with_object({}) { |(k, v), h| h[k.to_s] = v }
        instance.instance_variable_set(:@transient_credentials, normalized)
        instance.instance_variable_set(:@logger, Rails.logger)
        instance.instance_variable_set(:@connection, nil)
        instance.instance_variable_set(:@region, nil)
        instance.instance_variable_set(:@last_authentication_error, nil)
        instance
      end

      # Capability discovery (audit F4-06). Services check
      # `adapter.supports?(:volumes)` etc. BEFORE creating DB rows or
      # dispatching provider calls, so an unsupported operation fails as a
      # structured Result instead of a NotImplementedError mid-mission.
      # The full set is the default; providers with a narrower surface
      # override #capabilities.
      CAPABILITIES = %i[instances volumes ips images sync].freeze

      def capabilities
        CAPABILITIES
      end

      def supports?(capability)
        capabilities.include?(capability.to_sym)
      end

      # Cheap, side-effect-free authentication probe. Returns true when
      # credentials are valid; false when they're rejected. On failure,
      # populates `#last_authentication_error` with a human-readable
      # message that the BYOC onboarding UI can surface.
      #
      # Each adapter MUST override this with a provider-specific probe
      # (e.g., AWS: STS#get_caller_identity, Azure: AAD client_credentials
      # token grant, GCP: service-account JWT exchange, OpenStack:
      # Keystone v3 /auth/tokens, LocalQemu: libvirt URI reachability).
      def authenticate?
        raise NotImplementedError, "#{self.class} must implement #authenticate?"
      end

      # Provider type identifier
      #
      # @return [String] The provider type (aws, gcp, azure, openstack, mock)
      def provider_type
        raise NotImplementedError, "#{self.class} must implement #provider_type"
      end

      # ===========================================
      # Instance Lifecycle Operations
      # ===========================================

      # Create a new compute instance
      #
      # @param params [Hash] Instance creation parameters
      # @option params [String] :name Instance name
      # @option params [String] :image_id Machine image ID
      # @option params [String] :instance_type Instance type/size
      # @option params [String] :key_name SSH key name
      # @option params [Array<String>] :security_groups Security group IDs
      # @option params [String] :subnet_id Subnet ID
      # @option params [Hash] :tags Resource tags
      # @return [Hash] Normalized instance data
      def create_instance(params)
        raise NotImplementedError, "#{self.class} must implement #create_instance"
      end

      # Start a stopped instance
      #
      # @param instance_id [String] Cloud instance ID
      # @return [Hash] Result with :success, :status
      def start_instance(instance_id)
        raise NotImplementedError, "#{self.class} must implement #start_instance"
      end

      # === Operator ops hold (optional provider capability) ===
      #
      # A platform-side hold only binds callers that go through the platform.
      # On 2026-07-27 the start that raced offline maintenance on ops-hub was a
      # hypervisor task, and a DB flag would not have stopped it. Providers that
      # can refuse a start at their own layer should do so, so the hold survives
      # callers the platform never sees.
      #
      # Optional by design: a provider without such a primitive reports false
      # and the platform-level guard still applies. Default no-op rather than
      # NotImplementedError so a hold never fails outright on a provider that
      # simply cannot reinforce it.
      def supports_ops_hold?
        false
      end

      # @return [Hash] :success, and :state describing what the provider now reports
      def apply_ops_hold!(_instance_id, reason: nil)
        { success: false, unsupported: true,
          error: "#{self.class} cannot enforce an ops hold at the provider layer" }
      end

      def release_ops_hold!(_instance_id)
        { success: false, unsupported: true,
          error: "#{self.class} cannot enforce an ops hold at the provider layer" }
      end

      # Read back what the provider actually reports. A hold is verified by
      # READING this, never by attempting a start: a probe that finds the hold
      # broken has just started the instance you needed stopped.
      def ops_hold_state(_instance_id)
        nil
      end

      # Stop a running instance
      #
      # @param instance_id [String] Cloud instance ID
      # @param force [Boolean] Force stop without graceful shutdown
      # @return [Hash] Result with :success, :status
      def stop_instance(instance_id, force: false)
        raise NotImplementedError, "#{self.class} must implement #stop_instance"
      end

      # Reboot an instance
      #
      # @param instance_id [String] Cloud instance ID
      # @return [Hash] Result with :success, :status
      def reboot_instance(instance_id)
        raise NotImplementedError, "#{self.class} must implement #reboot_instance"
      end

      # Terminate/delete an instance
      #
      # @param instance_id [String] Cloud instance ID
      # @return [Hash] Result with :success
      # @param instance_id [String] Cloud instance ID
      # @param expected_name [String, nil] The guest name this instance was
      #   created with. Optional, and providers may ignore it — Proxmox uses it to
      #   tell a MIGRATED guest (same id, same name, different node: refuse to
      #   call it gone) from a RECYCLED vmid (same id, different guest: it really
      #   is gone). Omitting it keeps the conservative behaviour.
      def terminate_instance(instance_id, expected_name: nil)
        raise NotImplementedError, "#{self.class} must implement #terminate_instance"
      end

      # Get current instance state
      #
      # @param instance_id [String] Cloud instance ID
      # @return [Hash] Normalized instance data with current state
      def get_instance(instance_id)
        raise NotImplementedError, "#{self.class} must implement #get_instance"
      end

      # Reconcile the platform's view of an instance against the provider's
      # current truth. Default implementation delegates to #get_instance (which
      # every concrete provider implements) and maps a "gone" instance to
      # :terminated so the controller's in-flight reconcile loop stops waiting
      # on a deleted instance — mirroring local_qemu/proxmox, which override
      # this with cheaper status-only queries.
      #
      # Handles both ways providers signal "gone": a `{ success: false,
      # error_code: "NotFound" }` hash (aws/gcp) and a raised
      # ResourceNotFoundError (azure/openstack). Any other error propagates to
      # the caller (the controller logs + skips it).
      #
      # @param instance_id [String] Cloud instance ID
      # @return [Hash] { success:, status:, private_ip_address:, public_ip_address: }
      def sync_status(instance_id)
        result = get_instance(instance_id)
        return result if result.is_a?(Hash) && result[:success]

        if result.is_a?(Hash) &&
           (result[:error_code].to_s.casecmp?("NotFound") || result[:error].to_s.match?(/not found/i))
          return build_instance_response(cloud_id: instance_id, status: "terminated")
        end

        result
      rescue StandardError => e
        raise unless e.class.name.to_s.match?(/NotFound/i) || e.message.to_s.match?(/not found/i)

        build_instance_response(cloud_id: instance_id, status: "terminated")
      end

      # List instances with optional filters and pagination.
      #
      # Adapters MUST page through all results up to the caller's `max_pages`
      # limit (default 100) and return the aggregated set. Failures raise
      # the typed exception family (AuthenticationError, RateLimitError,
      # ResourceNotFoundError, ProviderError) rather than returning a
      # `{ success: false }` hash.
      #
      # @param filters [Hash] Optional filters and pagination knobs
      #   :per_page  [Integer] Page size hint (provider-specific cap applies)
      #   :max_pages [Integer, nil] Stop after N pages; nil = unbounded
      #   :status    [String] Filter by normalized status
      # @return [Hash] { success: true, instances: [...], page_count: N, truncated: Boolean }
      def list_instances(filters = {})
        raise NotImplementedError, "#{self.class} must implement #list_instances"
      end

      # ===========================================
      # IP Address Operations
      # ===========================================

      # Allocate a new public/elastic IP
      #
      # @return [Hash] Result with :success, :allocation_id, :public_ip
      def allocate_ip
        raise NotImplementedError, "#{self.class} must implement #allocate_ip"
      end

      # Associate an IP with an instance
      #
      # @param instance_id [String] Cloud instance ID
      # @param allocation_id [String, nil] IP allocation ID (if pre-allocated)
      # @return [Hash] Result with :success, :public_ip, :association_id
      def associate_ip(instance_id, allocation_id: nil)
        raise NotImplementedError, "#{self.class} must implement #associate_ip"
      end

      # Disassociate an IP from an instance
      #
      # @param association_id [String] IP association ID
      # @return [Hash] Result with :success
      def disassociate_ip(association_id)
        raise NotImplementedError, "#{self.class} must implement #disassociate_ip"
      end

      # Release an allocated IP
      #
      # @param allocation_id [String] IP allocation ID
      # @return [Hash] Result with :success
      def release_ip(allocation_id)
        raise NotImplementedError, "#{self.class} must implement #release_ip"
      end

      # ===========================================
      # Volume Operations
      # ===========================================

      # Create a new storage volume
      #
      # @param params [Hash] Volume creation parameters
      # @option params [Integer] :size_gb Volume size in GB
      # @option params [String] :volume_type Volume type
      # @option params [String] :availability_zone AZ for the volume
      # @return [Hash] Result with :success, :volume_id
      def create_volume(params)
        raise NotImplementedError, "#{self.class} must implement #create_volume"
      end

      # Attach a volume to an instance
      #
      # @param volume_id [String] Cloud volume ID
      # @param instance_id [String] Cloud instance ID
      # @param device [String] Device path (e.g., /dev/sdb)
      # @return [Hash] Result with :success, :device
      def attach_volume(volume_id, instance_id, device: nil)
        raise NotImplementedError, "#{self.class} must implement #attach_volume"
      end

      # Detach a volume from an instance
      #
      # @param volume_id [String] Cloud volume ID
      # @param force [Boolean] Force detach
      # @return [Hash] Result with :success
      def detach_volume(volume_id, force: false)
        raise NotImplementedError, "#{self.class} must implement #detach_volume"
      end

      # Delete a volume
      #
      # @param volume_id [String] Cloud volume ID
      # @return [Hash] Result with :success
      def delete_volume(volume_id)
        raise NotImplementedError, "#{self.class} must implement #delete_volume"
      end

      # Get volume information
      #
      # @param volume_id [String] Cloud volume ID
      # @return [Hash] Normalized volume data
      def get_volume(volume_id)
        raise NotImplementedError, "#{self.class} must implement #get_volume"
      end

      # ===========================================
      # Image Operations
      # ===========================================

      # Create an image from an instance
      #
      # @param instance_id [String] Cloud instance ID
      # @param name [String] Image name
      # @param description [String, nil] Image description
      # @return [Hash] Result with :success, :image_id
      def create_image(instance_id, name:, description: nil)
        raise NotImplementedError, "#{self.class} must implement #create_image"
      end

      # Get image information
      #
      # @param image_id [String] Cloud image ID
      # @return [Hash] Normalized image data
      def get_image(image_id)
        raise NotImplementedError, "#{self.class} must implement #get_image"
      end

      # Delete an image
      #
      # @param image_id [String] Cloud image ID
      # @return [Hash] Result with :success
      def delete_image(image_id)
        raise NotImplementedError, "#{self.class} must implement #delete_image"
      end

      # ===========================================
      # Utility Methods
      # ===========================================

      # Test provider connection
      #
      # @return [Hash] Result with :success, :message
      def test_connection
        raise NotImplementedError, "#{self.class} must implement #test_connection"
      end

      # Get provider-specific metadata
      #
      # @return [Hash] Provider metadata (regions, instance types, etc.)
      def get_metadata
        raise NotImplementedError, "#{self.class} must implement #get_metadata"
      end

      protected

      # Normalize instance status from provider-specific to common format
      #
      # @param provider_status [String] Provider-specific status
      # @return [String] Normalized status
      def normalize_status(provider_status)
        raise NotImplementedError, "#{self.class} must implement #normalize_status"
      end

      # Read a credential value with column-then-config fallback. Centralizes
      # the "try the typed column, fall back to config[..], optionally raise
      # if missing" pattern that every adapter previously hand-rolled.
      #
      # @param column [Symbol, nil] connection column to read first (e.g. :tenant)
      # @param config_key [String, Symbol, nil] config-dict fallback key
      # @param required [Boolean] raise AuthenticationError if missing/blank
      # @param default [Object, nil] returned if neither column nor config has a value
      # @return [Object, nil]
      def credential(column: nil, config_key: nil, required: false, default: nil)
        value = nil

        if column && connection.respond_to?(column)
          typed = connection.public_send(column)
          value = typed if typed.respond_to?(:present?) ? typed.present? : !typed.nil?
        end

        if value.nil? && config_key
          cfg = connection.config&.dig(config_key.to_s)
          value = cfg if cfg.respond_to?(:present?) ? cfg.present? : !cfg.nil?
        end

        # BYOC fallback: an operator may have saved credentials via the M2
        # ProviderCredential flow (Credentials tab in ProviderFormModal),
        # which writes to ::System::ProviderCredential — a separate store
        # from this ProviderConnection's typed columns / config JSONB.
        # Without consulting it here, BYOC-saved keys are invisible to the
        # adapter even though they're the operator's canonical credentials.
        if value.nil?
          byoc = ::System::ProviderCredential.for(
            account: connection.account,
            provider: connection.provider
          ) rescue nil
          if byoc&.credentials.is_a?(Hash)
            [ column, config_key ].compact.each do |key|
              next unless value.nil?
              v = byoc.credentials[key.to_s] || byoc.credentials[key.to_sym]
              value = v if v.respond_to?(:present?) ? v.present? : !v.nil?
            end
          end
        end

        value = default if value.nil? && !default.nil?

        if required && (value.respond_to?(:blank?) ? value.blank? : value.nil?)
          label = config_key || column
          raise AuthenticationError,
                "Missing required #{provider_type} credential: #{label}"
        end

        value
      end

      # Resolve the first present value among *keys, preferring transient (BYOC
      # request-scoped) credentials, else the connection's typed column / config
      # via #credential. Hoisted from the 4 cloud adapters (was byte-identical).
      def auth_credential(*keys)
        if @transient_credentials
          keys.each do |key|
            value = @transient_credentials[key.to_s] || @transient_credentials[key.to_sym]
            return value if value.respond_to?(:present?) ? value.present? : !value.to_s.empty?
          end
          return nil
        end

        return nil unless connection
        keys.each do |key|
          value = credential(column: key.to_sym, config_key: key.to_s)
          return value if value.respond_to?(:present?) ? value.present? : !value.to_s.empty?
        end
        nil
      end

      # Apply the fail-fast connect/read timeout convention to a Faraday
      # connection builder (the block argument yielded by `Faraday.new`).
      # Centralizes the open_timeout/timeout pair so the hand-rolled REST
      # adapters (Azure, GCP, OpenStack auth) don't repeat the literals.
      #
      # @param faraday [Faraday::Connection] builder yielded inside Faraday.new
      # @return [Faraday::Connection] the same builder (for chaining)
      def apply_http_timeouts(faraday)
        faraday.options.open_timeout = DEFAULT_CONNECT_TIMEOUT
        faraday.options.timeout      = DEFAULT_READ_TIMEOUT
        faraday
      end

      # Build normalized instance response
      #
      # @param cloud_id [String] Cloud instance ID
      # @param status [String] Normalized status
      # @param private_ip [String, nil] Private IP address
      # @param public_ip [String, nil] Public IP address
      # @param metadata [Hash] Additional metadata
      # @return [Hash] Normalized instance data
      def build_instance_response(cloud_id:, status:, private_ip: nil, public_ip: nil, **metadata)
        {
          success: true,
          cloud_instance_id: cloud_id,
          status: status,
          private_ip_address: private_ip,
          public_ip_address: public_ip,
          provider_type: provider_type,
          synced_at: Time.current
        }.merge(metadata)
      end

      # Build error response
      #
      # @param message [String] Error message
      # @param code [String, nil] Error code
      # @return [Hash] Error response
      def build_error_response(message, code: nil)
        {
          success: false,
          error: message,
          error_code: code,
          provider_type: provider_type
        }
      end

      # Keys whose values are scrubbed from log output. Match is exact on
      # the serialized key name (string or symbol). Applied recursively to
      # nested hashes, arrays, and AR record attribute dumps — protects
      # against AR records being passed in params and serializing all
      # columns (including ssh_key + ssh_host_key) via to_json.
      LOG_SENSITIVE_KEYS = %w[
        ssh_key ssh_host_key private_key
        access_key secret_key access_token refresh_token
        acceptance_token bootstrap_token enrollment_token
        api_key password vault_token client_secret authorization
        user_data ssh_keys ssh_authorized_keys
      ].to_set.freeze

      def log_operation(operation, **details)
        logger.info("[#{self.class.name}] #{operation}: #{sanitize_for_log(details).to_json}")
      end

      def sanitize_for_log(obj)
        case obj
        when ::Hash
          obj.each_with_object({}) do |(k, v), out|
            out[k] = LOG_SENSITIVE_KEYS.include?(k.to_s) ? "[REDACTED]" : sanitize_for_log(v)
          end
        when ::Array
          obj.map { |item| sanitize_for_log(item) }
        when ::ActiveRecord::Base
          sanitize_for_log(obj.attributes)
        else
          obj
        end
      end

      # Handle provider-specific errors and convert to common errors
      #
      # @param error [StandardError] The caught error
      # @raise [ProviderError] Converted error
      def handle_error(error)
        logger.error("[#{self.class.name}] Error: #{error.class} - #{error.message}")
        raise ProviderError, error.message
      end
    end
  end
end
