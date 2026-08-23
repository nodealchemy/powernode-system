# frozen_string_literal: true

module Sdwan
  # Sdwan::FlowExporterDeployer — attaches the seeded `sdwan-flow-exporter`
  # NodeModule to the machines that must run it, and reports the machines it
  # deliberately did not. (IMP-5a018031cc29)
  #
  # `Sdwan::Executors::CreateIpfixCollector` used to write one row and stop:
  # the compiler would start stamping exporter config onto every ovs bridge in
  # the account, the ingest endpoint stood ready, and no host anywhere ran a
  # producer. This is the missing rung.
  #
  # TWO THINGS IT MUST NEVER DO
  # ---------------------------
  # 1. Treat a host that cannot EXPORT IPFIX as one that should be exporting.
  #    A Linux bridge has no exporter, so such a host would look configured and
  #    report nothing forever — the exact failure this work exists to end.
  #    Those hosts come back under `unsupported_exporters`, by id and reason,
  #    so the caller can say "unavailable here" rather than staying quiet.
  #
  #    Note the asymmetry, because it is deliberate: exporting and COLLECTING
  #    are different jobs. In :host_local placement the producer is attached to
  #    exactly the OVS-capable nodes. In :fleet_host placement the collector
  #    lives on one named machine — the peer the operator pointed the collector
  #    at — and that machine need not be OVS-capable at all, because it
  #    RECEIVES flow records rather than producing them. So a node can
  #    legitimately appear in `deployed_node_ids` (it hosts the collector) and
  #    in `unsupported_exporters` (it exports nothing of its own). The key name
  #    carries that distinction; `unsupported` alone read as a contradiction.
  # 2. Raise when the producer module has not been seeded (or built). A
  #    collector create must still succeed; the operator gets an explicit
  #    `module_present: false` refusal naming what to seed, not a 500.
  #
  # It also never builds or publishes anything. Attaching a catalog row to a
  # node is a DB write; producing the artifact is a separate operator action
  # (see db/seeds/sdwan_flow_exporter_module.rb for the exact steps) because
  # publishing auto-promotes on this platform.
  class FlowExporterDeployer
    MODULE_NAME = ::Sdwan::FlowExportCoverage::MODULE_NAME

    # Priority the assignment carries. Mirrors the module's own catalog
    # priority so an operator reading the node's module list sees the exporter
    # ordered after the overlay that produces the flows it decodes.
    ASSIGNMENT_PRIORITY = 110

    def self.ensure_deployed!(account:)
      new(account: account).ensure_deployed!
    end

    def initialize(account:)
      @account = account
    end

    def ensure_deployed!
      coverage = ::Sdwan::FlowExportCoverage.new(@account)
      placement = coverage.placement
      report = base_report(coverage, placement)

      return report.merge(refusal: "no active Sdwan::IpfixCollector for this account; nothing to point a producer at") if placement.mode == :unconfigured
      return report.merge(refusal: "collector target #{placement.collector&.target_endpoint} is not a machine this platform manages — the collector there is operator-run") if placement.mode == :external

      node_module = producer_module
      if node_module.nil?
        return report.merge(
          module_present: false,
          refusal: "NodeModule '#{MODULE_NAME}' is not seeded for this account — " \
                   "run db/seeds/sdwan_flow_exporter_module.rb, then build and publish it"
        )
      end

      deployed = placement.node_ids.map { |node_id| attach!(node_module, node_id) }.compact

      advisory =
        unless coverage.producer_built?
          "NodeModule '#{MODULE_NAME}' is attached but has no published version — " \
          "build and publish it before expecting flow samples"
        end

      report.merge(module_present: true, deployed_node_ids: deployed.sort, refusal: advisory)
    end

    private

    def base_report(coverage, placement)
      {
        placement: placement.mode.to_s,
        collector_id: placement.collector&.id,
        collector_endpoint: placement.collector&.target_endpoint,
        module_present: producer_module.present?,
        deployed_node_ids: [],
        # Honest unavailability, itemised. A caller that renders only
        # deployed_node_ids would show "nothing happened" for an all-lightweight
        # fleet; this is what makes the absence legible.
        unsupported_exporters: unsupported_hosts(coverage),
        # An attached module with no published version delivers no artifact, so
        # nothing runs. Surfaced here rather than left for the operator to
        # discover as silence — this is the state the fleet is in immediately
        # after the catalog row is seeded and before it is built.
        producer_built: coverage.producer_built?,
        refusal: nil
      }
    end

    def unsupported_hosts(coverage)
      coverage.entries.values.select { |e| e[:state] == "unsupported" }.map do |e|
        {
          node_instance_id: e[:node_instance_id],
          node_id: e[:node_id],
          name: e[:name],
          network_profile: e[:network_profile],
          reason: e[:reason]
        }
      end
    end

    def producer_module
      return @producer_module if defined?(@producer_module)

      @producer_module = ::System::NodeModule.find_by(account_id: @account.id, name: MODULE_NAME)
    end

    # Returns the node_id when an assignment now exists, nil when it could not
    # be created. Idempotent: re-running a collector create must not stack
    # duplicate assignments (the model's uniqueness validation would refuse
    # them anyway, and a refusal is not something a create path should surface
    # as an error).
    # Created directly rather than through System::TemplateApplyService on
    # purpose: the producer is attached in response to a COLLECTOR being
    # created, not because any node template names it, so there is no
    # TemplateModule to record as the source. The row therefore carries
    # source_template_module_id NULL and auto_resolved false, and template
    # reconciliation will neither add nor reap it — which is correct, and is
    # why TemplateClosureDriftSensor (it flags only MISSING closure modules)
    # raises no drift for it.
    def attach!(node_module, node_id)
      existing = ::System::NodeModuleAssignment.find_by(node_id: node_id, node_module_id: node_module.id)

      # A DISABLED row delivers nothing — System::Runtime::SyncModules commits
      # only `enabled` assignments. Reporting it as deployed would claim an
      # actuation that will never happen. It is also not ours to silently
      # re-enable: an operator disabled it deliberately, and a create-collector
      # call is not consent to undo that. So it is left alone and reported as
      # NOT deployed, which surfaces as `undeployed` in the coverage oracle.
      return nil if existing && !existing.enabled?
      return node_id if existing

      ::System::NodeModuleAssignment.create!(
        node_id: node_id,
        node_module_id: node_module.id,
        enabled: true,
        priority: ASSIGNMENT_PRIORITY
      )
      node_id
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      # Lost a race with a concurrent create — the assignment exists, which is
      # all this method promises.
      ::System::NodeModuleAssignment.enabled
                                    .exists?(node_id: node_id, node_module_id: node_module.id) ? node_id : nil
    end
  end
end
