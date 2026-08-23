# frozen_string_literal: true

module Sdwan
  module Executors
    # Executor for `sdwan.ipfix_collector_create` (IMP-97c7b4123d8f).
    #
    # IMP-5a018031cc29 — this used to write one row and stop. Creating the row
    # makes Sdwan::TopologyCompiler stamp an `ipfix:` exporter block onto every
    # ovs-kind HostBridge in the account, so from that moment OVS is exporting
    # flow records at a target address. Nothing in the platform put a producer
    # behind that address: the sidecar the architecture requires was deployed
    # by no seed, no agent component and no provisioner. The action therefore
    # registered an endpoint nothing exported to, and every consumer saw the
    # same emptiness a DEAD exporter produces.
    #
    # It now actuates the producer half too, and — as important — reports the
    # hosts where the capability genuinely does not exist. Lightweight
    # (Linux-bridge) hosts cannot export IPFIX at all; they come back under
    # `unsupported` with a reason rather than being silently omitted, so an
    # operator reading the result can tell "unavailable here" from "should be
    # working and isn't".
    #
    # The deployment is a best-effort ATTACHMENT, never a gate: a fleet with no
    # OVS host, an unseeded producer module or an operator-run off-fleet
    # collector all still create the collector, and say plainly in
    # `flow_exporter_deployment[:refusal]` why nothing was attached. Failing
    # the create would be worse — the collector row is also what an external
    # collector needs in order to have an ingest endpoint at all.
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

        {
          collector_id: collector.id,
          name: collector.name,
          flow_exporter_deployment: deploy_producer
        }
      end

      def summarize = "Create IPFIX collector #{params[:name]}"

      # Rendered on a HUMAN approval card, so it must describe the write that
      # will actually happen. Where the producer lands depends on the collector
      # target (host-local vs a named fleet host vs operator-run), which is not
      # known until the row exists — so this states the RULE rather than naming
      # a node count it cannot yet compute. An earlier wording promised "every
      # OVS-capable node", which is true only of the host-local placement.
      def impact
        "Points flow export at a collector endpoint and attaches the " \
        "#{::Sdwan::FlowExportCoverage::MODULE_NAME} producer module wherever the collector target " \
        "resolves (every OVS-capable node for a host-local target, one named node for a fleet " \
        "target, nothing for an operator-run collector). Hosts that cannot export IPFIX at all — " \
        "lightweight Linux-bridge hosts — are reported as unavailable rather than skipped silently"
      end

      private

      # A producer-attachment failure must not lose the collector the operator
      # just asked for, nor be swallowed. The error is returned IN the report,
      # where the same reader who sees the collector id sees why no producer
      # went with it.
      # The failure is LOGGED as well as returned: System::Executors::Base logs
      # only on re-raise, so a swallowed error here would otherwise leave no
      # server-side trace of a producer that never got attached.
      #
      # `placement` and `module_present` keep their documented domains
      # (Sdwan::FlowExportCoverage::Placement's modes, and a boolean) — an
      # earlier form overloaded them with "error"/nil, which forced every
      # consumer switching on placement to carry an undocumented arm. The
      # failure gets its own key instead.
      def deploy_producer
        ::Sdwan::FlowExporterDeployer.ensure_deployed!(account: account)
      rescue StandardError => e
        Rails.logger.error(
          "[CreateIpfixCollector] producer deployment failed for account=#{account&.id}: " \
          "#{e.class}: #{e.message}"
        )
        {
          placement: nil,
          module_present: nil,
          producer_built: nil,
          deployed_node_ids: [],
          unsupported_exporters: [],
          refusal: nil,
          error: "producer deployment failed: #{e.class}: #{e.message}"
        }
      end
    end
  end
end
