# frozen_string_literal: true

require "rails_helper"

# IMP-5a018031cc29 — the actuation half.
#
# `Sdwan::Executors::CreateIpfixCollector` used to write one row and stop. The
# OVS exporter config compiled, the ingest endpoint accepted POSTs, the
# retention sweep ran — and nothing ever put a producer on a host, so the
# collector was an endpoint with no exporter behind it.
#
# The deployer closes that by assigning the seeded `sdwan-flow-exporter`
# NodeModule to the nodes that must run it, and — just as importantly —
# REPORTING the hosts it deliberately skipped. A lightweight host is not a
# failure to deploy; it is a host where the capability does not exist. The two
# must never collapse into one silent "nothing happened".
RSpec.describe Sdwan::FlowExporterDeployer do
  let(:account) { create(:account) }

  def host(profile:)
    node = create(:system_node, account: account)
    create(:system_node_instance,
           account: account, node: node, network_profile: profile, status: "running")
  end

  def bridge!(instance, kind:)
    create(:sdwan_host_bridge, account: account, node_instance: instance, kind: kind, state: "active")
  end

  # `built:` mirrors the real lifecycle: seeding the catalog row does NOT
  # produce an artifact — an operator builds and publishes separately, which is
  # why the default here is unbuilt. Examples that care about a working
  # producer opt in.
  def seed_module!(built: false)
    mod = System::NodeModule.create!(
      account: account,
      name: Sdwan::FlowExportCoverage::MODULE_NAME,
      variety: "subscription",
      enabled: true
    )
    if built
      version = create(:system_node_module_version, node_module: mod)
      mod.update!(current_version: version, current_version_number: version.version_number)
    end
    mod
  end

  def assigned_node_ids
    System::NodeModuleAssignment
      .joins(:node_module)
      .where(system_node_modules: { name: Sdwan::FlowExportCoverage::MODULE_NAME })
      .pluck(:node_id)
  end

  context "with a host-local collector and the module seeded" do
    let!(:mod) { seed_module! }
    let!(:heavy) { host(profile: "heavyweight").tap { |h| bridge!(h, kind: "ovs") } }
    let!(:light) { host(profile: "lightweight").tap { |h| bridge!(h, kind: "linux") } }
    let!(:collector) { create(:sdwan_ipfix_collector, account: account, host: "127.0.0.1") }

    it "assigns the producer module to the ovs-capable node only" do
      described_class.ensure_deployed!(account: account)

      expect(assigned_node_ids).to contain_exactly(heavy.node_id)
    end

    it "names the skipped lightweight host as UNSUPPORTED rather than silently omitting it" do
      report = described_class.ensure_deployed!(account: account)

      expect(report[:deployed_node_ids]).to eq([ heavy.node_id ])
      expect(report[:unsupported_exporters]).to contain_exactly(
        hash_including(node_instance_id: light.id, reason: "linux_bridge_only")
      )
      expect(report[:module_present]).to be(true)
    end

    # A count-only assertion passes unchanged if attach! were deleted outright,
    # so assert the RESULT on both runs, not the delta.
    it "is idempotent — a second run leaves the same single assignment" do
      described_class.ensure_deployed!(account: account)
      expect(assigned_node_ids).to eq([ heavy.node_id ])

      expect { described_class.ensure_deployed!(account: account) }
        .not_to change(System::NodeModuleAssignment, :count)
      expect(assigned_node_ids).to eq([ heavy.node_id ])
    end

    # An unbuilt module still gets attached — attaching is what makes the
    # artifact land once it is published — but the report must not let that
    # read as a working pipe.
    it "says the producer is attached but not yet built" do
      report = described_class.ensure_deployed!(account: account)

      expect(report[:producer_built]).to be(false)
      expect(report[:refusal]).to include("no published version")
    end

    it "drops the advisory once the module carries a published version" do
      version = create(:system_node_module_version, node_module: mod)
      mod.update!(current_version: version, current_version_number: version.version_number)

      report = described_class.ensure_deployed!(account: account)

      expect(report[:producer_built]).to be(true)
      expect(report[:refusal]).to be_nil
    end

    # B1 — an operator disabled the assignment. A create-collector call is not
    # consent to undo that, and claiming it as deployed would be a false
    # actuation claim.
    it "neither re-enables nor claims a DISABLED assignment" do
      described_class.ensure_deployed!(account: account)
      assignment = System::NodeModuleAssignment.find_by!(node_id: heavy.node_id, node_module_id: mod.id)
      assignment.update!(enabled: false)

      report = described_class.ensure_deployed!(account: account)

      expect(assignment.reload.enabled).to be(false)
      expect(report[:deployed_node_ids]).to eq([])
    end
  end

  context "when the producer module has not been seeded" do
    let!(:heavy) { host(profile: "heavyweight").tap { |h| bridge!(h, kind: "ovs") } }
    let!(:collector) { create(:sdwan_ipfix_collector, account: account, host: "127.0.0.1") }

    # A missing module is an OPERATOR-VISIBLE refusal, not an exception and not
    # a shrug. The collector still gets created (the executor must not fail on
    # it), but the report says plainly that no producer exists to deploy.
    it "refuses with module_present: false instead of raising" do
      report = described_class.ensure_deployed!(account: account)

      expect(report[:module_present]).to be(false)
      expect(report[:deployed_node_ids]).to eq([])
      expect(report[:refusal]).to include(Sdwan::FlowExportCoverage::MODULE_NAME)
    end
  end

  # S2 — the one placement that can attach the producer to a node with no OVS
  # bridge of its own. That is CORRECT: in fleet_host placement the module runs
  # as the collector, receiving flow records rather than producing them. The
  # point of the example is that the report's two lists mean different things
  # and are allowed to name the same node — `deployed_node_ids` is "the
  # producer was attached here", `unsupported_exporters` is "this host can
  # never export".
  context "with a central collector on a lightweight fleet host" do
    let!(:mod) { seed_module!(built: true) }
    let!(:heavy) { host(profile: "heavyweight").tap { |h| bridge!(h, kind: "ovs") } }
    let!(:collector_host) { host(profile: "lightweight").tap { |h| bridge!(h, kind: "linux") } }
    let!(:network) { create(:sdwan_network, account: account) }
    let!(:peer) do
      create(:sdwan_peer, account: account, network: network,
             node_instance: collector_host, assigned_address: "fd00:abcd:1::7")
    end
    let!(:collector) { create(:sdwan_ipfix_collector, account: account, host: "fd00:abcd:1::7") }

    it "attaches the producer to the collector's node, not to the exporting node" do
      report = described_class.ensure_deployed!(account: account)

      expect(report[:placement]).to eq("fleet_host")
      expect(assigned_node_ids).to eq([ collector_host.node_id ])
      expect(report[:deployed_node_ids]).to eq([ collector_host.node_id ])
    end

    it "still reports the collector host as unable to EXPORT" do
      report = described_class.ensure_deployed!(account: account)

      expect(report[:unsupported_exporters]).to contain_exactly(
        hash_including(node_instance_id: collector_host.id, reason: "linux_bridge_only")
      )
      # The same node in both lists is the point: the keys are not synonyms.
      expect(report[:deployed_node_ids]).to include(collector_host.node_id)
    end

    it "leaves the OVS host depending on that one producer rather than its own" do
      described_class.ensure_deployed!(account: account)

      expect(Sdwan::FlowExportCoverage.for_account(account).fetch(heavy.id)[:state]).to eq("stalled")
    end
  end

  context "with an off-fleet collector target" do
    let!(:mod) { seed_module! }
    let!(:heavy) { host(profile: "heavyweight").tap { |h| bridge!(h, kind: "ovs") } }
    let!(:collector) { create(:sdwan_ipfix_collector, account: account, host: "198.51.100.7") }

    it "deploys nothing and says the collector is operator-run" do
      report = described_class.ensure_deployed!(account: account)

      expect(report[:placement]).to eq("external")
      expect(assigned_node_ids).to eq([])
      expect(report[:refusal]).to be_present
    end
  end

  context "with no active collector" do
    let!(:mod) { seed_module! }
    let!(:heavy) { host(profile: "heavyweight").tap { |h| bridge!(h, kind: "ovs") } }

    it "deploys nothing — there is no exporter target to point at yet" do
      report = described_class.ensure_deployed!(account: account)

      expect(report[:placement]).to eq("unconfigured")
      expect(assigned_node_ids).to eq([])
    end
  end

  describe "the create executor" do
    let!(:mod) { seed_module! }
    let!(:heavy) { host(profile: "heavyweight").tap { |h| bridge!(h, kind: "ovs") } }
    let!(:light) { host(profile: "lightweight").tap { |h| bridge!(h, kind: "linux") } }

    # This is the red-first assertion for the whole task: creating a collector
    # must ACTUATE the producer, not just register an endpoint.
    it "deploys the producer and returns the coverage report" do
      operation = ::Ai::DeferredOperation.create!(
        account: account,
        action_category: Sdwan::Executors::CreateIpfixCollector::ACTION_CATEGORY,
        executor_class: "Sdwan::Executors::CreateIpfixCollector",
        params: {}
      )

      result = Sdwan::Executors::CreateIpfixCollector.execute(
        { name: "local", host: "127.0.0.1", port: 4739 },
        deferred_operation: operation
      )

      expect(result[:success]).to be(true)
      expect(assigned_node_ids).to eq([ heavy.node_id ])

      deployment = result.dig(:data, :flow_exporter_deployment)
      expect(deployment[:deployed_node_ids]).to eq([ heavy.node_id ])
      expect(deployment[:unsupported_exporters].first).to include(node_instance_id: light.id)
    end
  end
end
