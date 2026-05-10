# frozen_string_literal: true

# Operator-facing read API + sidecar-facing ingest API for
# Sdwan::FlowSample. Nested under ipfix_collectors — every flow record
# is attributed to one collector even when batches arrive from multiple
# sidecars (each sidecar carries its own collector_id).
#
# Recommended sidecar config (vector example, comment-only):
#
#   [sources.ovs_ipfix]
#     type = "netflow"
#     mode = "udp"
#     address = "0.0.0.0:4739"
#     version = "ipfix"
#
#   [sinks.powernode]
#     type = "http"
#     inputs = ["ovs_ipfix"]
#     uri = "https://platform.example/api/v1/system/sdwan/ipfix_collectors/<COLLECTOR_ID>/flow_samples"
#     method = "post"
#     auth.strategy = "bearer"
#     auth.token = "<JWT with sdwan.ipfix.ingest>"
#     batch.max_events = 5000
#
# Phase O6 follow-up of the OVS+OVN dual-profile networking roadmap.
module Api
  module V1
    module System
      module Sdwan
        class FlowSamplesController < ::Api::V1::System::BaseController
          before_action :set_account
          before_action :set_collector

          def index
            require_permission("sdwan.ipfix.read")

            scope = ::Sdwan::FlowSample.for_account(@account)
                                       .for_collector(@collector)
                                       .recent
            scope = scope.since(parse_time_param(params[:since]))            if params[:since].present?
            scope = scope.until_time(parse_time_param(params[:until]))       if params[:until].present?
            scope = scope.where(protocol: params[:protocol].to_i)            if params[:protocol].present?

            limit = [ params.fetch(:limit, 100).to_i.clamp(1, 1000), 1000 ].min
            samples = scope.limit(limit).to_a

            render_success(
              flow_samples: samples.map { |s| serialize_sample(s) },
              count: samples.size,
              filters: {
                since: params[:since],
                until: params[:until],
                protocol: params[:protocol],
                limit: limit
              }.compact
            )
          end

          def create
            require_permission("sdwan.ipfix.ingest")

            records = params.dig(:flow_samples) || params[:records] || []
            unless records.is_a?(Array)
              return render_error("flow_samples must be an array", status: :unprocessable_entity)
            end

            result = ::Sdwan::IpfixIngestService.call(
              account: @account,
              ipfix_collector: @collector,
              records: records.map(&:to_unsafe_h)
            )

            render_success(
              ingested_count: result.ingested_count,
              rejected_count: result.rejected.size,
              rejected: result.rejected,
              batch_id: result.batch_id
            )
          rescue ArgumentError => e
            render_error(e.message, status: :unprocessable_entity)
          end

          private

          def set_collector
            @collector = ::Sdwan::IpfixCollector
                           .for_account(@account)
                           .find(params[:ipfix_collector_id])
          rescue ActiveRecord::RecordNotFound
            render_not_found("SDWAN IPFIX Collector")
          end

          def parse_time_param(raw)
            Time.parse(raw.to_s)
          rescue ArgumentError
            nil
          end

          def serialize_sample(s)
            {
              id: s.id,
              src_ip: s.src_ip.to_s,
              dst_ip: s.dst_ip.to_s,
              src_port: s.src_port,
              dst_port: s.dst_port,
              protocol: s.protocol,
              protocol_label: s.protocol_label,
              octet_count: s.octet_count,
              packet_count: s.packet_count,
              flow_start_at: s.flow_start_at.iso8601,
              flow_end_at: s.flow_end_at.iso8601,
              observed_at: s.observed_at.iso8601
            }
          end
        end
      end
    end
  end
end
