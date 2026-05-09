# frozen_string_literal: true

module Api
  module V1
    module System
      module NodeApi
        # Fleet event ingestion endpoint for node instances. Lets the
        # on-node Go agent emit FleetEvent rows scoped to its own
        # account + node_instance, batched per request.
        #
        # Auth: BaseController#authenticate_instance! (mTLS preferred,
        # JWT fallback). The current_instance is the only emit-source
        # the agent can claim — all events are forced to
        # source: "agent" + node_instance_id: current_instance.id so
        # an agent cannot impersonate another instance.
        #
        # Reference: Phase 0 of the agent stub implementation plan
        # (~/.claude/plans/find-stubs-in-powernde-agent-kind-lecun.md).
        class FleetController < BaseController
          # POST /api/v1/system/node_api/fleet/events
          #
          # Body shape:
          #   { events: [
          #       { kind: "module.attached",
          #         severity: "low",
          #         payload: { module_id: "abc", digest: "sha256:..." },
          #         correlation_id: "optional-uuid" },
          #       ...
          #   ] }
          #
          # Returns { written: <count> } where count is the number of
          # events successfully persisted. Per-event failures don't
          # abort the batch — broadcaster.emit! returns nil on error
          # and is logged server-side.
          def events
            entries = Array(params[:events])
            return render_error("events: required (non-empty array)", :unprocessable_entity) if entries.empty?

            written = entries.count do |entry|
              attrs = entry.respond_to?(:to_unsafe_h) ? entry.to_unsafe_h : entry
              attrs = attrs.with_indifferent_access if attrs.respond_to?(:with_indifferent_access)

              kind = attrs[:kind]
              next false if kind.blank?

              severity = (attrs[:severity].presence || "low").to_s
              payload  = attrs[:payload].is_a?(Hash) ? attrs[:payload] : {}

              event = ::System::Fleet::EventBroadcaster.emit!(
                account: current_account,
                kind: kind,
                severity: severity,
                payload: payload,
                source: "agent",
                correlation_id: attrs[:correlation_id],
                node_instance_id: current_instance.id
              )
              event.present?
            end

            render_success(written: written, requested: entries.size)
          end
        end
      end
    end
  end
end
