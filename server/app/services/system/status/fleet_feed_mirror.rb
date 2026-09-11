# frozen_string_literal: true

module System
  module Status
    # THE MIRROR EMITTER (design §4.3). Core writes every verdict transition as
    # Platform::StatusEvents and knows nothing of the fleet feed. This class
    # is registered into Platform::Status::Emitters from to_prepare (pull,
    # never push) and copies each transition into System::FleetEvent, so the
    # fleet stream shows component status beside the signals and decisions it
    # already carries.
    #
    # A MIRROR, NOT A PRODUCER. Nothing is decided here, and core discards the
    # return value.
    #
    # ONE FLEET EVENT PER TRANSITION. Core writes a status_changed event for
    # every transition, and a component_down event beside it when the move is
    # into down (Platform::Status::SweepRunner#write_events). Mirroring each
    # event put two feed rows on one outage. The feed row is the transition's
    # most specific event, component_down when there is one. Its payload
    # carries that event's id and the ids of every event the transition wrote.
    #
    # A SHARED component (null account) is not mirrored: FleetEvent is a
    # per-account ledger, and a shared row has no account to file it under.
    class FleetFeedMirror
      NAME = :fleet_feed
      SOURCE = "platform.status"

      # FleetEvent has four severity rungs and the verdict ladder has six. A
      # transition INTO down is the fleet's "high" (critical stays reserved for
      # the sensors that already use it), into degraded is "medium", and every
      # other move (recovery, held, progressing, not_measured, removal) is "low".
      SEVERITY_BY_VERDICT = {
        ::Platform::ComponentStatus::DOWN => "high",
        ::Platform::ComponentStatus::DEGRADED => "medium"
      }.freeze
      DEFAULT_SEVERITY = "low"

      # The FleetEvent resource column for a component kind whose ref IS that
      # resource's id, so the fleet feed's per-resource filters find the mirror.
      REF_COLUMNS = {
        "node_instance" => :node_instance_id,
        "node" => :node_id,
        "node_module" => :node_module_id,
        "acme_certificate" => :certificate_id
      }.freeze

      UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

      # @return [Integer] how many feed rows were written: 0 or 1
      def self.call(transition:, events:)
        account_id = transition[:account_id] || transition["account_id"]
        return 0 if account_id.nil?

        account = ::Account.find_by(id: account_id)
        return 0 unless account

        events = Array(events)
        event = representative(events)
        return 0 unless event

        mirror(account, transition, event, events) ? 1 : 0
      end

      def self.representative(events)
        events.find { |event| event.kind.to_s == ::Platform::StatusEvent::KIND_COMPONENT_DOWN } || events.first
      end
      private_class_method :representative

      def self.mirror(account, transition, event, events)
        kind = event.component_kind.to_s
        ref = event.component_ref.to_s
        ::System::Fleet::EventBroadcaster.emit!(
          account: account,
          kind: event.kind,
          severity: SEVERITY_BY_VERDICT.fetch(event.to_verdict.to_s, DEFAULT_SEVERITY),
          payload: {
            "status_event_id" => event.id,
            "status_event_ids" => events.map(&:id),
            "component_kind" => kind,
            "component_ref" => ref,
            "from" => event.from_verdict,
            "to" => event.to_verdict,
            "reason" => transition[:reason] || transition["reason"]
          }.compact,
          source: SOURCE,
          correlation_id: "component_status:#{kind}:#{ref}",
          **resource_ref(kind, ref)
        )
      end
      private_class_method :mirror

      def self.resource_ref(kind, ref)
        column = REF_COLUMNS[kind]
        column && ref.match?(UUID) ? { column => ref } : {}
      end
      private_class_method :resource_ref
    end
  end
end
