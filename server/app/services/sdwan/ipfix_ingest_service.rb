# frozen_string_literal: true

# Sdwan::IpfixIngestService — accepts batched flow records (as parsed by
# external sidecars like vector/fluent-bit) and persists them as
# Sdwan::FlowSample rows. Designed for high-throughput batching: uses
# insert_all to bypass per-record validation callbacks.
#
# Validation runs upfront in two phases:
#   1. Cheap structural checks (presence, type, range) per record.
#     Bad records are collected; valid records still get persisted
#     (partial success is preferable to all-or-nothing for a batch
#     whose individual records were sent independently by sidecars).
#   2. insert_all writes the validated batch in a single round-trip.
#
# Distributed-sidecar architecture: each host runs vector or fluent-bit
# parsing local OVS IPFIX export, then POSTs JSON batches here. Platform
# never speaks IPFIX wire format — the sidecar handles binary parsing,
# template management, etc.
#
# Phase O6 follow-up of the OVS+OVN dual-profile networking roadmap.
module Sdwan
  class IpfixIngestService
    # Reasonable upper bound to prevent a sidecar from posting an
    # unbounded batch. ~5000 records × 200 bytes ≈ 1 MB JSON payload.
    MAX_BATCH_SIZE = 5_000

    Result = Struct.new(:ingested_count, :rejected, :batch_id, keyword_init: true) do
      def success?
        ingested_count.positive? || rejected.empty?
      end
    end

    def self.call(account:, ipfix_collector:, records:)
      new(account: account, ipfix_collector: ipfix_collector, records: records).call
    end

    def initialize(account:, ipfix_collector:, records:)
      @account = account
      @ipfix_collector = ipfix_collector
      @records = Array(records)
    end

    def call
      raise ArgumentError, "account is required"        if @account.nil?
      raise ArgumentError, "ipfix_collector is required" if @ipfix_collector.nil?
      raise ArgumentError, "records exceed MAX_BATCH_SIZE (#{MAX_BATCH_SIZE})" if @records.size > MAX_BATCH_SIZE

      now = Time.current
      rows = []
      rejected = []

      @records.each_with_index do |raw, idx|
        attrs, error = normalize_record(raw, default_observed_at: now)
        if error
          rejected << { index: idx, error: error }
          next
        end
        rows << attrs
      end

      ingested_count = 0
      if rows.any?
        # insert_all returns the affected rows; we sum to stay
        # conservative when the DB silently drops on conflict.
        result = ::Sdwan::FlowSample.insert_all(rows, returning: %i[id])
        ingested_count = result&.length || rows.size
      end

      Result.new(
        ingested_count: ingested_count,
        rejected: rejected,
        batch_id: SecureRandom.uuid
      )
    end

    private

    # Returns [attrs_hash, nil] on success, [nil, error_string] on
    # rejection. Cheap field-by-field validation — anything more
    # expensive (CIDR parsing, etc.) is left to the model layer's
    # bulk-load behavior.
    def normalize_record(raw, default_observed_at:)
      r = raw.is_a?(Hash) ? raw : raw.to_h

      src_ip = (r[:src_ip] || r["src_ip"]).to_s.strip
      return [ nil, "src_ip is required" ]            if src_ip.empty?

      dst_ip = (r[:dst_ip] || r["dst_ip"]).to_s.strip
      return [ nil, "dst_ip is required" ]            if dst_ip.empty?

      protocol = (r[:protocol] || r["protocol"]).to_i
      unless protocol.between?(::Sdwan::FlowSample::PROTOCOL_MIN, ::Sdwan::FlowSample::PROTOCOL_MAX)
        return [ nil, "protocol must be 0-255" ]
      end

      src_port = optional_port(r[:src_port] || r["src_port"])
      return [ nil, "src_port out of range" ] if src_port == :invalid

      dst_port = optional_port(r[:dst_port] || r["dst_port"])
      return [ nil, "dst_port out of range" ] if dst_port == :invalid

      octet_count  = (r[:octet_count]  || r["octet_count"]  || 0).to_i
      packet_count = (r[:packet_count] || r["packet_count"] || 0).to_i
      return [ nil, "octet_count must be >= 0" ]  if octet_count.negative?
      return [ nil, "packet_count must be >= 0" ] if packet_count.negative?

      flow_start_at = parse_time(r[:flow_start_at] || r["flow_start_at"])
      return [ nil, "flow_start_at is required and must parse" ] unless flow_start_at

      flow_end_at = parse_time(r[:flow_end_at] || r["flow_end_at"])
      return [ nil, "flow_end_at is required and must parse" ] unless flow_end_at

      observed_at = parse_time(r[:observed_at] || r["observed_at"]) || default_observed_at

      [ {
        id: SecureRandom.uuid,
        account_id: @account.id,
        ipfix_collector_id: @ipfix_collector.id,
        src_ip: src_ip,
        dst_ip: dst_ip,
        src_port: src_port,
        dst_port: dst_port,
        protocol: protocol,
        octet_count: octet_count,
        packet_count: packet_count,
        flow_start_at: flow_start_at,
        flow_end_at: flow_end_at,
        observed_at: observed_at,
        created_at: default_observed_at,
        updated_at: default_observed_at
      }, nil ]
    end

    # Returns nil for blank/nil port (legitimate for ICMP), :invalid
    # for out-of-range, integer otherwise.
    def optional_port(raw)
      return nil if raw.nil? || raw.to_s.strip.empty?

      i = raw.to_i
      return :invalid unless i.between?(::Sdwan::FlowSample::PORT_MIN, ::Sdwan::FlowSample::PORT_MAX)

      i
    end

    def parse_time(raw)
      return raw if raw.is_a?(Time) || raw.is_a?(ActiveSupport::TimeWithZone)
      return nil if raw.nil? || raw.to_s.strip.empty?

      Time.parse(raw.to_s).utc
    rescue ArgumentError
      nil
    end
  end
end
