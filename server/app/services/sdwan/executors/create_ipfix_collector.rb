# frozen_string_literal: true

module Sdwan
  module Executors
    # Executor for `sdwan.ipfix_collector_create` (IMP-97c7b4123d8f).
    class CreateIpfixCollector < ::System::Executors::Base
      ACTION_CATEGORY = "sdwan.ipfix_collector_create"

      protected

      def perform
        collector = ::Sdwan::IpfixCollector.create!(
          account: account,
          name: params[:name],
          host: params[:host],
          port: params[:port].present? ? params[:port].to_i : 4739,
          sampling_rate: params[:sampling_rate].present? ? params[:sampling_rate].to_i : 1
        )
        { collector_id: collector.id, name: collector.name }
      end

      def summarize = "Create IPFIX collector #{params[:name]}"
      def impact    = "Points flow export at a collector endpoint"
    end
  end
end
