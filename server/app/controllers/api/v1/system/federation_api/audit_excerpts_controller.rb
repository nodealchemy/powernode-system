# frozen_string_literal: true

module Api
  module V1
    module System
      module FederationApi
        # P9.2 — Cross-peer audit excerpt request endpoint.
        #
        # Social Contract commitment #5 ("audit transparency"): on
        # legitimate operator-to-operator request, peers commit to
        # providing audit log excerpts pertaining to the requesting
        # peer's interactions within 72 hours. This endpoint
        # mechanizes the "providing" half — operators on side B
        # implement the request initiation via the request_audit
        # MCP action (P9.2 follow-up).
        #
        # Auth (delegated to BaseController):
        #   mTLS cert → FederationPeer  (current_federation_peer)
        #
        # No specific grant required. Peering itself is the credential
        # for fetching the calling peer's own audit trail — the
        # caller already participated in every event being returned,
        # so there's no third-party data exposure.
        #
        # GET /api/v1/system/federation_api/audit_excerpts
        #   Query:
        #     since: ISO-8601 timestamp (default: 90 days ago)
        #     until: ISO-8601 timestamp (default: now)
        #     limit: integer ≤ 5000 (default 1000)
        #   Returns:
        #     { events: [...], shipments: [...], window, peer_id }
        #
        # `shipments` enumerates WORM shipments covering periods that
        # overlap the requested window so the caller knows which
        # excerpts are sealed already and where they live (the
        # `sealed_path` is operator-visible only; the calling peer
        # doesn't access the raw file).
        #
        # Plan reference: Decentralized Federation Social Contract #5;
        # P9.2 deliverable.
        class AuditExcerptsController < BaseController
          MAX_LIMIT = 5_000
          DEFAULT_LIMIT = 1_000
          DEFAULT_WINDOW_DAYS = 90

          def index
            peer = current_federation_peer
            unless peer && peer.status == "active"
              return render_error("Audit excerpts available only to peers in active status",
                                  :forbidden)
            end

            since_ts = parse_ts(params[:since]) || (Time.current - DEFAULT_WINDOW_DAYS.days)
            until_ts = parse_ts(params[:until]) || Time.current
            limit    = [ (params[:limit].to_i.positive? ? params[:limit].to_i : DEFAULT_LIMIT), MAX_LIMIT ].min

            if until_ts <= since_ts
              return render_error("until must be after since", :unprocessable_entity)
            end

            events = events_for_peer(peer, since: since_ts, until_at: until_ts, limit: limit)
            shipments = shipments_overlapping(peer, since: since_ts, until_at: until_ts)

            render_success(
              peer_id:   peer.id,
              window:    { since: since_ts.iso8601, until: until_ts.iso8601 },
              events:    events.map { |e| serialize_event(e) },
              shipments: shipments.map { |s| serialize_shipment(s) },
              count:     events.size
            )
          end

          private

          def parse_ts(raw)
            return nil if raw.blank?
            Time.parse(raw.to_s).utc
          rescue ArgumentError
            nil
          end

          def events_for_peer(peer, since:, until_at:, limit:)
            ::System::FleetEvent
              .where(account_id: peer.account_id)
              .where(emitted_at: since..until_at)
              .where(
                "(payload->>'federation_peer_id' = ?) OR (payload->>'peer_id' = ?)",
                peer.id, peer.id
              )
              .order(:emitted_at)
              .limit(limit)
          end

          def shipments_overlapping(peer, since:, until_at:)
            ::System::FederationAuditShipment
              .where(federation_peer_id: peer.id)
              .where("period_end >= ? AND period_start <= ?", since, until_at)
              .terminal
              .order(:period_start)
          end

          def serialize_event(event)
            {
              id:               event.id,
              kind:              event.kind,
              severity:          event.severity,
              emitted_at:        event.emitted_at&.iso8601,
              correlation_id:    event.correlation_id,
              source:            event.source,
              payload:           event.payload
            }
          end

          def serialize_shipment(shipment)
            {
              id:           shipment.id,
              period_start: shipment.period_start.iso8601,
              period_end:   shipment.period_end.iso8601,
              event_count:  shipment.event_count,
              sha256:       shipment.sha256,
              status:       shipment.status,
              shipped_at:   shipment.shipped_at&.iso8601
            }
          end
        end
      end
    end
  end
end
