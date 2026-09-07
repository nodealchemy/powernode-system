# frozen_string_literal: true

require "rails_helper"

# IMP-53e7df9f2ae1 — re-templating an already-provisioned node moved the
# POINTER but not the MODULES.
#
# `system_update_node` accepts `node_template_id` and writes it through
# `node.update!`. Nothing else happens: a node's modules are
# System::NodeModuleAssignment rows, and the only thing that materializes them
# from a template's closure is System::TemplateApplyService, whose callers were
# all provisioning-time or the REST twin. System::Node has no callback on a
# node_template_id change, and System::Runtime::SyncModules reconciles
# `node.node_module_assignments` — never the template — so the agent's own
# refresh re-applies the OLD module set. The operator got a success and the node
# kept running the previous template's modules indefinitely.
#
# The property pinned here is the one the operator ruled on: after an operation
# that changes a provisioned node's template, the node's ATTACHED MODULES match
# the NEW template. A re-template REPLACES modules — it does not add to them.
#
# The discriminating fixture is a node carrying BOTH a template-derived module
# and an out-of-band one (System::InferenceDeploymentService,
# Sdwan::FlowExporterDeployer and System::ModuleCommitService all create
# assignments with a NULL source_template_module_id, and no template will ever
# re-create them). A fixture with only template modules would pass whether or
# not the purge could tell the two apart.
RSpec.describe Ai::Tools::SystemFleetTool, "re-templating a provisioned node" do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account, name: "cat-#{SecureRandom.hex(3)}") }
  let(:tool)     { described_class.new(account: account, internal: true) }

  let(:template_a) do
    create(:system_node_template, account: account, node_platform: platform, name: "tmpl-a-#{SecureRandom.hex(3)}")
  end
  let(:template_b) do
    create(:system_node_template, account: account, node_platform: platform, name: "tmpl-b-#{SecureRandom.hex(3)}")
  end
  let(:node) do
    create(:system_node, account: account, node_template: template_a, name: "node-#{SecureRandom.hex(3)}")
  end

  def node_module(name)
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "#{name}-#{SecureRandom.hex(3)}")
  end

  def join(template, mod)
    ::System::TemplateModule.create!(node_template: template, node_module: mod, enabled: true)
  end

  def call(action, **rest)
    tool.execute(params: { action: action }.merge(rest))
  end

  # The A-template module, materialized the way provisioning materializes it —
  # through the applier, so it carries a real source_template_module_id.
  let!(:module_a) { node_module("from-template-a") }
  let!(:module_b) { node_module("from-template-b") }
  let!(:oob_module) { node_module("out-of-band") }

  before do
    join(template_a, module_a)
    join(template_b, module_b)
    ::System::TemplateApplyService.new(node).apply!

    # Exactly the shape InferenceDeploymentService#assign_module! creates:
    # no template closure behind it, so source_template_module_id is NULL.
    ::System::NodeModuleAssignment.create!(
      node: node, node_module: oob_module, enabled: true, priority: 100
    )
  end

  def assigned_module_ids
    node.reload.node_module_assignments.pluck(:node_module_id)
  end

  describe "the module set after the pointer moves" do
    it "starts from the discriminating fixture: one template module, one out-of-band" do
      expect(assigned_module_ids).to contain_exactly(module_a.id, oob_module.id)
      expect(node.node_module_assignments.find_by(node_module_id: module_a.id).source_template_module_id).to be_present
      expect(node.node_module_assignments.find_by(node_module_id: oob_module.id).source_template_module_id).to be_nil
    end

    it "attaches the new template's modules" do
      call("system_update_node", node_id: node.id, node_template_id: template_b.id)

      expect(assigned_module_ids).to include(module_b.id)
    end

    it "detaches the previous template's modules — a re-template REPLACES" do
      call("system_update_node", node_id: node.id, node_template_id: template_b.id)

      expect(assigned_module_ids).not_to include(module_a.id)
    end

    it "leaves the out-of-band assignment alone — no template will re-create it" do
      call("system_update_node", node_id: node.id, node_template_id: template_b.id)

      expect(assigned_module_ids).to include(oob_module.id)
    end

    it "reports what it created and purged rather than a bare success" do
      r = call("system_update_node", node_id: node.id, node_template_id: template_b.id)

      expect(r[:success]).to be true
      applied = r.dig(:data, :template_applied)
      expect(applied).to be_present
      expect(applied[:created_module_ids]).to include(module_b.id)
      expect(applied[:purged_module_ids]).to eq([ module_a.id ])
    end
  end

  describe "operations that do not change the template" do
    it "leaves assignments untouched on a rename" do
      call("system_update_node", node_id: node.id, name: "renamed-#{SecureRandom.hex(3)}")

      expect(assigned_module_ids).to contain_exactly(module_a.id, oob_module.id)
    end

    it "does not re-apply when the same template id is supplied" do
      r = call("system_update_node", node_id: node.id, node_template_id: template_a.id)

      expect(r[:success]).to be true
      expect(r.dig(:data, :template_applied)).to be_nil
      expect(assigned_module_ids).to contain_exactly(module_a.id, oob_module.id)
    end
  end

  # Right assignments are not a converged node. System::Runtime::SyncModules
  # reads node_module_assignments, so a cloud_init instance converges once a
  # sync_modules Task runs — but a pivot-booted instance composes its module
  # union at BOOT (memory: live-module-refresh-no-remount-pivot), so the same
  # task is a silent no-op there. Fleet::DecisionEngine#apply_template_closure_drift
  # splits on exactly that; this verb must not report a convergence it cannot
  # deliver.
  describe "the convergence rung" do
    def sync_tasks_for(instance)
      ::System::Task.where(operable: instance, command: "sync_modules")
    end

    it "queues sync_modules for a live cloud_init instance" do
      instance = create(:system_node_instance, :running, node: node, account: account,
                        last_heartbeat_at: Time.current, config: { "boot_mode" => "cloud_init" })

      r = call("system_update_node", node_id: node.id, node_template_id: template_b.id)

      expect(sync_tasks_for(instance).count).to eq(1)
      expect(r.dig(:data, :template_applied, :convergence, :dispatched)).to include(instance.id)
    end

    it "defers a pivot-booted instance to a reboot instead of queuing a no-op task" do
      instance = create(:system_node_instance, :running, node: node, account: account, config: { "boot_mode" => "direct_kernel" })

      r = call("system_update_node", node_id: node.id, node_template_id: template_b.id)

      expect(sync_tasks_for(instance).count).to eq(0)
      convergence = r.dig(:data, :template_applied, :convergence)
      # {instance_id, reason} since IMP-0da2d48b5c1f — a bare id discarded the
      # liveness fact for a pivot node that was also dead.
      expect(convergence[:deferred].map { |e| e[:instance_id] }).to include(instance.id)
      expect(convergence[:reason].to_s).to match(/reboot|reprovision/i)
    end

    it "does not dispatch to a terminated instance" do
      instance = create(:system_node_instance, node: node, account: account, status: "terminated",
                        config: { "boot_mode" => "cloud_init" })

      call("system_update_node", node_id: node.id, node_template_id: template_b.id)

      expect(sync_tasks_for(instance).count).to eq(0)
    end
  end

  # IMP-cdf18862a7c1 — the convergence rung had TWO buckets, and an instance
  # that could not converge fell into the dispatched one.
  #
  # The scope is TemplateApprovalPolicy::LIVE_INSTANCE_SCOPE, which is the
  # blast-radius definition this verb shares with the approval policy — so it
  # deliberately keeps `error` (and every transitional status) in range, and
  # the terminated case above is the only one the QUERY excludes. That left
  # two shapes queueing a task no agent would ever pull: an errored instance,
  # and a `running` one whose agent has gone silent or never enrolled at all.
  # Both produced `dispatched: [id]` and a task that sits pending until the
  # janitor cancels it 48 hours later.
  #
  # The scope stays as it is — narrowing it here would silently disagree with
  # the policy about what the blast radius IS. The third bucket reports the
  # ones that cannot converge instead, using the same
  # NodeInstance#on_node_dispatch_refusal the Fleet::DecisionEngine consults,
  # so the two dispatchers cannot drift on what "no agent will pull this" means.
  describe "the convergence rung's third bucket (IMP-cdf18862a7c1)" do
    def sync_tasks_for(instance)
      ::System::Task.where(operable: instance, command: "sync_modules")
    end

    def convergence_for(instance)
      r = call("system_update_node", node_id: node.id, node_template_id: template_b.id)
      [ r.dig(:data, :template_applied, :convergence), sync_tasks_for(instance).count ]
    end

    it "skips an errored instance, naming it and why, instead of queueing a task it cannot pull" do
      instance = create(:system_node_instance, node: node, account: account, status: "error",
                        config: { "boot_mode" => "cloud_init" })

      convergence, task_count = convergence_for(instance)

      expect(task_count).to eq(0)
      expect(convergence[:dispatched]).not_to include(instance.id)
      expect(convergence[:skipped]).to contain_exactly(
        a_hash_including(instance_id: instance.id, reason: a_string_matching(/error/))
      )
    end

    it "skips a running instance whose agent went silent" do
      instance = create(:system_node_instance, :running, node: node, account: account,
                        last_heartbeat_at: 30.minutes.ago, config: { "boot_mode" => "cloud_init" })

      convergence, task_count = convergence_for(instance)

      expect(task_count).to eq(0)
      expect(convergence[:skipped]).to contain_exactly(
        a_hash_including(instance_id: instance.id, reason: a_string_matching(/went silent/))
      )
    end

    # The never-enrolled VM: CloudSyncService writes `running` from provider
    # state alone, so the status says live and no agent has ever existed.
    it "skips a running instance whose agent has never reported" do
      instance = create(:system_node_instance, :running, node: node, account: account,
                        last_heartbeat_at: nil, config: { "boot_mode" => "cloud_init" })

      convergence, task_count = convergence_for(instance)

      expect(task_count).to eq(0)
      expect(convergence[:skipped]).to contain_exactly(
        a_hash_including(instance_id: instance.id, reason: a_string_matching(/never reported/))
      )
    end

    # A node still coming up is not a dead node — refusing it here would trade
    # a visible stuck task for a node that never gets its modules.
    it "still dispatches to a starting instance that has not reported yet" do
      instance = create(:system_node_instance, node: node, account: account, status: "starting",
                        last_heartbeat_at: nil, config: { "boot_mode" => "cloud_init" })

      convergence, task_count = convergence_for(instance)

      expect(task_count).to eq(1)
      expect(convergence[:dispatched]).to include(instance.id)
      expect(convergence[:skipped]).to be_empty
    end

    # The pivot arm is checked FIRST and keeps its own bucket: a pivot-booted
    # node that is also silent is deferred, not skipped — the operator action
    # (reboot) is the same either way, and reporting it twice would double-count
    # the fleet.
    it "reports a silent pivot-booted instance as deferred, not skipped" do
      instance = create(:system_node_instance, :running, node: node, account: account,
                        last_heartbeat_at: 30.minutes.ago, config: { "boot_mode" => "direct_kernel" })

      convergence, task_count = convergence_for(instance)

      expect(task_count).to eq(0)
      expect(convergence[:deferred].map { |e| e[:instance_id] }).to include(instance.id)
      expect(convergence[:skipped]).to be_empty
    end

    # IMP-0da2d48b5c1f — two reporting defects, both about the payload telling
    # the caller something FALSE.
    #
    # 1. The pivot arm is checked first (correctly — the operator action for a
    #    silent-but-alive pivot node is a reboot either way, and two buckets
    #    would double-count the fleet), but `deferred` carried BARE IDS while
    #    `skipped` carried {instance_id, reason}. So a pivot node that was
    #    errored, silent or never-enrolled arrived with NO liveness information
    #    and the shared "just reboot it" reason attached — true for a
    #    silent-but-alive node, FALSE for a presumed-dead one, where the action
    #    is investigate/reprovision.
    #
    # 2. A DORMANT instance (stopped/rebooting/provisioning) was reported
    #    `dispatched`. The task really is created and really is pulled when an
    #    agent starts — but nothing is listening now, and the janitor's 48h
    #    cancel may reach the row first, so `dispatched` overstates it.
    describe "the payload does not overstate what it knows (IMP-0da2d48b5c1f)" do
      def deferred_entry(convergence, instance)
        convergence[:deferred].find { |e| e[:instance_id] == instance.id }
      end

      it "carries the LIVENESS reason for a pivot node that is presumed dead" do
        instance = create(:system_node_instance, :running, node: node, account: account,
                          last_heartbeat_at: 30.minutes.ago, config: { "boot_mode" => "direct_kernel" })

        convergence, task_count = convergence_for(instance)

        expect(task_count).to eq(0)
        entry = deferred_entry(convergence, instance)
        expect(entry).to be_present
        expect(entry[:reason]).to match(/went silent/)
      end

      it "carries the liveness reason for a pivot node reaped to error" do
        instance = create(:system_node_instance, node: node, account: account, status: "error",
                          last_heartbeat_at: 30.minutes.ago, config: { "boot_mode" => "direct_kernel" })

        convergence, = convergence_for(instance)

        entry = deferred_entry(convergence, instance)
        expect(entry).to be_present
        expect(entry[:reason]).to match(/no agent will pull/)
      end

      it "still says 'reboot' for a pivot node whose agent is fine" do
        instance = create(:system_node_instance, :running, node: node, account: account,
                          last_heartbeat_at: Time.current, config: { "boot_mode" => "direct_kernel" })

        convergence, = convergence_for(instance)

        entry = deferred_entry(convergence, instance)
        expect(entry).to be_present
        expect(entry[:reason]).to match(/reboot|reprovision/i)
        expect(entry[:reason]).not_to match(/went silent|never reported|no agent will pull/)
      end

      it "reports a dormant instance in its own bucket rather than as dispatched" do
        instance = create(:system_node_instance, node: node, account: account, status: "stopped",
                          last_heartbeat_at: Time.current, config: { "boot_mode" => "cloud_init" })

        convergence, task_count = convergence_for(instance)

        # The task IS created — that is the fact the old `dispatched` bucket
        # was right about, and it must not be lost.
        expect(task_count).to eq(1)
        expect(convergence[:dispatched]).not_to include(instance.id)
        expect(convergence[:skipped]).to be_empty

        entry = convergence[:dormant].find { |e| e[:instance_id] == instance.id }
        expect(entry).to be_present
        expect(entry[:reason]).to match(/no agent is running/)
        expect(entry[:task_id]).to be_present
      end

      # THE CASE THAT CAUGHT THE DESCRIPTION OUT. A `starting` instance with no
      # heartbeat has no agent listening — but a missing heartbeat during boot
      # is deliberately NOT evidence of death (#silence_verdict returns nil for
      # `starting`, and #dormant_agent_reason declines to judge a status where
      # a heartbeat IS expected), so it is neither refused nor dormant and it
      # lands in `dispatched`. That is the right BEHAVIOUR — refusing it would
      # trade a visible stuck task for a node that never gets its modules — and
      # it is why `dispatched` cannot claim an agent is listening. An earlier
      # draft of the tool description said exactly that and was false here.
      it "puts a not-yet-reported starting instance in dispatched, which therefore proves nothing" do
        instance = create(:system_node_instance, node: node, account: account, status: "starting",
                          last_heartbeat_at: nil, config: { "boot_mode" => "cloud_init" })

        convergence, task_count = convergence_for(instance)

        expect(task_count).to eq(1)
        expect(convergence[:dispatched]).to include(instance.id)
        expect(convergence[:dormant]).to be_empty
        expect(convergence[:skipped]).to be_empty
      end

      it "leaves dormant empty and dispatched populated for a live agent" do
        instance = create(:system_node_instance, :running, node: node, account: account,
                          last_heartbeat_at: Time.current, config: { "boot_mode" => "cloud_init" })

        convergence, = convergence_for(instance)

        expect(convergence[:dispatched]).to include(instance.id)
        expect(convergence[:dormant]).to be_empty
      end
    end

    it "leaves skipped empty for a healthy fleet" do
      instance = create(:system_node_instance, :running, node: node, account: account,
                        last_heartbeat_at: Time.current, config: { "boot_mode" => "cloud_init" })

      convergence, task_count = convergence_for(instance)

      expect(task_count).to eq(1)
      expect(convergence[:skipped]).to be_empty
    end
  end

  describe "account scoping" do
    it "still refuses a node from another account" do
      other = create(:account)
      other_platform = create(:system_node_platform, account: other)
      other_template = create(:system_node_template, account: other, node_platform: other_platform)
      foreign = create(:system_node, account: other, node_template: other_template, name: "foreign-#{SecureRandom.hex(3)}")

      r = call("system_update_node", node_id: foreign.id, node_template_id: template_b.id)

      expect(r[:success]).to be false
      expect(foreign.reload.node_template_id).to eq(other_template.id)
    end
  end
end
