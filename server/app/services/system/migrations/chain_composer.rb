# frozen_string_literal: true

module System
  module Migrations
    # P9.5 — Compose a MigrationChain from a hop list.
    #
    # Given a chain like `[self, peer_b, peer_c]` (peer ids), composes:
    #   1. A `System::MigrationChain` row capturing the envelope
    #   2. One `System::Migration` per hop (chain_position 0..N-1),
    #      each in `planned` state ready for sequential execution
    #
    # The composer does NOT execute. `ChainExecutor` is the runtime
    # that walks the chain, triggers each hop's apply, and advances
    # the chain's `current_hop_index` after each successful hop.
    #
    # Plan reference: Decentralized Federation P9 (multi-hop migration
    # workflows) + Locked Decision #14 (single home per UUID).
    class ChainComposer
      Result = ::Struct.new(:ok?, :chain, :error, keyword_init: true)

      class << self
        def compose!(account:, hop_peer_ids:, root_resource_kind:,
                     root_resource_id:, operation: "migrate",
                     initiated_by_user: nil, metadata: {})
          new(account: account, hop_peer_ids: hop_peer_ids,
              root_resource_kind: root_resource_kind,
              root_resource_id: root_resource_id,
              operation: operation,
              initiated_by_user: initiated_by_user,
              metadata: metadata).compose!
        end
      end

      def initialize(account:, hop_peer_ids:, root_resource_kind:,
                     root_resource_id:, operation:, initiated_by_user:, metadata:)
        @account             = account
        @hop_peer_ids        = Array(hop_peer_ids)
        @root_resource_kind  = root_resource_kind
        @root_resource_id    = root_resource_id
        @operation           = operation.to_s
        @initiated_by_user   = initiated_by_user
        @metadata            = metadata.is_a?(::Hash) ? metadata : {}
      end

      def compose!
        validate!
        chain = nil

        ::System::MigrationChain.transaction do
          chain = ::System::MigrationChain.create!(
            account:               @account,
            initiated_by_user:     @initiated_by_user,
            hop_peer_ids:          @hop_peer_ids,
            root_resource_kind:    @root_resource_kind,
            root_resource_id:      @root_resource_id,
            operation:             @operation,
            status:                "planned",
            current_hop_index:     0,
            total_hops:            @hop_peer_ids.size - 1, # N peers = N-1 hops
            metadata:              @metadata
          )

          (1...@hop_peer_ids.size).each do |idx|
            dest_peer_id = @hop_peer_ids[idx]
            ::System::Migration.create!(
              account:             @account,
              initiated_by_user:   @initiated_by_user,
              destination_peer_id: dest_peer_id,
              root_resource_kind:  @root_resource_kind,
              root_resource_id:    @root_resource_id,
              operation:           @operation,
              status:              "planned",
              migration_chain_id:  chain.id,
              chain_position:      idx - 1,
              dry_run:             false,
              metadata:            { "chain_hop" => idx }
            )
          end

          chain.append_audit!(
            "event"        => "chain_composed",
            "hop_count"    => chain.total_hops,
            "hop_peer_ids" => @hop_peer_ids
          )
        end

        Result.new(ok?: true, chain: chain.reload)
      rescue ::ActiveRecord::RecordInvalid, ::ArgumentError => e
        Result.new(ok?: false, error: e.message)
      end

      private

      def validate!
        if @hop_peer_ids.size < 2
          raise ::ArgumentError, "chain needs at least 2 hop peer ids (origin + 1 destination); got #{@hop_peer_ids.inspect}"
        end
        if @hop_peer_ids.uniq.size != @hop_peer_ids.size
          raise ::ArgumentError, "duplicate hop peer in chain: #{@hop_peer_ids.inspect}"
        end
        unless ::System::MigrationChain::OPERATIONS.include?(@operation)
          raise ::ArgumentError, "operation must be one of #{::System::MigrationChain::OPERATIONS.inspect}"
        end
      end
    end
  end
end
