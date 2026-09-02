# frozen_string_literal: true

require "rails_helper"

# IMP-1e2e7b43b083 — `system_node_instances.lifecycle_class` was a DIFFERENT
# AXIS wearing a name that already meant something else.
#
# IMP-2fc66d5b7e00 established the two facts: system_nodes vs
# system_instance_pools is deliberate LAYERING (the pool value space is a
# correct strict subset of the node one, and
# `InstancePoolService#provision_warming_member!` depends on that relation),
# while system_node_instances was the ACCIDENT — its only value, "task_scoped",
# answers "why was this instance leased", not "how long-lived is this machine",
# and would violate the CHECK constraint standing on EITHER sibling table. That
# task could only document the divergence at the write site, because a rename is
# a schema change beyond its brief. This is the rename: the column, its partial
# index, the one writer, the two readers, and the serializer key all move to
# `lease_class`.
#
# WHAT THIS GUARD CAN SEE:
#   - the accident coming back anywhere in the schema, by EQUALITY: exactly two
#     tables may carry a `lifecycle_class` column, and they are named here. A
#     containment assertion ("system_node_instances is not among them") would
#     stay green if a fourth table acquired one.
#   - the column or the partial index failing to move (both are asserted on the
#     LIVE database, not on schema.rb, which is core-only and lags extension
#     columns by construction — see System::SchemaDriftDetector).
#   - the index predicate being left pointing at the old name: renaming the
#     column in Postgres rewrites the predicate, so a hand-rolled
#     add_index/remove_index pair that forgot it reddens here.
#   - any site re-associating the OLD name with the lease value. Every line
#     under server/app or server/spec carrying both tokens is counted per file
#     and compared for EQUALITY against ALLOWED_OLD_NAME_LINES below (the two
#     sibling-rejection examples), so a new stale line reddens even in a file
#     that already appears there. Paired with a PRESENCE assertion naming the
#     three app/ sites, so satisfying the absence half by DELETING the lease
#     logic fails too.
#   - the writer, both readers and the serializer, driven for real.
#
# WHAT IT CANNOT SEE:
#   - the two SIBLING columns' value spaces. Those are guarded by
#     spec/models/system/lifecycle_class_value_space_spec.rb, which is the file
#     that must move with this one if a value space legitimately changes.
#   - a NEW writer of the lease column added outside the four sites listed
#     below; the co-occurrence scan would notice only if it used the old name.
#   - anything in the Go agent or the frontend, neither of which mentions either
#     column (`command grep -rn "lifecycle_class\|lease_class"
#     extensions/system/agent extensions/system/frontend` → only the
#     InstancePools page, which is the POOL column).
module NodeInstanceLeaseClass
  SERVER_ROOT = File.expand_path("../../..", __dir__)

  # Tables that legitimately carry `lifecycle_class` — the layered node/pool
  # pair, and nothing else.
  LIFECYCLE_CLASS_TABLES = %w[system_instance_pools system_nodes].freeze

  # The migrated sites, with the expression each must now carry EXACTLY once.
  MIGRATED_SITES = {
    "app/services/system/fulfillment_advance_orchestrator.rb" =>
      "attrs[:lease_class]",
    "app/services/system/fulfillment_request_sweep_service.rb" =>
      '::System::NodeInstance.where(account_id: @account.id, lease_class: "task_scoped")',
    "app/controllers/api/v1/system/worker_api/fulfillment_controller.rb" =>
      '::System::NodeInstance.where(lease_class: "task_scoped")',
    "app/models/system/fulfillment_request.rb" =>
      '"lease_class" => inst.try(:lease_class),'
  }.freeze

  # Directories scanned for a stale (old-name) lease reference.
  SCAN_DIRS = %w[app spec].freeze

  # The ONLY files allowed to put the old name next to the lease value, with
  # the exact line count each may have. An equality oracle rather than a
  # skip-list: a NEW stale line in an allowed file reddens too. Both entries
  # here assert a SIBLING table REJECTS the value, which is the point of the
  # rename, so they are not stale.
  #   spec/models/system/lifecycle_class_value_space_spec.rb — the System::Node
  #   and System::InstancePool rejection examples (2 lines).
  ALLOWED_OLD_NAME_LINES = {
    "spec/models/system/lifecycle_class_value_space_spec.rb" => 2
  }.freeze

  def self.ruby_files
    SCAN_DIRS.flat_map { |dir| Dir[File.join(SERVER_ROOT, dir, "**", "*.rb")] }.sort
  end

  # [path, lineno, line] for every line associating a token with "task_scoped".
  def self.lines_pairing(token)
    ruby_files.flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, idx|
        next unless line.include?(token) && line.include?("task_scoped")

        [ path.delete_prefix("#{SERVER_ROOT}/"), idx + 1, line.strip ]
      end
    end
  end

  def self.read(rel)
    path = File.join(SERVER_ROOT, rel)
    raise "expected #{rel} to exist under #{SERVER_ROOT}" unless File.exist?(path)

    File.read(path)
  end
end

RSpec.describe "system_node_instances.lease_class (renamed from lifecycle_class)" do
  let(:connection) { ActiveRecord::Base.connection }

  describe "the schema" do
    it "leaves EXACTLY the layered node/pool pair carrying a lifecycle_class column" do
      tables = connection.select_values(<<~SQL.squish)
        SELECT table_name FROM information_schema.columns
        WHERE table_schema = current_schema() AND column_name = 'lifecycle_class'
        ORDER BY table_name
      SQL

      expect(tables).to eq(NodeInstanceLeaseClass::LIFECYCLE_CLASS_TABLES)
    end

    it "carries lease_class on system_node_instances, and no lifecycle_class" do
      names = connection.columns("system_node_instances").map(&:name)

      expect(names).to include("lease_class")
      expect(names).not_to include("lifecycle_class")
    end

    it "leaves the column nullable and unconstrained — it is provenance, not a value space" do
      column = connection.columns("system_node_instances").find { |c| c.name == "lease_class" }

      expect(column).not_to be_nil
      expect(column.null).to be(true)
      expect(column.default).to be_nil
      checks = connection.check_constraints("system_node_instances")
      expect(checks.select { |c| c.expression.to_s.include?("lease_class") }).to be_empty
    end

    it "moves the reaper's partial index onto lease_class, predicate included" do
      index = connection.indexes("system_node_instances")
                        .find { |i| i.name == "idx_node_instances_task_scoped_lease" }

      expect(index).not_to be_nil, "the fulfillment reaper's partial index is gone"
      expect(index.columns).to eq(%w[lease_class lease_expires_at])
      expect(index.where.to_s).to include("lease_class")
      expect(index.where.to_s).not_to include("lifecycle_class")
    end
  end

  describe "the model" do
    it "exposes lease_class and no longer exposes lifecycle_class" do
      instance = ::System::NodeInstance.new

      expect(instance).to respond_to(:lease_class)
      expect(instance).not_to respond_to(:lifecycle_class)
    end

    it "still declares no value space of its own" do
      expect(::System::NodeInstance.const_defined?(:LEASE_CLASSES, false)).to be(false)
      expect(::System::NodeInstance.validators_on(:lease_class)).to be_empty
    end
  end

  describe "the source sites" do
    NodeInstanceLeaseClass::MIGRATED_SITES.each do |rel, expression|
      it "#{rel} carries the migrated expression exactly once" do
        text = NodeInstanceLeaseClass.read(rel)
        occurrences = text.lines.count { |line| line.include?(expression) }

        expect(occurrences).to eq(1),
                               "expected exactly one #{expression.inspect} in #{rel}, found #{occurrences}"
      end
    end

    it "puts the OLD name next to the lease value nowhere but the two rejection examples" do
      counts = NodeInstanceLeaseClass.lines_pairing("lifecycle_class")
                                     .group_by { |path, _line, _src| path }
                                     .transform_values(&:size)

      expect(counts).to eq(NodeInstanceLeaseClass::ALLOWED_OLD_NAME_LINES)
    end

    it "PRESENCE half: the lease logic still exists under the new name in app/" do
      # Absence alone is satisfiable by deleting the lease logic outright, so
      # the writer and both readers are named positively here. Scoped to app/
      # so this spec file cannot satisfy its own presence check.
      files = NodeInstanceLeaseClass.lines_pairing("lease_class")
                                    .map(&:first)
                                    .select { |path| path.start_with?("app/") }

      expect(files.uniq.sort).to eq(%w[
        app/controllers/api/v1/system/worker_api/fulfillment_controller.rb
        app/services/system/fulfillment_advance_orchestrator.rb
        app/services/system/fulfillment_request_sweep_service.rb
      ])
    end
  end

  describe "the migration" do
    let(:file) do
      Dir[File.join(NodeInstanceLeaseClass::SERVER_ROOT, "db", "migrate",
                    "*_rename_lifecycle_class_to_lease_class_on_system_node_instances.rb")].first
    end

    it "exists and renames the column with a reversible operation" do
      expect(file).not_to be_nil, "the rename migration is missing from db/migrate"

      src = File.read(file)
      expect(src).to include("rename_column :system_node_instances, :lifecycle_class, :lease_class")
      # `change` + rename_column is reversible by construction; raw SQL is not.
      expect(src).to match(/^\s*def change$/)
      expect(src).not_to include("execute(")
    end
  end

  # This is the first rename System::SchemaDriftDetector has ever had anything
  # to SUBTRACT. Its rename branch does execute today on a maintainer checkout —
  # one other rename_column is stamped there — but it nets out nothing, because
  # that column was declared inside a create_table block and #scan_source only
  # tracks top-level add_column (schema_drift_detector.rb, the add_column arm of
  # #scan_source). And the branch carries no spec of its own (`command grep -n
  # "rename" spec/services/system/schema_drift_detector_spec.rb` -> 0 lines),
  # which is why this example exists. The detector
  # runs on every boot and shouts about "stamped-but-absent" objects, so a
  # rename it failed to follow would report `system_node_instances.lifecycle_class`
  # missing on every node forever — a permanent false positive on the sole
  # control plane, caused by this migration. Driven against the REAL loaded
  # migration paths and the REAL database, because the defect would live in the
  # interaction between the two migration files, not in either alone.
  describe "the boot-time drift detector follows the rename" do
    it "reports no missing object on system_node_instances" do
      result = ::System::SchemaDriftDetector.run

      expect(result.error).to be_nil
      offenders = Array(result.missing).select { |m| m[:table] == "system_node_instances" }
      expect(offenders).to be_empty
    end
  end

  describe "the writer, readers and serializer, driven for real" do
    let(:account)  { create(:account) }
    let(:platform) { create(:system_node_platform, account: account) }

    let(:instance) do
      template = create(:system_node_template, account: account, node_platform: platform)
      node = create(:system_node, account: account, node_template: template)
      create(:system_node_instance, :running, node: node)
    end

    def fulfillment_request(lease_ttl: 3600)
      ::System::FulfillmentRequest.create_composed!(
        account: account, request: "give me a running memcached instance",
        plan: { "execution" => { "count" => 1, "platform_id" => platform.id } },
        cost_estimate: {}, reused_modules: [], lease_ttl_seconds: lease_ttl
      )
    end

    it "WRITER: FulfillmentAdvanceOrchestrator stamps lease_class on a fresh instance" do
      orchestrator = ::System::FulfillmentAdvanceOrchestrator.new(request: fulfillment_request)
      orchestrator.send(:apply_lease!, instance)

      expect(instance.reload.lease_class).to eq("task_scoped")
      expect(instance.lease_expires_at).to be_present
    end

    it "READER: the sweep reaps a stray lease_class instance past its lease" do
      instance.update!(lease_class: "task_scoped", lease_expires_at: 1.minute.ago)
      allow(::System::ProvisioningService).to receive(:terminate_instance)
        .and_return(instance_double("Result", success?: true))

      ::System::FulfillmentRequestSweepService.run!(account: account)

      expect(::System::ProvisioningService).to have_received(:terminate_instance).with(instance: instance)
    end

    it "READER: the worker-API sweep targets an account reachable ONLY by a live lease" do
      instance.update!(lease_class: "task_scoped", lease_expires_at: 1.hour.from_now)
      controller = ::Api::V1::System::WorkerApi::FulfillmentController.new
      allow(controller).to receive(:params).and_return(ActionController::Parameters.new)

      expect(controller.send(:target_accounts).map(&:id)).to include(account.id)
    end

    it "SERIALIZER: lease_summaries reports the lease under the new key" do
      instance.update!(config: { "fulfillment_lease" => { "task_scoped" => true } },
                       lease_class: "task_scoped", lease_expires_at: 1.hour.from_now)
      request = fulfillment_request
      request.record_instances!([ instance.id ])

      summary = request.lease_summaries.first
      expect(summary["lease_class"]).to eq("task_scoped")
      expect(summary).not_to have_key("lifecycle_class")
    end
  end
end
