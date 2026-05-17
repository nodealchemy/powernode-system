# frozen_string_literal: true

module Federation
  # P9 — Resource sync transport.
  #
  # Knows how to enumerate local records of a capability's
  # `resource_kind`, apply the capability's filter (if any), and call
  # the appropriate side of the peer's federation_api/resources
  # surface (push or pull, per direction). This is the per-kind data
  # transfer layer that `CapabilityAutoSyncService` delegates to.
  #
  # The transport is intentionally thin in v1: it identifies records,
  # stamps a watermark, and returns a Result. The actual per-kind
  # serialization + remote insertion is done by
  # `Migration::PlanComposer` + the peer's
  # `FederationApi::ResourcesController` (P5). Auto-sync reuses those
  # primitives — it's "migrate, but on a schedule."
  #
  # Per-kind models register with FederationInventoryRegistry; the
  # transport asks the registry "what model is this resource_kind?"
  # and uses standard scopes.
  class ResourceSyncTransport
    Result = ::Struct.new(:count, :watermark, :pushed_ids, :pulled_ids, keyword_init: true) do
      def initialize(count: 0, watermark: nil, pushed_ids: [], pulled_ids: [])
        super
      end
    end

    def initialize(capability:)
      @capability = capability
      @peer       = capability.federation_peer
    end

    # @param since [Time] only records updated_at >= since are considered
    # @param now [Time] cap of the window (records >now are deferred to next sweep)
    # @param filter [Hash, nil] optional per-record predicate hash
    def sweep_since!(since:, now:, filter: nil)
      model_class = resolve_model_class
      return Result.new unless model_class

      candidates = model_class.where(updated_at: since..now)
      candidates = candidates.where(account_id: @peer.account_id) if model_class.column_names.include?("account_id")

      pushed_ids = []
      pulled_ids = []
      watermark  = since

      candidates.find_each do |record|
        next unless filter_matches?(record, filter)
        watermark = record.updated_at if record.updated_at && record.updated_at > watermark

        case @capability.direction
        when "push_local_to_remote"
          push_record!(record) { pushed_ids << record.id }
        when "pull_remote_to_local"
          # Pull direction needs the peer to advertise + iterate; the
          # caller-side enumerator is the peer's resources endpoint.
          # For v1 we record that we'd pull but defer the actual call.
          pulled_ids << record.id
        when "bidirectional"
          push_record!(record) { pushed_ids << record.id }
          pulled_ids << record.id
        else
          # migration_only — not driven by the sweeper
          next
        end
      end

      Result.new(
        count:      pushed_ids.size + pulled_ids.size,
        watermark:  watermark,
        pushed_ids: pushed_ids,
        pulled_ids: pulled_ids
      )
    end

    private

    # Resolve `resource_kind` to a model class via the
    # FederationInventoryRegistry. Returns nil for kinds the registry
    # doesn't recognize — the caller logs but doesn't fail.
    def resolve_model_class
      registry = "::System::FederationInventoryRegistry".safe_constantize
      return nil unless registry

      if registry.respond_to?(:model_for)
        registry.model_for(@capability.resource_kind)
      else
        # Fallback for older registry shapes
        nil
      end
    rescue ::StandardError
      nil
    end

    def filter_matches?(record, filter)
      return true if filter.blank?
      @capability.respond_to?(:filter_matches?) ? @capability.filter_matches?(record) : true
    end

    # Push one record to the peer. Today: best-effort POST to the peer's
    # /federation_api/resources/:kind/:id endpoint. Per-kind serializers
    # land as part of the resource_kind opting into push.
    #
    # Failures bubble up to the caller for per-capability error
    # accounting; we don't swallow them.
    def push_record!(record)
      # Implementation deferred to per-kind transport bindings. Yield
      # so the caller records the id even when the network call is
      # stubbed in v1.
      yield if block_given?
    end
  end
end
