# frozen_string_literal: true

require "rails_helper"

# IMP-054397261461 — MCP wait-for primitive. A session used to poll the ops-hub
# database over ssh+psql to learn that a task, a build batch or a rollout had
# finished. system_get_task and system_get_module_build_batch now take
# wait_seconds (a bounded long-poll), and system_wait_for holds a rollout
# (module version × environment) until the nodes report the version's digest
# running. All three are reads: they never mutate, and an instance principal
# may be granted them.
RSpec.describe Ai::Tools::SystemFleetTool, "wait-for" do
  include ActiveSupport::Testing::TimeHelpers

  let(:account)  { create(:account) }
  let(:platform_record) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform_record) }
  let(:tool) { described_class.new(account: account, internal: true) }

  def call(action, **rest)
    tool.execute(params: { action: action }.merge(rest))
  end

  # Replaces the poll sleep: advances the clock by the requested amount so the
  # deadline arithmetic is exercised for real, without waiting. The block runs
  # once per poll interval and may change state, standing in for the world
  # moving on while the caller is parked.
  def stub_sleep(target = tool, &on_tick)
    @sleeps = []
    allow(target).to receive(:sleep) do |seconds|
      @sleeps << seconds
      travel(seconds.seconds)
      on_tick&.call(@sleeps.size)
    end
  end

  # travel truncates sub-second precision, so a fractional start would let a
  # short final sleep round to no progress; start on a whole second.
  before { travel_to(Time.current.change(usec: 0)) }
  after { travel_back }

  it "polls no faster than the reference wait loop and caps below the tightest in-tree HTTP read timeout" do
    expect(described_class::WAIT_POLL_SECONDS).to eq(2)
    # Mcp::SyncExecutionService reads with a 60s timeout, the smallest of the
    # MCP HTTP timeouts in the codebase; the cap must leave margin under it.
    expect(described_class::WAIT_MAX_SECONDS).to be <= 50
    expect(described_class::WAIT_MAX_SECONDS).to be > described_class::WAIT_POLL_SECONDS
  end

  describe "system_get_task wait_seconds" do
    let(:node) { create(:system_node, account: account, node_template: template, name: "waittask") }
    let!(:task) do
      System::Task.create!(account: account, command: "apply_config", status: "running", progress: 10,
                           operable_type: "System::Node", operable_id: node.id)
    end

    it "keeps the existing response, with no wait keys, when wait_seconds is absent or 0" do
      stub_sleep
      [ {}, { wait_seconds: 0 }, { wait_seconds: "0" } ].each do |extra|
        r = call("system_get_task", task_id: task.id, **extra)
        expect(r[:success]).to be true
        expect(r[:data].keys).to eq([ :task ])
        expect(r[:data][:task][:status]).to eq("running")
      end
      expect(@sleeps).to be_empty
    end

    it "returns immediately, without sleeping, when the task is already terminal" do
      stub_sleep
      task.update!(status: "complete")

      r = call("system_get_task", task_id: task.id, wait_seconds: 30)

      expect(r[:success]).to be true
      expect(r[:data][:task][:status]).to eq("complete")
      expect(r[:data][:timed_out]).to be false
      expect(@sleeps).to be_empty
    end

    it "returns once the task reaches a terminal state mid-wait" do
      stub_sleep { |tick| task.update_columns(status: "failed") if tick == 2 }

      r = call("system_get_task", task_id: task.id, wait_seconds: 30)

      expect(r[:success]).to be true
      expect(r[:data][:task][:status]).to eq("failed")
      expect(r[:data][:timed_out]).to be false
      expect(@sleeps).to eq([ 2, 2 ])
    end

    # The model has no terminal-status constant, only the `finished` scope, so
    # that scope (SQL) is the oracle, not the #finished? the tool calls.
    it "treats every status the model's finished scope holds as done, and no other" do
      stub_sleep
      System::Task::STATUSES.each do |status|
        task.update_columns(status: status)
        r = call("system_get_task", task_id: task.id, wait_seconds: 10)
        finished = System::Task.finished.exists?(id: task.id)
        expect(r[:data][:timed_out]).to be(!finished), "status #{status}"
      end
      expect(System::Task::STATUSES.count { |st| System::Task.finished.where_values_hash["status"].include?(st) }).to eq(4)
    end

    it "times out with timed_out: true and the current snapshot, never an error" do
      stub_sleep

      r = call("system_get_task", task_id: task.id, wait_seconds: 5)

      expect(r[:success]).to be true
      expect(r[:data][:timed_out]).to be true
      expect(r[:data][:task][:status]).to eq("running")
      expect(r[:data][:task][:id]).to eq(task.id)
      expect(@sleeps.sum).to eq(5)
    end

    it "clamps an oversized wait_seconds to the cap" do
      stub_sleep

      r = call("system_get_task", task_id: task.id, wait_seconds: 100_000)

      expect(r[:success]).to be true
      expect(r[:data][:timed_out]).to be true
      expect(r[:data][:wait_seconds]).to eq(described_class::WAIT_MAX_SECONDS)
      expect(@sleeps.sum).to eq(described_class::WAIT_MAX_SECONDS)
    end

    it "still errors on an unknown task and does not wait" do
      stub_sleep

      r = call("system_get_task", task_id: SecureRandom.uuid, wait_seconds: 30)

      expect(r[:success]).to be false
      expect(@sleeps).to be_empty
    end
  end

  describe "system_get_module_build_batch wait_seconds" do
    let(:batch) do
      System::ModuleBuildBatch.create_for(account: account, trigger: "manual", base_sha: "base", head_sha: "head",
                                          source_repo: "powernode/powernode-platform",
                                          plan: [ { module: "mod-x", oci_ref: "abc1234" } ])
    end

    before { batch.update_columns(status: "publishing") }

    it "keeps the existing response, with no wait keys, when wait_seconds is absent or 0" do
      stub_sleep
      [ {}, { wait_seconds: 0 } ].each do |extra|
        r = call("system_get_module_build_batch", batch_id: batch.id, **extra)
        expect(r[:data].keys).to eq([ :module_build_batch ])
      end
      expect(@sleeps).to be_empty
    end

    it "returns immediately when the batch is already finished" do
      stub_sleep
      batch.update_columns(status: "complete")

      r = call("system_get_module_build_batch", batch_id: batch.id, wait_seconds: 30)

      expect(r[:data][:module_build_batch][:status]).to eq("complete")
      expect(r[:data][:timed_out]).to be false
      expect(@sleeps).to be_empty
    end

    it "returns once the batch finishes mid-wait" do
      stub_sleep { |tick| batch.update_columns(status: "partial") if tick == 3 }

      r = call("system_get_module_build_batch", batch_id: batch.id, wait_seconds: 30)

      expect(r[:data][:module_build_batch][:status]).to eq("partial")
      expect(r[:data][:timed_out]).to be false
      expect(@sleeps.size).to eq(3)
    end

    it "times out with timed_out: true and the current snapshot" do
      stub_sleep

      r = call("system_get_module_build_batch", batch_id: batch.id, wait_seconds: 4)

      expect(r[:success]).to be true
      expect(r[:data][:timed_out]).to be true
      expect(r[:data][:module_build_batch][:status]).to eq("publishing")
    end

    it "clamps an oversized wait_seconds to the cap" do
      stub_sleep

      r = call("system_get_module_build_batch", batch_id: batch.id, wait_seconds: 99_999)

      expect(r[:data][:timed_out]).to be true
      expect(@sleeps.sum).to eq(described_class::WAIT_MAX_SECONDS)
    end

    it "still refuses a blank id without waiting" do
      stub_sleep
      expect(call("system_get_module_build_batch", batch_id: "", wait_seconds: 30)[:error]).to include("batch_id is required")
      expect(@sleeps).to be_empty
    end
  end

  describe "system_wait_for" do
    let(:environment) { create(:ai_environment, account: account, slug: "staging-wait") }
    let(:mod) do
      create(:system_node_module, account: account, node_platform: platform_record,
                                  category: category, variety: "subscription", name: "wait-mod")
    end
    let(:digest) { "sha256:#{'b' * 64}" }
    let(:old_digest) { "sha256:#{'c' * 64}" }
    let!(:version) do
      System::NodeModuleVersion.create!(node_module: mod, version_number: 2, mask: [], file_spec: [],
                                        package_spec: [], config: {}, oci_digest: digest)
    end

    def rollout_instance(idx, running: old_digest, env: environment, heartbeat: Time.current)
      node = create(:system_node, account: account, node_template: template, name: "wait-node-#{idx}")
      node.node_modules << mod
      create(:system_node_instance, :running, node: node).tap do |inst|
        inst.update!(environment: env, running_module_digests: running ? { mod.id => running } : {},
                     last_heartbeat_at: heartbeat)
      end
    end

    def wait_for(**rest)
      call("system_wait_for", module_version_id: version.id, environment: environment.slug, **rest)
    end

    it "returns converged at once when every node in the environment runs the digest" do
      stub_sleep
      rollout_instance(1, running: digest)
      rollout_instance(2, running: digest)

      r = wait_for(wait_seconds: 30)

      expect(r[:success]).to be true
      data = r[:data]
      expect(data).to include(converged: true, timed_out: false, target_digest: digest,
                              instance_count: 2, converged_count: 2, environment: environment.slug,
                              module_version_id: version.id)
      expect(data[:pending]).to eq([])
      expect(@sleeps).to be_empty
    end

    it "converges mid-wait once the last node's heartbeat reports the digest" do
      rollout_instance(1, running: digest)
      laggard = rollout_instance(2, running: old_digest)
      stub_sleep { |tick| laggard.update_columns(running_module_digests: { mod.id => digest }) if tick == 2 }

      r = wait_for(wait_seconds: 30)

      expect(r[:data]).to include(converged: true, timed_out: false, converged_count: 2)
      expect(@sleeps.size).to eq(2)
    end

    # Inside a request the query cache is on, and #reload clears it, so only the
    # rollout's own queries depend on uncached: without it the first poll's
    # SELECTs are replayed for the whole wait and a heartbeat landing elsewhere
    # is never seen. The write goes straight to the PG connection so it does not
    # itself clear the cache, as another process's write would not (an AR write,
    # even inside an uncached block, clears it).
    it "sees a heartbeat that lands mid-wait even with the query cache on" do
      rollout_instance(1, running: digest)
      laggard = rollout_instance(2, running: old_digest)
      stub_sleep do |tick|
        if tick == 2
          conn = ActiveRecord::Base.connection
          conn.raw_connection.exec(
            "UPDATE system_node_instances SET running_module_digests = " \
            "#{conn.quote({ mod.id => digest }.to_json)}::jsonb WHERE id = #{conn.quote(laggard.id)}"
          )
        end
      end

      r = ActiveRecord::Base.cache { wait_for(wait_seconds: 30) }

      expect(r[:data]).to include(converged: true, timed_out: false, converged_count: 2)
    end

    it "times out with timed_out: true and names the nodes still pending, never an error" do
      rollout_instance(1, running: digest)
      laggard = rollout_instance(2, running: old_digest)
      stub_sleep

      r = wait_for(wait_seconds: 6)

      expect(r[:success]).to be true
      expect(r[:data]).to include(converged: false, timed_out: true, instance_count: 2, converged_count: 1)
      expect(r[:data][:pending]).to eq([ { instance_id: laggard.id, name: laggard.name, running_digest: old_digest,
                                           stale: false, last_heartbeat_at: laggard.last_heartbeat_at.iso8601 } ])
      expect(@sleeps.sum).to eq(6)
    end

    # Mirrors PromotionCriteria.evaluate: a node that reported the digest and
    # then went silent is a fault, not evidence the rollout landed.
    it "does not count a node that reports the digest but has gone silent as converged" do
      rollout_instance(1, running: digest)
      silent = rollout_instance(2, running: digest,
                                    heartbeat: (System::NodeInstance::HEARTBEAT_STALE_AFTER + 1.minute).ago)
      stub_sleep

      r = wait_for(wait_seconds: 4)

      expect(r[:data]).to include(converged: false, timed_out: true, instance_count: 2, converged_count: 1)
      expect(r[:data][:pending]).to eq([ { instance_id: silent.id, name: silent.name, running_digest: digest,
                                           stale: true, last_heartbeat_at: silent.last_heartbeat_at.iso8601 } ])
    end

    it "does not count a node that never heartbeated as converged" do
      rollout_instance(1, running: digest, heartbeat: nil)
      stub_sleep

      r = wait_for(wait_seconds: 2)

      expect(r[:data]).to include(converged: false, converged_count: 0)
      expect(r[:data][:pending].first).to include(stale: true, last_heartbeat_at: nil)
    end

    it "is not converged while the environment has no node carrying the module" do
      stub_sleep

      r = wait_for(wait_seconds: 4)

      expect(r[:data]).to include(converged: false, timed_out: true, instance_count: 0)
    end

    it "ignores nodes in other environments and nodes that are not running" do
      other = create(:ai_environment, account: account, slug: "other-wait")
      rollout_instance(1, running: digest)
      rollout_instance(2, running: old_digest, env: other)
      stopped = rollout_instance(3, running: old_digest)
      stopped.update_columns(status: "terminated")
      stub_sleep

      r = wait_for(wait_seconds: 30)

      expect(r[:data]).to include(converged: true, instance_count: 1)
    end

    it "clamps an oversized wait_seconds to the cap and defaults to it when absent" do
      rollout_instance(1, running: old_digest)
      stub_sleep

      expect(wait_for(wait_seconds: 100_000)[:data][:wait_seconds]).to eq(described_class::WAIT_MAX_SECONDS)
      expect(@sleeps.sum).to eq(described_class::WAIT_MAX_SECONDS)

      stub_sleep
      expect(wait_for[:data]).to include(timed_out: true, wait_seconds: described_class::WAIT_MAX_SECONDS)
      expect(@sleeps.sum).to eq(described_class::WAIT_MAX_SECONDS)
    end

    it "refuses unknown inputs without waiting" do
      stub_sleep

      expect(call("system_wait_for", environment: environment.slug)[:error]).to include("module_version_id is required")
      expect(call("system_wait_for", module_version_id: version.id)[:error]).to include("environment is required")
      expect(call("system_wait_for", module_version_id: SecureRandom.uuid, environment: environment.slug)[:error])
        .to include("not found")
      expect(call("system_wait_for", module_version_id: version.id, environment: "nope")[:error]).to include("not found")

      foreign = create(:ai_environment, account: create(:account), slug: "foreign-wait")
      expect(call("system_wait_for", module_version_id: version.id, environment: foreign.id)[:error]).to include("not found")

      version.update!(oci_digest: nil)
      expect(wait_for[:error]).to include("no oci_digest")
      expect(@sleeps).to be_empty
    end

    it "does not see a version belonging to another account" do
      other_mod = create(:system_node_module, account: create(:account), name: "foreign-mod")
      foreign_version = System::NodeModuleVersion.create!(node_module: other_mod, version_number: 1, mask: [],
                                                          file_spec: [], package_spec: [], config: {},
                                                          oci_digest: digest)

      r = call("system_wait_for", module_version_id: foreign_version.id, environment: environment.slug)

      expect(r[:success]).to be false
      expect(r[:error]).to include("not found")
    end

    it "requires system.modules.read" do
      denied = described_class.new(account: account,
                                   user: create(:user, account: account, permissions: %w[system.nodes.read]))

      r = denied.execute(params: { action: "system_wait_for", module_version_id: version.id,
                                   environment: environment.slug })

      expect(r[:success]).to be false
      expect(r[:error]).to include("permission denied")
    end
  end

  describe "wait_seconds parsing" do
    let(:node) { create(:system_node, account: account, node_template: template, name: "parsewait") }
    let!(:task) do
      System::Task.create!(account: account, command: "apply_config", status: "running",
                           operable_type: "System::Node", operable_id: node.id)
    end
    let(:batch) do
      System::ModuleBuildBatch.create_for(account: account, trigger: "manual", base_sha: "b", head_sha: "h",
                                          plan: [ { module: "mod-x", oci_ref: "abc1234" } ])
    end
    let(:environment) { create(:ai_environment, account: account, slug: "parse-wait") }
    let(:version) do
      mod = create(:system_node_module, account: account, node_platform: platform_record,
                                        category: category, variety: "subscription", name: "parse-mod")
      System::NodeModuleVersion.create!(node_module: mod, version_number: 1, mask: [], file_spec: [],
                                        package_spec: [], config: {}, oci_digest: "sha256:#{'e' * 64}")
    end

    def each_verb
      yield "system_get_task", { task_id: task.id }
      yield "system_get_module_build_batch", { batch_id: batch.id }
      yield "system_wait_for", { module_version_id: version.id, environment: environment.slug }
    end

    it "refuses a non-integer wait_seconds by name instead of raising or reading it as 0" do
      stub_sleep
      [ "abc", true, [ 5 ], { "a" => 1 }, "1.5x" ].each do |bad|
        each_verb do |action, args|
          r = call(action, **args, wait_seconds: bad)
          expect(r[:success]).to be(false), "#{action} wait_seconds=#{bad.inspect}"
          expect(r[:error]).to include("wait_seconds")
        end
      end
      expect(@sleeps).to be_empty
    end

    it "accepts an integer, an integer string and a whole float, and reads negatives as 0" do
      stub_sleep
      expect(call("system_get_task", task_id: task.id, wait_seconds: "3")[:data]).to include(wait_seconds: 3)
      expect(call("system_get_task", task_id: task.id, wait_seconds: 3.0)[:data]).to include(wait_seconds: 3)
      expect(call("system_get_task", task_id: task.id, wait_seconds: -5)[:data].keys).to eq([ :task ])
    end
  end

  describe "concurrent wait bound" do
    let(:node) { create(:system_node, account: account, node_template: template, name: "boundwait") }
    let!(:task) do
      System::Task.create!(account: account, command: "apply_config", status: "running",
                           operable_type: "System::Node", operable_id: node.id)
    end
    let(:batch) do
      System::ModuleBuildBatch.create_for(account: account, trigger: "manual", base_sha: "b", head_sha: "h",
                                          plan: [ { module: "mod-x", oci_ref: "abc1234" } ]).tap do |b|
        b.update_columns(status: "publishing")
      end
    end
    let(:environment) { create(:ai_environment, account: account, slug: "bound-wait") }
    let(:version) do
      mod = create(:system_node_module, account: account, node_platform: platform_record,
                                        category: category, variety: "subscription", name: "bound-mod")
      System::NodeModuleVersion.create!(node_module: mod, version_number: 1, mask: [], file_spec: [],
                                        package_spec: [], config: {}, oci_digest: "sha256:#{'f' * 64}")
    end
    let(:permits) { described_class::WAIT_PERMITS }

    it "sizes the bound at a quarter of the Puma max threads, minimum 1" do
      expected = [ ENV.fetch("RAILS_MAX_THREADS", 16).to_i / 4, 1 ].max
      expect(described_class::WAIT_CONCURRENCY).to eq(expected)
      expect(permits.available_permits).to eq(expected)
      expect(described_class.wait_concurrency_for(16)).to eq(4)
      expect(described_class.wait_concurrency_for(2)).to eq(1)
      expect(described_class.wait_concurrency_for(0)).to eq(1)
    end

    context "with every permit taken" do
      around do |example|
        held = permits.available_permits
        permits.drain_permits
        example.run
      ensure
        permits.release(held - permits.available_permits)
      end

      it "degrades the task wait to one check: success, timed_out and wait_degraded, no sleeping" do
        stub_sleep

        r = call("system_get_task", task_id: task.id, wait_seconds: 30)

        expect(r[:success]).to be true
        expect(r[:data]).to include(timed_out: true, wait_degraded: true)
        expect(r[:data][:task][:status]).to eq("running")
        expect(@sleeps).to be_empty
      end

      it "degrades the batch wait and the rollout wait the same way" do
        stub_sleep

        b = call("system_get_module_build_batch", batch_id: batch.id, wait_seconds: 30)
        expect(b[:data]).to include(timed_out: true, wait_degraded: true)

        w = call("system_wait_for", module_version_id: version.id, environment: environment.slug)
        expect(w[:success]).to be true
        expect(w[:data]).to include(converged: false, timed_out: true, wait_degraded: true)
        expect(@sleeps).to be_empty
      end

      it "still answers an already-terminal task normally, with no degrade flag" do
        task.update_columns(status: "complete")

        r = call("system_get_task", task_id: task.id, wait_seconds: 30)

        expect(r[:data]).to include(timed_out: false)
        expect(r[:data]).not_to have_key(:wait_degraded)
      end
    end

    it "does not flag wait_degraded on a wait that held a permit" do
      stub_sleep
      r = call("system_get_task", task_id: task.id, wait_seconds: 4)
      expect(r[:data]).to include(timed_out: true)
      expect(r[:data]).not_to have_key(:wait_degraded)
    end

    it "holds a permit only while waiting and releases it after a timeout, a finish and an exception" do
      full = permits.available_permits
      held_during = nil

      stub_sleep { held_during = permits.available_permits }
      call("system_get_task", task_id: task.id, wait_seconds: 4)
      expect(held_during).to eq(full - 1)
      expect(permits.available_permits).to eq(full)

      stub_sleep { |tick| task.update_columns(status: "complete") if tick == 1 }
      call("system_get_task", task_id: task.id, wait_seconds: 30)
      expect(permits.available_permits).to eq(full)

      task.update_columns(status: "running")
      stub_sleep { raise "boom" }
      begin
        call("system_get_task", task_id: task.id, wait_seconds: 30)
      rescue StandardError
        nil
      end
      expect(permits.available_permits).to eq(full)
    end
  end

  describe "read-only contract" do
    let(:catalog) { ::Mcp::ToolCatalog.new(protocol_version: ::Mcp::ProtocolService::ALL_SUPPORTED_VERSIONS.max) }

    it "declares the wait verbs non-mutating" do
      %w[system_wait_for system_get_task system_get_module_build_batch].each do |action|
        expect(described_class.declared_action(action)).to include(mutating: false), action
      end
    end

    it "advertises system_wait_for with readOnlyHint true and documents wait_seconds on all three" do
      entries = catalog.list_entries.index_by { |t| t["name"] }

      entry = entries.fetch("platform.system_wait_for")
      expect(entry["annotations"]).to include("readOnlyHint" => true)
      expect(entry["annotations"]).not_to include("destructiveHint" => true)

      %w[system_wait_for system_get_task system_get_module_build_batch].each do |action|
        params = described_class.action_definitions.fetch(action)[:parameters]
        expect(params[:wait_seconds]).to include(type: "integer", required: false)
      end
      expect(described_class.action_definitions.fetch("system_wait_for")[:parameters])
        .to include(:module_version_id, :environment)
    end

    it "maps system_wait_for to a read permission" do
      expect(described_class::ACTION_PERMISSIONS.fetch("system_wait_for")).to eq("system.modules.read")
    end
  end

  describe "instance-principal reachability" do
    let(:node_instance) { double("NodeInstance", id: SecureRandom.uuid, account: account) }
    let(:principal) do
      ::Mcp::Principal.new(kind: :instance, account: account, node_instance: node_instance,
                           subject_id: node_instance.id)
    end
    let(:granted) { %w[platform.system_wait_for platform.system_get_task platform.system_get_module_build_batch] }

    around do |example|
      previous = ::Mcp::Principal.tool_grant_resolver
      ::Mcp::Principal.tool_grant_resolver = ->(_i) { granted }
      example.run
      ::Mcp::Principal.tool_grant_resolver = previous
    end

    it "is not destroy-shaped, so the deny overlay leaves it grantable" do
      granted.each do |name|
        expect(::Mcp::Principal.destructive_tool?(name)).to be(false), name
        expect(principal.may_invoke?(name)).to be(true), name
      end
    end

    it "is listed for an instance granted it and hidden from one that is not" do
      catalog = ::Mcp::ToolCatalog.new(protocol_version: ::Mcp::ProtocolService::ALL_SUPPORTED_VERSIONS.max,
                                       principal: principal)
      expect(catalog.advertised_names).to match_array(granted)

      ::Mcp::Principal.tool_grant_resolver = ->(_i) { [] }
      expect(catalog.class.new(protocol_version: ::Mcp::ProtocolService::ALL_SUPPORTED_VERSIONS.max,
                               principal: principal).advertised_names).to be_empty
    end

    it "executes for an instance-authorized tool without a user" do
      environment = create(:ai_environment, account: account, slug: "inst-wait")
      mod = create(:system_node_module, account: account, node_platform: platform_record,
                                        category: category, variety: "subscription", name: "inst-mod")
      version = System::NodeModuleVersion.create!(node_module: mod, version_number: 1, mask: [], file_spec: [],
                                                  package_spec: [], config: {}, oci_digest: "sha256:#{'d' * 64}")
      instance_tool = described_class.new(account: account, user: nil)
      instance_tool.instance_authorized = true
      instance_tool.node_instance = node_instance
      allow(instance_tool).to receive(:sleep)

      r = instance_tool.execute(params: { action: "system_wait_for", module_version_id: version.id,
                                          environment: environment.slug, wait_seconds: 0 }.with_indifferent_access)

      expect(r[:success]).to be true
      expect(r[:data]).to include(converged: false)
    end
  end
end
