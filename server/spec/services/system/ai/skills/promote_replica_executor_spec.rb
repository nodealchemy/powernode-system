# frozen_string_literal: true

require "rails_helper"
require "yaml"

# APO-6 (DR-3) — the PROMOTE half of the postgres cluster_member lane.
#
# modules/postgres-replica has streamed from a parent primary since
# ClusterMemberPgReplicaSetupJob shipped (physical slot + replication role +
# Vault credential, all on the SETUP side). The recovery side was missing
# ENTIRELY: a grep for promote/pg_promote/failover across both postgres module
# manifests, the setup job and PlatformDeploymentOrchestrator returned nothing,
# so the answer to "the primary is gone" was a person with psql.
#
# The oracles below are that lane's contract:
#   1. the promote path EXISTS and cuts the DB VIP over to the replica's peer
#      (the component-per-instance cutover point), rather than editing a config
#      file on a host nothing can reach
#   2. the SPLIT-BRAIN guard is not waivable — a primary the provider still
#      answers for is never promoted around
#   3. the DATA-LOSS bound is DB-resolved and refuses on a missing or stale lag
#      sample, waivable only by an explicit operator input
#   4. the old primary is FENCED (off the VIP, stamped on the peer) and never
#      restarted as primary
#   5. the whole thing is idempotent on operation_id
RSpec.describe System::Ai::Skills::PromoteReplicaExecutor, type: :service do
  let(:account)                { create(:account) }
  let(:node_template)          { create(:system_node_template, account: account) }
  let(:provider_region)        { create(:system_provider_region) }
  let(:provider_instance_type) { create(:system_provider_instance_type) }

  def instance_named(name, status:)
    node = create(:system_node, account: account, node_template: node_template)
    create(:system_node_instance,
           node: node, name: name, variety: "cloud", status: status,
           provider_region: provider_region,
           provider_instance_type: provider_instance_type,
           config: { "cloud_instance_id" => "cloud-#{name}" })
  end

  let!(:primary_instance) { instance_named("pg-primary", status: "error") }
  let!(:replica_instance) { instance_named("pg-replica", status: "running") }

  let(:network) { create(:sdwan_network, account: account) }
  let!(:primary_peer) do
    create(:sdwan_peer, :active, account: account, network: network,
                                 node_instance: primary_instance)
  end
  let!(:replica_peer) do
    create(:sdwan_peer, :active, account: account, network: network,
                                 node_instance: replica_instance)
  end

  # The DB VIP. THE cutover point — the whole reason the promote is a platform
  # action and not a psql session.
  let!(:vip) do
    create(:sdwan_virtual_ip, network: network, account: account,
                              holder_peer_ids: [ primary_peer.id ], state: "active")
  end

  # The replication record ClusterMemberPgReplicaSetupJob stamps, plus the lag
  # sample the promote reads.
  let(:cluster_pg) do
    {
      "slot_name" => "powernode_repl_abc",
      "primary_host" => "10.0.0.9",
      "primary_port" => 5432,
      "state" => "ready",
      "replication_lag_bytes" => 4096,
      "lag_sampled_at" => 30.seconds.ago.iso8601
    }
  end

  let!(:peer) do
    create(:system_federation_peer, :platform, account: account,
           spawn_mode: "cluster_member", spawn_role: "parent",
           metadata: { "node_instance_id" => replica_instance.id,
                       "cluster_pg" => cluster_pg })
  end

  # The module manifests' declared promote/fence contract, as ManifestImportService
  # lands it: one ModuleService row per manifest `services:` entry, metadata verbatim.
  let!(:replica_service) do
    create(:system_module_service,
           node_module: create(:system_node_module, account: account, name: "postgres-replica"),
           name: "pg-replica",
           metadata: {
             "pg_role" => "streaming_replica",
             "promote_command" => "/usr/lib/postgresql/16/bin/pg_ctl -D /var/lib/postgresql/16/replica promote -w -t 60"
           })
  end
  let!(:primary_service) do
    create(:system_module_service,
           node_module: create(:system_node_module, account: account, name: "postgres-primary"),
           name: "postgres",
           metadata: {
             "pg_role" => "postgres_primary",
             "fence_command" => "/usr/bin/pg_ctl -D /var/lib/postgresql/16/main stop -m immediate"
           })
  end

  let(:provider) { instance_double(System::Providers::MockProvider, provider_type: "mock") }

  before do
    allow(System::Providers::Registry).to receive(:for_instance).and_return(provider)
    # The primary is PROVIDER-CONFIRMED DOWN — the only state the promote runs in.
    allow(provider).to receive(:sync_status).and_return({ success: true, status: "error" })
  end

  def run(operation_id: "promote-1", **extra)
    described_class.new(account: account, agent: nil, user: nil)
                   .execute(gated: true,
                            peer_id: peer.id,
                            primary_instance_id: primary_instance.id,
                            replica_instance_id: replica_instance.id,
                            operation_id: operation_id, **extra)
  end

  describe "the promote path that did not exist" do
    it "cuts the DB VIP over to the replica's peer and dispatches the declared promote command" do
      result = run

      expect(result[:success]).to be(true), "executor failed: #{result[:error]}"
      data = result[:data]

      expect(data[:promoted]).to be(true)
      expect(vip.reload.holder_peer_ids).to eq([ replica_peer.id ])
      expect(data[:moved_virtual_ip_ids]).to eq([ vip.id ])

      task = System::Task.find_by(id: data[:promote_task_id])
      expect(task).to be_present
      expect(task.operable).to eq(replica_instance)
      expect(task.options["command"]).to eq(replica_service.metadata["promote_command"])
    end

    it "stamps the replication record so the replica is the primary from now on" do
      run

      cpg = peer.reload.metadata["cluster_pg"]
      expect(cpg["state"]).to eq("promoted")
      expect(cpg["promoted_at"]).to be_present
      expect(cpg["fenced_primary_instance_id"]).to eq(primary_instance.id)
    end

    it "refuses when the replica module declares no promote command" do
      replica_service.update!(metadata: replica_service.metadata.except("promote_command"))

      result = run

      expect(result[:success]).to be(false)
      expect(result[:error]).to match(/promote_command/)
    end
  end

  describe "the split-brain guard (never waivable)" do
    it "refuses while the provider still answers for the primary" do
      allow(provider).to receive(:sync_status).and_return({ success: true, status: "running" })

      result = run(accept_data_loss: true)

      expect(result[:success]).to be(false)
      expect(result[:error]).to match(/primary/i)
      expect(vip.reload.holder_peer_ids).to eq([ primary_peer.id ])
    end

    it "refuses when the provider cannot be read at all rather than assuming the primary is dead" do
      allow(provider).to receive(:sync_status).and_return({ success: false })

      result = run(accept_data_loss: true)

      expect(result[:success]).to be(false)
      expect(vip.reload.holder_peer_ids).to eq([ primary_peer.id ])
    end
  end

  describe "the data-loss bound" do
    it "refuses when the last lag sample is over the configured bound" do
      allow(SiteSetting).to receive(:get).and_call_original
      allow(SiteSetting).to receive(:get).with(described_class::MAX_LAG_BYTES_SETTING).and_return("1024")

      result = run

      expect(result[:success]).to be(false)
      expect(result[:error]).to match(/lag/i)
      expect(vip.reload.holder_peer_ids).to eq([ primary_peer.id ])
    end

    it "refuses when there is NO lag sample rather than assuming a caught-up replica" do
      peer.update!(metadata: peer.metadata.merge("cluster_pg" => cluster_pg.except("replication_lag_bytes", "lag_sampled_at")))

      result = run

      expect(result[:success]).to be(false)
      expect(result[:error]).to match(/lag/i)
    end

    it "refuses on a STALE sample — a lag reading older than the freshness window proves nothing" do
      peer.update!(metadata: peer.metadata.merge("cluster_pg" => cluster_pg.merge("lag_sampled_at" => 3.days.ago.iso8601)))

      result = run

      expect(result[:success]).to be(false)
      expect(result[:error]).to match(/lag/i)
    end

    it "is waived only by an explicit operator input" do
      peer.update!(metadata: peer.metadata.merge("cluster_pg" => cluster_pg.except("replication_lag_bytes", "lag_sampled_at")))

      result = run(accept_data_loss: true)

      expect(result[:success]).to be(true), "executor failed: #{result[:error]}"
      expect(result[:data][:data_loss_accepted]).to be(true)
    end

    it "resolves the bound from the DB with a constant fallback, never a bare literal" do
      allow(SiteSetting).to receive(:get).and_call_original
      allow(SiteSetting).to receive(:get).with(described_class::MAX_LAG_BYTES_SETTING).and_return(nil)

      expect(run[:success]).to be(true)
      expect(described_class::DEFAULT_MAX_LAG_BYTES).to be_positive
    end
  end

  describe "fencing the old primary" do
    it "takes the old primary off the VIP and records the declared fence command" do
      result = run

      expect(vip.reload.holder_peer_ids).not_to include(primary_peer.id)
      expect(result[:data][:fence_command]).to eq(primary_service.metadata["fence_command"])
    end

    it "never issues a restart/start of the old primary" do
      run

      expect(System::Task.where(operable: primary_instance)
                         .where(command: %w[start restart reboot])).to be_empty
    end

    it "does not dispatch a fence to a VM the provider has already destroyed" do
      allow(provider).to receive(:sync_status).and_return({ success: true, status: "terminated" })

      result = run

      expect(result[:success]).to be(true), "executor failed: #{result[:error]}"
      expect(result[:data][:fence_dispatched]).to be(false)
      expect(System::Task.where(operable: primary_instance, command: "ssh_command")).to be_empty
    end
  end

  describe "cutover feasibility" do
    it "refuses before mutating anything when the replica holds no peer on the VIP's network" do
      replica_peer.destroy!

      result = run

      expect(result[:success]).to be(false)
      expect(result[:error]).to match(/peer/i)
      expect(vip.reload.holder_peer_ids).to eq([ primary_peer.id ])
      expect(System::Task.where(command: "ssh_command")).to be_empty
    end

    it "refuses when no VIP resolves at all rather than promoting into a cutover that moves nothing" do
      vip.destroy!

      result = run

      expect(result[:success]).to be(false)
      expect(result[:error]).to match(/cutover point/i)
      expect(System::Task.where(command: "ssh_command")).to be_empty
    end
  end

  describe "idempotency on operation_id" do
    it "replays instead of promoting a second time" do
      first = run
      expect(first[:success]).to be(true), "executor failed: #{first[:error]}"

      # reload FIRST: the executor moved the row, and writing the same value
      # this stale object already holds would be a no-op UPDATE that leaves the
      # promoted holder in place and fakes the assertion below.
      vip.reload.update!(holder_peer_ids: [ primary_peer.id ])
      second = run

      expect(second[:success]).to be(true)
      expect(second[:data][:replayed]).to be(true)
      expect(vip.reload.holder_peer_ids).to eq([ primary_peer.id ])
    end
  end

  describe "the preview an approval card is built from" do
    it "is a SUCCESS carrying the verdict, not a failure" do
      allow(provider).to receive(:sync_status).and_return({ success: true, status: "running" })

      result = run(dry_run: true)

      expect(result[:success]).to be(true)
      expect(result[:data][:dry_run]).to be(true)
      expect(result[:data][:blocked]).to be(true)
      expect(result[:data][:would_move_virtual_ip_ids]).to eq([ vip.id ])
    end
  end

  describe "the operator control" do
    it "is approval-gated on its own action_category" do
      expect(described_class.gate_required?).to be(true)
      expect(described_class.action_category).to eq("system.replica_promote")
    end
  end

  # ── review-driven oracles (finalize pass) ────────────────────────────────
  #
  # Each of these pins a defect the independent review found in the first cut,
  # not a restatement of the finding. They are the reason the class can be
  # trusted to REFUSE rather than to half-apply.

  describe "a cutover that does not apply is never reported as a promote" do
    # The first cut wrote `moved << vip.id if vip.save` and dropped the false
    # branch, so an Sdwan::VirtualIp that failed validation was silently
    # skipped while the promotion stamp committed and pg_ctl was dispatched:
    # `promoted: true` with the fenced primary still holding the name.
    it "rolls the whole promote back when a VIP write is rejected" do
      allow_any_instance_of(Sdwan::VirtualIp).to receive(:save!)
        .and_raise(ActiveRecord::RecordInvalid.new(Sdwan::VirtualIp.new))

      result = run

      expect(result[:success]).to be(false)
      expect(result[:error]).to match(/virtual ip|vip/i)
      expect(vip.reload.holder_peer_ids).to eq([ primary_peer.id ])
      expect(peer.reload.metadata["cluster_pg"]["state"]).to eq("ready")
      expect(System::Task.where(command: "ssh_command")).to be_empty
      expect(System::FleetEvent.where(account_id: account.id)).to be_empty
    end
  end

  describe "the peer must name the cluster being promoted" do
    # The lag sample is the only WAIVABLE safety evidence, and it is read off
    # the caller-supplied peer. Nothing correlated that peer with the two
    # instance ids, so a caught-up peer from an unrelated cluster_member spawn
    # satisfied the gate for a badly-lagging replica.
    it "refuses a peer that describes a different replica" do
      other = instance_named("pg-replica-elsewhere", status: "running")
      peer.update!(metadata: peer.metadata.merge("node_instance_id" => other.id))

      result = run

      expect(result[:success]).to be(false)
      expect(result[:error]).to match(/does not describe|node_instance_id/i)
      expect(vip.reload.holder_peer_ids).to eq([ primary_peer.id ])
    end

    it "refuses a peer that does not identify a replica at all" do
      peer.update!(metadata: { "cluster_pg" => cluster_pg })

      result = run(accept_data_loss: true)

      expect(result[:success]).to be(false)
      expect(result[:error]).to match(/node_instance_id/i)
    end

    it "refuses a peer whose spawn_role is not the parent that stamps cluster_pg" do
      peer.update!(spawn_role: "child")

      result = run

      expect(result[:success]).to be(false)
      expect(result[:error]).to match(/spawn_role/i)
    end

    it "refuses when the primary and the replica are the same host" do
      result = described_class.new(account: account, agent: nil, user: nil)
                             .execute(gated: true,
                                      peer_id: peer.id,
                                      primary_instance_id: replica_instance.id,
                                      replica_instance_id: replica_instance.id,
                                      operation_id: "same-host")

      expect(result[:success]).to be(false)
      expect(result[:error]).to match(/same/i)
    end
  end

  describe "an ambiguous role declaration is loud, not nondeterministic" do
    # `role` was an unnamespaced token resolved account-wide with .first on an
    # unordered relation: a second module declaring the same role handed its
    # command to a postgres fence, and which one won was undefined.
    it "refuses when two modules declare the same pg_role with different commands" do
      create(:system_module_service,
             node_module: create(:system_node_module, account: account, name: "postgres-replica-fork"),
             name: "pg-replica-fork",
             metadata: { "pg_role" => "streaming_replica",
                         "promote_command" => "/usr/lib/postgresql/17/bin/pg_ctl -D /srv/pg promote" })

      result = run

      expect(result[:success]).to be(false)
      expect(result[:error]).to match(/more than one|ambiguous/i)
      expect(vip.reload.holder_peer_ids).to eq([ primary_peer.id ])
    end
  end

  describe "the idempotency ledger is written with the cutover, not after it" do
    # record_step! ran after the tasks were dispatched and outside the
    # transaction, so a crash in between moved the VIP, dispatched pg_ctl and
    # left NO replay marker — the next drive promoted a second time.
    it "leaves no applied-but-unrecorded promote when the dispatch raises" do
      allow(System::Task).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "boom")

      result = run

      expect(result[:success]).to be(false)
      expect(vip.reload.holder_peer_ids).to eq([ primary_peer.id ])
      expect(peer.reload.metadata["cluster_pg"]["state"]).to eq("ready")
      expect(System::FleetEvent.where(account_id: account.id)).to be_empty
    end

    it "records the ledger event in the same transaction as the cutover" do
      run

      event = System::FleetEvent.find_by(account_id: account.id,
                                         kind: "#{described_class::EVENT_PREFIX}.promote")
      expect(event).to be_present
      expect(event.payload["moved_virtual_ip_ids"]).to eq([ vip.id ])
      expect(event.payload["promote_task_id"]).to be_present
    end
  end

  describe "the split-brain reading cannot drift from the sensor it copies" do
    # The class comment promises the provider reading is the one
    # InstanceUnrecoverableSensor makes. A duplicated constant makes that a
    # claim nothing enforces.
    it "shares the sensor's terminal-state list rather than restating it" do
      expect(described_class::TERMINAL_PROVIDER_STATES)
        .to equal(System::Fleet::Sensors::InstanceUnrecoverableSensor::TERMINAL_PROVIDER_STATES)
    end
  end

  describe "the declared fence command must exist on the module that runs it" do
    # /usr/bin/pg_ctl is NOT in postgres-primary's file inventory (the Debian
    # layout ships it under /usr/lib/postgresql/<major>/bin), so the first cut's
    # fence would have failed command-not-found on every node — silently, since
    # the dispatch is best-effort and never inspects the task outcome.
    it "postgres-primary's fence binary is covered by the module's own file_spec" do
      manifest = YAML.safe_load_file(
        File.join(File.expand_path("../../../../../..", __dir__),
                  "modules/postgres-primary/manifest.yaml"), aliases: true
      )
      svc  = manifest.fetch("services").find { |s| s["name"] == "postgres" }
      binary = svc.fetch("metadata").fetch("fence_command").split.first
      files  = Array(manifest["file_spec"])

      covered = files.any? do |entry|
        entry == binary || (entry.end_with?("/**") && binary.start_with?(entry.delete_suffix("**")))
      end

      expect(covered).to be(true),
                         "fence_command runs #{binary}, which no entry in the manifest's file_spec " \
                         "delivers: #{files.grep(%r{pg_ctl|usr/lib/postgresql}).inspect}"
    end
  end

  # The finding's own evidence: the manifests declared NO promote/fence
  # mechanism, so the executor had nothing to read and the agent had nothing
  # to run. These pin the declaration the executor resolves.
  describe "the module manifests declare the mechanism" do
    extension_root = File.expand_path("../../../../../..", __dir__)

    def service_metadata(manifest_path, service_name)
      manifest = YAML.safe_load_file(manifest_path, aliases: true)
      svc = manifest.fetch("services").find { |s| s["name"] == service_name }
      raise "no #{service_name} service in #{manifest_path}" unless svc

      svc["metadata"] || {}
    end

    it "postgres-replica declares how to promote" do
      meta = service_metadata(File.join(extension_root, "modules/postgres-replica/manifest.yaml"),
                              "pg-replica")

      expect(meta["pg_role"]).to eq("streaming_replica")
      expect(meta["promote_command"]).to be_present
    end

    it "postgres-primary declares how to fence" do
      meta = service_metadata(File.join(extension_root, "modules/postgres-primary/manifest.yaml"),
                              "postgres")

      expect(meta["pg_role"]).to eq("postgres_primary")
      expect(meta["fence_command"]).to be_present
    end
  end
end
