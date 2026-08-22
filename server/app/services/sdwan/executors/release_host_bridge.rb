# frozen_string_literal: true

module Sdwan
  module Executors
    # Executor for `sdwan.host_bridge_delete` (IMP-97c7b4123d8f).
    #
    # `force: true` skips the draining grace window that lets in-flight taps
    # settle before the short_id is reusable, so this carries the delete tier
    # its siblings do.
    #
    # IMP-53a5c597ec8c made this class the SINGLE declaration site for what
    # "force" means on this verb. Before it, the two surfaces naming this act
    # disagreed about the default: REST host_bridges#destroy called
    # HostBridgeAllocator.release!(force: true) unconditionally, while the MCP
    # arm read `params[:force] == true` and so defaulted to draining. An
    # OPERATOR delete therefore skipped a grace window an AGENT release
    # honored — the same intent, opposite safety postures.
    #
    # The default is now DRAIN on every surface, with force an explicit
    # opt-in. Drain is the conservative arm and the one whose consequences are
    # recoverable: a drained bridge stays in `compilable`, so the topology
    # compiler keeps emitting it and Sdwan::HostBridgeResolver keeps answering
    # for the host — in-flight taps survive, and a caller who actually needed
    # the hard release calls again with force. A hard release is not
    # recoverable in the same sense: the row leaves `compilable` immediately
    # and anything mid-provision against that bridge loses its name.
    class ReleaseHostBridge < ::System::Executors::Base
      ACTION_CATEGORY = "sdwan.host_bridge_delete"

      # The default, stated once. Changing it here changes it on every surface
      # — which is the property the divergence above cost us.
      DEFAULT_FORCE = false

      # Coercion, also stated once. REST params arrive as STRINGS ("true" from
      # a query string or a JSON body's boolean round-tripped through
      # ActionController::Parameters), MCP params arrive as real booleans, and
      # a deferred operation replays them through a JSONB round trip. All
      # three have to mean the same thing or the surfaces diverge again in a
      # subtler way than they did the first time — the same lesson
      # IMP-6bbe5c673c38 learned from IPFIX's `port` coercion.
      #
      # This is an ALLOW-LIST on BOTH sides rather than
      # ActiveModel::Type::Boolean, and the reason is the failure DIRECTION.
      # Rails' Boolean cast has a closed FALSE_VALUES set and treats
      # everything outside it as TRUE, so `"False"`, `"no"`, `"n"`, `" "`,
      # `[]` and `{}` all cast to true — i.e. an unrecognised value would
      # select the DESTRUCTIVE arm. On a verb whose forced branch tears a
      # bridge off a live host, an input nobody can parse must fall to the
      # default, never to the irreversible option. The MCP surface makes this
      # concrete: its params are emitted by a model, and "no" is a plausible
      # thing for one to write.
      #
      # An ABSENT, blank or UNRECOGNISED value is therefore the caller
      # expressing no usable opinion, and all three resolve to DEFAULT_FORCE.
      TRUTHY = %w[true t 1 yes y on].freeze
      FALSY  = %w[false f 0 no n off].freeze

      def self.force?(raw)
        return raw if raw == true || raw == false
        return DEFAULT_FORCE if raw.nil?

        token = raw.to_s.strip.downcase
        return true  if TRUTHY.include?(token)
        return false if FALSY.include?(token)

        DEFAULT_FORCE
      end

      protected

      def perform
        bridge = resolve_scoped(::Sdwan::HostBridge, params[:host_bridge_id])
        forced = self.class.force?(params[:force])
        ::Sdwan::HostBridgeAllocator.release!(bridge, force: forced)
        { host_bridge_id: bridge.id, state: bridge.reload.state, forced: forced }
      end

      def summarize
        forced = self.class.force?(params[:force]) ? " (forced)" : ""
        "Release SDWAN host bridge #{(scoped_label_record(::Sdwan::HostBridge, params[:host_bridge_id])&.bridge_name || params[:host_bridge_id])}#{forced}"
      end

      def impact
        "Removes the bridge from the node; the default drains it (the compiler keeps emitting it " \
          "until in-flight taps finish), and a forced release skips that window"
      end
    end
  end
end
