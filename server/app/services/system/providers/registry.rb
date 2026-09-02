# frozen_string_literal: true

module System
  module Providers
    # Registry for cloud provider adapters
    # Provides factory methods for creating provider instances based on connection type
    class Registry
      class UnknownProviderError < StandardError; end

      # Raised when the provider type IS registered but the adapter's SDK gem
      # is not bundled in this build (APO-7). A subclass of
      # UnknownProviderError so `.with_adapter` — and every existing caller
      # that already rescues UnknownProviderError — turns it into a
      # Runtime::Result refusal naming the gem, never a bare NameError from
      # deep inside the adapter.
      class ProviderSdkMissingError < UnknownProviderError; end

      # Registered provider types and their adapter classes.
      # Mapped by class NAME so an adapter file that is not present is not a
      # boot error. Note that #available_providers / #sdk_available? DO
      # resolve every mapped class (constantize) in order to ask it whether
      # its optional SDK gem is loaded — an adapter must therefore never
      # `require` an unbundled gem at the top of its file.
      PROVIDER_CLASSES = {
        "aws" => "System::Providers::AwsProvider",
        "gcp" => "System::Providers::GcpProvider",
        "azure" => "System::Providers::AzureProvider",
        "openstack" => "System::Providers::OpenStackProvider",
        "proxmox" => "System::Providers::ProxmoxProvider",
        "mock" => "System::Providers::MockProvider",
        "local_qemu" => "System::Providers::LocalQemuProvider",
        "pro_cloud" => "System::Providers::ProCloudProvider"
      }.freeze

      class << self
        # Get a provider adapter for a connection
        #
        # @param connection [System::ProviderConnection] The provider connection
        # @param region [System::ProviderRegion, nil] Optional region override
        # @return [BaseProvider] The provider adapter instance
        # @raise [UnknownProviderError] If provider type is not registered
        def for(connection, region: nil)
          provider_type = connection.provider.provider_type

          unless PROVIDER_CLASSES.key?(provider_type)
            raise UnknownProviderError, "Unknown provider type: #{provider_type}. " \
                                        "Available: #{available_providers.join(', ')}"
          end

          provider_class = PROVIDER_CLASSES[provider_type].constantize

          unless provider_class.sdk_available?
            raise ProviderSdkMissingError, sdk_missing_message(provider_type)
          end

          provider_class.new(connection, region: region)
        end

        # Get a provider adapter for a node instance
        #
        # @param instance [System::NodeInstance] The node instance
        # @return [BaseProvider] The provider adapter instance
        # @raise [UnknownProviderError] If no connection found or provider unknown
        def for_instance(instance)
          connection = find_connection_for_instance(instance)

          unless connection
            raise UnknownProviderError, "No provider connection available for instance #{instance.id}"
          end

          self.for(connection, region: instance.provider_region)
        end

        # Get a provider adapter for a node
        #
        # @param node [System::Node] The node
        # @param region [System::ProviderRegion] The target region
        # @return [BaseProvider] The provider adapter instance
        def for_node(node, region:)
          connection = find_connection_for_region(region, node.account)

          unless connection
            raise UnknownProviderError, "No provider connection available for region #{region.id}"
          end

          self.for(connection, region: region)
        end

        # Get a provider adapter for a volume
        #
        # @param volume [System::ProviderVolume] The volume
        # @return [BaseProvider] The provider adapter instance
        def for_volume(volume)
          connection = find_connection_for_region(volume.provider_region, volume.account)

          unless connection
            raise UnknownProviderError, "No provider connection available for volume #{volume.id}"
          end

          self.for(connection, region: volume.provider_region)
        end

        # Look up the adapter class for a Provider record (or provider_type
        # string). Used by System::CredentialValidationService — the BYOC
        # onboarding flow needs the adapter class without instantiating it
        # against a persisted ProviderConnection.
        #
        # @param provider [System::Provider, String, Symbol] Provider record
        #   or provider_type identifier
        # @return [Class, nil] The adapter class, or nil if unknown
        def adapter_for(provider)
          provider_type = provider.respond_to?(:provider_type) ? provider.provider_type : provider.to_s
          class_name = PROVIDER_CLASSES[provider_type]
          return nil unless class_name
          class_name.constantize
        end

        # List provider types that are OPERABLE in this build — registered
        # and with their SDK gem actually loaded. Adapters whose optional gem
        # is missing are hidden here rather than advertised and then failing
        # at first call (APO-7).
        #
        # @return [Array<String>] Operable provider type identifiers
        def available_providers
          PROVIDER_CLASSES.keys.select { |provider_type| sdk_available?(provider_type) }
        end

        # Every registered provider type, operable or not. Callers that need
        # the mapping itself (docs, catalog listings, "is this a typo?"
        # checks) use this; callers that are about to USE an adapter use
        # #available_providers.
        #
        # @return [Array<String>] Registered provider type identifiers
        def registered_providers
          PROVIDER_CLASSES.keys
        end

        # Check if a provider type is registered (mapping exists). This does
        # NOT imply the adapter can run — see #sdk_available?.
        #
        # @param provider_type [String] The provider type to check
        # @return [Boolean] True if provider is registered
        def supported?(provider_type)
          PROVIDER_CLASSES.key?(provider_type)
        end

        # Check if a registered provider type's SDK gem is loaded here.
        #
        # @param provider_type [String] The provider type to check
        # @return [Boolean] True if the adapter can actually run
        def sdk_available?(provider_type)
          adapter_class = adapter_for(provider_type)
          return false unless adapter_class

          adapter_class.sdk_available?
        end

        # @param provider_type [String] The provider type to check
        # @return [String, nil] The gem this provider type needs but does not
        #   have, or nil when the adapter is operable (or unregistered)
        def missing_sdk_gem(provider_type)
          adapter_class = adapter_for(provider_type)
          return nil unless adapter_class
          return nil if adapter_class.sdk_available?

          adapter_class.required_sdk_gem
        end

        # Refusal text naming the missing gem, for callers that answer with a
        # result instead of raising.
        #
        # @param provider_type [String] The provider type being refused
        # @return [String] Operator-actionable refusal message
        def sdk_missing_message(provider_type)
          "Provider type '#{provider_type}' is not operable in this build: " \
            "the #{missing_sdk_gem(provider_type)} gem is not bundled. " \
            "Operable provider types: #{available_providers.join(', ')}."
        end

        # Register a custom provider (for extensions/plugins)
        #
        # @param provider_type [String] The provider type identifier
        # @param class_name [String] The fully qualified class name
        def register(provider_type, class_name)
          PROVIDER_CLASSES[provider_type] = class_name
        end

        # Find a suitable connection for a region, falling back to a global
        # (account_id IS NULL) connection if no account-scoped connection
        # exists. Public so service-layer callers don't need to duplicate
        # this query (formerly hand-rolled in CloudSyncService and
        # VolumeManagementService).
        #
        # @param region [System::ProviderRegion] The region
        # @param account [Account, nil] The account preferring its own connection
        # @return [System::ProviderConnection, nil] The connection or nil
        def find_connection_for_region(region, account)
          provider = region.provider

          ::System::ProviderConnection
            .where(provider: provider)
            .where("account_id = ? OR account_id IS NULL", account&.id)
            .where(status: "connected")
            .order(Arel.sql("CASE WHEN account_id IS NOT NULL THEN 0 ELSE 1 END"))
            .first
        end

        # Resolve a provider adapter and yield it to the block. If the
        # lookup raises UnknownProviderError, returns Result.err instead
        # of yielding — saving callers a repeated begin/rescue idiom.
        #
        # Pass exactly one of:
        #   connection: + region: (optional)
        #   instance:
        #   node: + region:
        #   volume:
        #
        # Returns whatever the block returns (typically a Runtime::Result).
        def with_adapter(connection: nil, instance: nil, node: nil, volume: nil, region: nil, account: nil)
          adapter =
            if connection
              self.for(connection, region: region)
            elsif instance
              for_instance(instance)
            elsif node && region
              for_node(node, region: region)
            elsif volume
              for_volume(volume)
            else
              raise ArgumentError,
                    "Pass exactly one of: connection:, instance:, node: + region:, volume:"
            end

          yield adapter
        rescue UnknownProviderError => e
          ::System::Runtime::Result.err(error: e.message)
        end

        private

        # Find a suitable connection for an instance
        #
        # @param instance [System::NodeInstance] The instance
        # @return [System::ProviderConnection, nil] The connection or nil
        def find_connection_for_instance(instance)
          region = instance.provider_region
          return nil unless region

          find_connection_for_region(region, instance.node&.account)
        end
      end
    end
  end
end
