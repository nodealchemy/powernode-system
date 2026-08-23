# frozen_string_literal: true

module Sdwan
  module Executors
    # Executor for `sdwan.ipfix_collector_delete` (IMP-97c7b4123d8f).
    #
    # Destroying a collector cascades its flow_samples, which is why an
    # operator disabling one should update its state rather than delete it.
    class DeleteIpfixCollector < ::System::Executors::Base
      ACTION_CATEGORY = "sdwan.ipfix_collector_delete"

      protected

      def perform
        collector = resolve_scoped(::Sdwan::IpfixCollector, params[:collector_id])
        name = collector.name
        collector.destroy!
        { deleted: true, collector_id: params[:collector_id], name: name }
      end

      def summarize = "Delete IPFIX collector #{(scoped_label_record(::Sdwan::IpfixCollector, params[:collector_id])&.name || params[:collector_id])}"
      def impact    = "Removes the collector and the flow samples recorded against it"
    end
  end
end
