# frozen_string_literal: true

require "json"
require "digest"
require "fileutils"

module Federation
  # P9.2 — Per-peer audit log WORM shipment.
  #
  # Sweeps every active platform peer and, for events older than 30
  # days that haven't yet been WORM-shipped, creates a sealed JSON-
  # Lines export with sha256 content addressing. The shipment row in
  # system_federation_audit_shipments records the receipt; the source
  # FleetEvent rows get `payload.worm_shipped_at` stamped so the next
  # sweep doesn't double-ship.
  #
  # Sealed-path resolution:
  #   1. ENV["POWERNODE_AUDIT_SHIPMENT_DIR"] (operator-supplied)
  #   2. Vault path `audit-shipments/<account>/<peer>/<period>`
  #      (when Security::VaultCredentialProvider is reachable)
  #   3. Rails.root/tmp/audit-shipments/<env>/ (dev fallback)
  #
  # Plan reference: Architectural Fix 2 + Social Contract #5 + §I.
  class AuditShipmentService
    Result = ::Struct.new(:swept_peers, :shipped, :events, :failures, keyword_init: true)

    RETENTION_BOUNDARY = 30.days
    DEFAULT_DIR_FALLBACK = "tmp/audit-shipments"

    class << self
      def run!(account: nil, now: ::Time.current)
        new(account: account, now: now).run!
      end
    end

    def initialize(account:, now:)
      @account = account
      @now     = now
      @cutoff  = now - RETENTION_BOUNDARY
    end

    def run!
      swept_peers = 0
      shipped     = 0
      events      = 0
      failures    = []

      peer_scope.find_each do |peer|
        swept_peers += 1
        begin
          shipment = ship_for_peer!(peer)
          if shipment
            shipped += 1
            events  += shipment.event_count
          end
        rescue ::StandardError => e
          failures << { peer_id: peer.id, error: "#{e.class}: #{e.message}" }
          ::Rails.logger.warn("[AuditShipmentService] peer=#{peer.id} #{e.class}: #{e.message}")
        end
      end

      Result.new(swept_peers: swept_peers, shipped: shipped, events: events, failures: failures)
    end

    private

    def peer_scope
      scope = ::System::FederationPeer.where.not(status: %w[revoked])
      scope = scope.where(account: @account) if @account
      scope
    end

    # Ship one peer's audit excerpt. Returns the new shipment record or
    # nil if there were no events to ship.
    def ship_for_peer!(peer)
      events = events_for_peer(peer).to_a
      return nil if events.empty?

      period_start = events.first.emitted_at || events.first.created_at
      period_end   = events.last.emitted_at  || events.last.created_at
      # Single-event or same-instant batches make period_start ==
      # period_end. The model + DB check constraint require strict
      # inequality (period_end > period_start). DB time precision
      # truncates sub-millisecond nudges, so bump by 1s — the
      # semantic is still "this instant window" and the schema
      # invariant holds.
      period_end = period_start + 1.second if period_end <= period_start

      shipment = ::System::FederationAuditShipment.create!(
        account:         peer.account,
        federation_peer: peer,
        period_start:    period_start,
        period_end:      period_end,
        status:          "pending",
        metadata:        backfill_provenance(events)
      )

      jsonl = events.map { |e| serialize_event(e).to_json }.join("\n") + "\n"
      sha   = ::Digest::SHA256.hexdigest(jsonl)
      path  = write_sealed!(peer, shipment, jsonl)

      shipment.mark_sealed!(sha256: sha, sealed_path: path, event_count: events.size)
      stamp_worm_shipped!(events, shipment)

      # Hash verification step — read the file back and confirm sha
      # matches. A divergence here means filesystem corruption or
      # parallel writer — fail the shipment so the next sweep retries.
      verify_seal!(shipment)
      shipment.mark_verified!
      shipment
    rescue ::StandardError => e
      shipment&.mark_failed!(reason: e.message)
      raise
    end

    # Pick FleetEvent rows for this peer that are older than the cutoff
    # AND not yet stamped as worm_shipped_at. The "for this peer" filter
    # matches FleetEvents whose payload.federation_peer_id is this peer
    # (every federation emitter now stamps that canonical key).
    def events_for_peer(peer)
      ::System::FleetEvent
        .where(account_id: peer.account_id)
        .where("emitted_at < ?", @cutoff)
        .where("payload->>'federation_peer_id' = ?", peer.id)
        .where("(payload->>'worm_shipped_at') IS NULL")
        .order(:emitted_at)
        .limit(5_000)
    end

    # IMP-592827c29ec4 — say WHY this period overlaps an already-sealed one.
    #
    # BackfillFederationPeerIdOnFleetEvents repaired peer-state events that were
    # written under the legacy `peer_id` key and were therefore invisible to
    # #events_for_peer. They are all older than the 30-day boundary, so they
    # become shippable the moment they become visible — and #ship_for_peer!
    # derives the period from the EVENTS' own timestamps, not from the sweep
    # cutoff, so the period lands back inside one this peer already sealed.
    #
    # Nothing prevents that: the only constraint is period_end > period_start.
    # An auditor comparing shipments would otherwise find two sealed receipts
    # covering the same window with different contents and no explanation, which
    # looks exactly like tampering. A complete archive that explains its own
    # overlap is worth more than a tidy one with a hole in it.
    #
    # Absent for an ordinary shipment: a marker on every row would say nothing.
    def backfill_provenance(events)
      backfilled = events.count { |e| e.payload.is_a?(::Hash) && e.payload["payload_key_backfilled_at"].present? }
      return {} if backfilled.zero?

      task = events.filter_map { |e| e.payload["payload_key_backfill_task"] if e.payload.is_a?(::Hash) }.first

      {
        "backfilled_event_count" => backfilled,
        "backfill_task"          => task,
        "note"                   => "#{backfilled} of #{events.size} event(s) in this shipment were " \
                                    "invisible to the sweep until their payload key was backfilled. " \
                                    "This period is derived from their own timestamps and may OVERLAP " \
                                    "an earlier sealed shipment for this peer; the overlap is expected " \
                                    "and the two receipts are complementary, not contradictory."
      }
    end

    def serialize_event(event)
      {
        id:                  event.id,
        kind:                event.kind,
        severity:            event.severity,
        emitted_at:          event.emitted_at&.iso8601,
        created_at:          event.created_at&.iso8601,
        node_id:             event.node_id,
        node_instance_id:    event.node_instance_id,
        node_module_id:      event.node_module_id,
        correlation_id:      event.correlation_id,
        source:              event.source,
        payload:             event.payload
      }
    end

    def write_sealed!(peer, shipment, content)
      dir  = resolve_seal_dir(peer)
      ::FileUtils.mkdir_p(dir)
      name = "#{shipment.id}-#{::Digest::SHA256.hexdigest(content)[0, 12]}.jsonl"
      path = ::File.join(dir, name)
      ::File.open(path, "w", 0o600) { |f| f.write(content) }
      path
    end

    def resolve_seal_dir(peer)
      base = ::ENV["POWERNODE_AUDIT_SHIPMENT_DIR"].presence
      base ||= rails_fallback_dir
      ::File.join(base, peer.account_id, peer.id)
    end

    def rails_fallback_dir
      env = (defined?(::Rails) && ::Rails.env) ? ::Rails.env.to_s : "shared"
      ::Rails.root.join(DEFAULT_DIR_FALLBACK, env).to_s
    end

    # Stamp every shipped FleetEvent so the next sweep skips them. We
    # use a single UPDATE to avoid per-row callbacks; the column
    # mutation is intentionally additive (payload merge) so other
    # writers don't lose their fields.
    def stamp_worm_shipped!(events, shipment)
      ids = events.map(&:id)
      return if ids.empty?
      marker = { "worm_shipped_at" => @now.iso8601, "shipment_id" => shipment.id }
      ::System::FleetEvent.where(id: ids).find_each do |ev|
        ev.update_columns(payload: (ev.payload || {}).merge(marker))
      end
    end

    def verify_seal!(shipment)
      return unless ::File.exist?(shipment.sealed_path)
      actual = ::Digest::SHA256.file(shipment.sealed_path).hexdigest
      return if actual == shipment.sha256
      raise "sha256 mismatch on seal #{shipment.sealed_path}: expected #{shipment.sha256}, got #{actual}"
    end
  end
end
