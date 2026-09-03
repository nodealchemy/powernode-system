# frozen_string_literal: true

require "rails_helper"

# IMP-4e49eb79c5e0 — the APO-4 remainder: the DR lane had no MCP door at all.
#
# APO-4 (a08fb15c) landed System::Ai::Skills::ReplaceInstanceExecutor and
# System::Ai::Skills::ReapInstanceExecutor behind the fleet sensor lane only.
# Every OTHER way into that lane was closed: the executors are bound to the
# "Fleet Autonomy" agent, and no MCP verb named either of them
# (`command grep -rn "replace_instance\|reap_instance" --include=*.rb
# extensions/system/server/app/services/ai/tools/ server/app/services/ai/tools/
# | wc -l` returned 0 on the commit this spec was written against). So an
# operator — or a Concierge agent asked "this box is dead, replace it" — could
# not drive a disaster-recovery replace on demand; they could only wait for the
# unrecoverable sensor to notice.
#
# WHY THE VERBS ARE GATE-ROUTED RATHER THAN PLAIN. The executors already carry
# `requires_approval` and their own action_category, and BaseSkillExecutor
# #gate_action! would park an approval on an ungated in-#call invocation. But
# routing through Ai::Tools::BaseTool's declared gate instead is what makes the
# MCP door behave like the REST/terminate door: ONE Ai::AutonomyGate evaluation
# at the chokepoint, the pending envelope BaseTool mints (which the frontend
# and every agent already read), and the executor — never the action body — as
# the actor on both branches. A verb that reached #call and let the executor
# park its own approval would return the SKILL's envelope shape on the pending
# branch, which no MCP caller reads as "parked".
#
# THE ORACLE IS THE ROW, never the response shape alone. This repo has shipped
# a guard that rendered a refusal from an action body while the write landed
# (IMP-ce5d320d3e4e), so each gated example reads the instance/pool back, and
# the replay examples drive execute_now! to prove the parked operation still
# performs the work.
RSpec.describe "SystemFleetTool replace/reap MCP verbs (IMP-4e49eb79c5e0)" do
  let(:account) { create(:account) }

  # system.nodes.read is SystemFleetTool::REQUIRED_PERMISSION — the tool floor —
  # and is carried alongside the per-action permission deliberately: a principal
  # that could park a replace but not clear the floor would be refused before
  # #authorization_error ever asked the per-action question, and the "really
  # replaces when approved" examples would pass for the wrong reason.
  let(:user) do
    create(:user, account: account,
                  permissions: %w[system.nodes.read system.instances.control])
  end
  let(:tool) { Ai::Tools::SystemFleetTool.new(account: account, user: user) }

  let(:node_template)          { create(:system_node_template, account: account) }
  let(:provider_region)        { create(:system_provider_region) }
  let(:provider_instance_type) { create(:system_provider_instance_type) }

  let(:pool) do
    System::InstancePool.create!(
      account: account, node_template: node_template, name: "dr-pool",
      target_size: 2, min_size: 1, max_size: 4, lifecycle_class: "ephemeral",
      status: "active", provider_region: provider_region,
      provider_instance_type: provider_instance_type
    )
  end

  def pool_member(pool_state:, status:)
    node = create(:system_node, account: account, node_template: node_template)
    create(:system_node_instance,
           node: node, name: "m-#{SecureRandom.hex(3)}", variety: "cloud",
           status: status, provider_region: provider_region,
           provider_instance_type: provider_instance_type,
           instance_pool_id: pool.id, pool_state: pool_state,
           pool_warming_started_at: 5.minutes.ago)
  end

  let!(:failed) { pool_member(pool_state: "claimed", status: "error") }
  let!(:spare)  { pool_member(pool_state: "ready",   status: "running") }

  let(:provider) { instance_double(System::Providers::MockProvider, provider_type: "mock") }

  before do
    allow(System::Providers::Registry).to receive(:for_volume).and_return(provider)
    allow(System::Providers::Registry).to receive(:for_instance).and_return(provider)
    allow(provider).to receive(:detach_volume).and_return({ success: true })
    allow(provider).to receive(:attach_volume).and_return({ success: true, device: "/dev/sdf" })
    allow(provider).to receive(:terminate_instance).and_return({ success: true })
  end

  def replace!(attrs = {})
    tool.execute(params: { action: "system_replace_instance",
                           instance_id: failed.id,
                           operation_id: "mcp-replace-1" }.merge(attrs))
  end

  def reap!(attrs = {})
    tool.execute(params: { action: "system_reap_instance",
                           instance_id: failed.id,
                           operation_id: "mcp-reap-1" }.merge(attrs))
  end

  def latest_deferred
    ::Ai::DeferredOperation.where(account_id: account.id).order(created_at: :desc).first
  end

  describe "the registry surface" do
    # A declaration on a tool nothing routes to is inert: BaseTool#execute is
    # only reached because PlatformApiToolRegistry maps the action name onto
    # this class. Asserting the map — not just the declaration — is what makes
    # "an operator can drive this" true.
    it "routes both verbs to SystemFleetTool" do
      aggregate_failures do
        expect(Ai::Tools::PlatformApiToolRegistry.all_tools["system_replace_instance"])
          .to eq("Ai::Tools::SystemFleetTool")
        expect(Ai::Tools::PlatformApiToolRegistry.all_tools["system_reap_instance"])
          .to eq("Ai::Tools::SystemFleetTool")
      end
    end

    it "publishes an input schema for each" do
      definitions = Ai::Tools::SystemFleetTool.action_definitions

      aggregate_failures do
        %w[system_replace_instance system_reap_instance].each do |action|
          expect(definitions[action]).to be_present, "#{action} has no action_definition"
          expect(definitions[action][:parameters][:instance_id]).to be_present
          expect(definitions[action][:parameters][:operation_id]).to be_present
        end
      end
    end

    # An agent reads the CATALOG, not the declaration. A gated verb whose
    # description reads as a plain write is one an agent reports as completed on
    # a pending envelope.
    it "announces the gate in the description an agent reads" do
      definitions = Ai::Tools::SystemFleetTool.action_definitions

      aggregate_failures do
        replace = definitions["system_replace_instance"][:description]
        expect(replace).to include("system.instance_replace")
        expect(replace).to match(/pending/i)

        reap = definitions["system_reap_instance"][:description]
        expect(reap).to include("system.instance_reap")
        expect(reap).to match(/pending/i)
      end
    end
  end

  describe "the declarations" do
    it "arms the gate on both verbs, naming the skill executor that replays them" do
      {
        "system_replace_instance" => %w[system.instance_replace
                                        System::Ai::Skills::ReplaceInstanceExecutor],
        "system_reap_instance"    => %w[system.instance_reap
                                        System::Ai::Skills::ReapInstanceExecutor]
      }.each do |action, (category, executor)|
        declaration = Ai::Tools::SystemFleetTool.declared_action(action)

        expect(declaration).to be_present, "#{action} is not declared at all"
        aggregate_failures action do
          expect(declaration[:mutating]).to be(true)
          expect(declaration[:action_category]).to eq(category)
          expect(declaration[:executor_class]).to eq(executor)
          expect(declaration[:gate_context]).to be_present
          expect(declaration[:on_proceed]).to be_present
        end
      end
    end

    # Two independently-typed spellings of one category drift apart silently:
    # Ai::InterventionPolicyService defaults EVERY unmatched category to
    # require_approval, so a misspelling still parks and every behavioural
    # example still passes while the operator's tuned row governs nothing.
    it "names the SAME categories the executors gate themselves on" do
      aggregate_failures do
        expect(Ai::Tools::SystemFleetTool.declared_action("system_replace_instance")[:action_category])
          .to eq(System::Ai::Skills::ReplaceInstanceExecutor.action_category)
        expect(Ai::Tools::SystemFleetTool.declared_action("system_reap_instance")[:action_category])
          .to eq(System::Ai::Skills::ReapInstanceExecutor.action_category)
      end
    end

    it "gates on categories the platform actually declares" do
      declared = System::Governance::PolicyDeclarations::FLEET_AUTONOMY_POLICIES

      aggregate_failures do
        expect(declared).to include("system.instance_replace")
        expect(declared).to include("system.instance_reap")
      end
    end
  end

  describe "authorization" do
    # A gated action never reaches #call, where this tool enforces its
    # per-action permissions — #authorization_error is the seam that keeps the
    # two in step, and a gated verb that skipped it would be an escalation
    # introduced by a safety control.
    it "refuses a caller without system.instances.control, and parks nothing" do
      nobody = create(:user, account: account, permissions: %w[system.nodes.read])
      weak   = Ai::Tools::SystemFleetTool.new(account: account, user: nobody)

      expect {
        result = weak.execute(params: { action: "system_replace_instance",
                                        instance_id: failed.id, operation_id: "nope" })
        expect(result[:success]).to be(false)
        expect(result[:error]).to eq("permission denied: system.instances.control required")
      }.not_to change(::Ai::DeferredOperation, :count)
    end
  end

  describe "driving a replace over MCP" do
    it "parks under system.instance_replace instead of acquiring the spare" do
      expect { replace! }.to change(::Ai::DeferredOperation, :count).by(1)

      expect(spare.reload.pool_state).to eq("ready"), "the replace ran despite the gate"
      expect(latest_deferred.action_category).to eq("system.instance_replace")
      expect(latest_deferred.executor_class)
        .to eq("System::Ai::Skills::ReplaceInstanceExecutor")
    end

    it "answers the caller with the pending envelope" do
      response = replace!

      expect(response[:success]).to be(true)
      expect(response[:data][:pending]).to be(true)
      expect(response[:data][:action_category]).to eq("system.instance_replace")
      expect(response[:data][:deferred_operation_id]).to eq(latest_deferred.id)
    end

    # "It parks" and "the parked operation still performs the work" are two
    # different claims, and only the second says the verb functions at all.
    # Nothing is stubbed between the operation and the replay, so a params-key
    # mismatch surfaces here rather than as a well-formed pending response.
    it "really replaces the instance when the parked operation is approved" do
      replace!

      latest_deferred.execute_now!

      expect(spare.reload.pool_state).to eq("claimed")
      expect(System::FleetEvent
               .where(account_id: account.id, kind: "system.instance_replace.acquire_replacement")
               .where("payload->>'operation_id' = ?", "mcp-replace-1")).to exist
    end

    # The additive half must not terminate anything, whichever door it came
    # through: the reap is a second approval on its own category.
    it "terminates nothing on the approved replace" do
      replace!
      latest_deferred.execute_now!

      expect(provider).not_to have_received(:terminate_instance)
      expect(failed.reload.status).to eq("error")
    end

    # BaseTool#validate_params! reads the TOOL's parameter definition, not the
    # action's, so `required: true` in action_definitions is advertised to the
    # caller and enforced by nobody. The gate context is the enforcement: both
    # executors are idempotent ON operation_id, so an approval parked without
    # one could not be told apart from a second replacement.
    it "refuses a call with no operation_id before parking anything" do
      expect {
        result = tool.execute(params: { action: "system_replace_instance",
                                        instance_id: failed.id })
        expect(result[:success]).to be(false)
        expect(result[:error]).to match(/operation_id is required/i)
      }.not_to change(::Ai::DeferredOperation, :count)
    end

    it "refuses an instance outside the account scope before parking anything" do
      other = create(:system_node_instance, name: "not-mine")

      expect {
        result = tool.execute(params: { action: "system_replace_instance",
                                        instance_id: other.id, operation_id: "x-account" })
        expect(result[:success]).to be(false)
      }.not_to change(::Ai::DeferredOperation, :count)
    end
  end

  describe "driving a reap over MCP" do
    it "parks under system.instance_reap instead of terminating" do
      expect { reap! }.to change(::Ai::DeferredOperation, :count).by(1)

      expect(provider).not_to have_received(:terminate_instance)
      expect(latest_deferred.action_category).to eq("system.instance_reap")
      expect(latest_deferred.executor_class).to eq("System::Ai::Skills::ReapInstanceExecutor")
    end

    it "really terminates when the parked operation is approved" do
      reap!

      latest_deferred.execute_now!

      expect(provider).to have_received(:terminate_instance).once
      expect(System::FleetEvent
               .where(account_id: account.id, kind: "system.instance_replace.reap")
               .where("payload->>'operation_id' = ?", "mcp-reap-1")).to exist
    end

    # The two verbs must not collapse into one category: an operator who tunes
    # system.instance_replace to a proceeding verb must NOT thereby have tuned
    # the terminate.
    it "does not park the reap under the replace's category" do
      reap!

      expect(latest_deferred.action_category).not_to eq("system.instance_replace")
    end
  end

  # THE PRECONDITION THE MCP DOOR REMOVED.
  #
  # Before these verbs, both executors were reachable from exactly one place —
  # System::Fleet::Sensors::InstanceUnrecoverableSensor deciding an instance was
  # unrecoverable — and the SENSOR was what made the word "unrecoverable" true.
  # A door that resolves any account-scoped id and goes straight to
  # detach/reattach volumes, move VIPs and (with reap) terminate would aim all
  # of that at a HEALTHY instance while showing the operator a card asserting a
  # classification nobody made.
  #
  # The oracle is the ROW, not the message: an operation must not exist.
  describe "the liveness precondition" do
    # Deliberately NOT a pool member: the point is that any account-scoped
    # instance was reachable, and a healthy workload node is the one a caller
    # must not be able to aim this lane at.
    let!(:live) do
      node = create(:system_node, account: account, node_template: node_template)
      create(:system_node_instance,
             node: node, name: "healthy-#{SecureRandom.hex(3)}", variety: "cloud",
             status: "running", provider_region: provider_region,
             provider_instance_type: provider_instance_type,
             last_heartbeat_at: 5.seconds.ago)
    end

    def replace_live(attrs = {})
      tool.execute(params: { action: "system_replace_instance", instance_id: live.id,
                             operation_id: "live-1" }.merge(attrs))
    end

    it "refuses to replace a running instance that is still reporting, and parks nothing" do
      expect {
        result = replace_live
        expect(result[:success]).to be(false)
        expect(result[:error]).to match(/still reporting|silence window/i)
      }.not_to change(::Ai::DeferredOperation, :count)
    end

    it "refuses to reap a running instance that is still reporting, and terminates nothing" do
      expect {
        result = tool.execute(params: { action: "system_reap_instance", instance_id: live.id,
                                        operation_id: "live-2" })
        expect(result[:success]).to be(false)
      }.not_to change(::Ai::DeferredOperation, :count)

      expect(provider).not_to have_received(:terminate_instance)
    end

    # The window is the ACCOUNT's resolved sensor threshold, not a literal, so
    # an operator who widens the sensor's silence window widens this door with
    # it. A spec pinning 180 would agree with the constant by coincidence and
    # keep agreeing after the setting moved.
    it "admits an instance silent for longer than the sensor's own threshold" do
      threshold = System::Fleet::Sensors::InstanceStatusSensor
                    .resolved_threshold("silent_threshold_seconds", account: account).to_i
      live.update!(last_heartbeat_at: (threshold + 60).seconds.ago)

      expect { replace_live }.to change(::Ai::DeferredOperation, :count).by(1)
    end

    # The sensor's own candidate shape is `last_heartbeat_at < cutoff OR NULL`,
    # so a never-reporting instance is exactly what the DR lane is for.
    it "admits an instance that has never reported" do
      live.update!(last_heartbeat_at: nil)

      expect { replace_live }.to change(::Ai::DeferredOperation, :count).by(1)
    end

    it "admits an explicit assertion of unrecoverability" do
      expect { replace_live(accept_running: true) }
        .to change(::Ai::DeferredOperation, :count).by(1)
    end

    # An override that the approver cannot see is not an assertion, it is a
    # bypass: the card has to say the classification came from the CALLER.
    it "records on the card that the classification was asserted, not observed" do
      replace_live(accept_running: true)

      expect(latest_deferred.description).to match(/CALLER ASSERTS/)
      expect(latest_deferred.description).to include("running")
    end

    # And on the ordinary path the card must not assert "unrecoverable" as
    # fact either — it reports what the platform actually observed.
    it "reports the observed status on an ordinary DR card" do
      replace!

      expect(latest_deferred.description).to include("error")
      expect(latest_deferred.description).not_to match(/CALLER ASSERTS/)
    end
  end

  # THE ASYMMETRY BETWEEN THE TWO VERBS, pinned rather than left incidental.
  describe "an MCP instance principal" do
    let(:instance_tool) do
      t = Ai::Tools::SystemFleetTool.new(account: account, user: nil)
      t.instance_authorized = true
      t
    end

    # The overlay is the authority for the destructive half; this asserts the
    # premise the refusal below is built on rather than assuming it.
    it "is denied system_reap_instance outright by the deny overlay" do
      expect(Mcp::Principal.destructive_tool?("system_reap_instance")).to be(true)
    end

    # ...and matches no pattern for the additive half, which is why the refusal
    # of `reap: true` has to live in the gate context.
    it "is not denied system_replace_instance by the deny overlay" do
      expect(Mcp::Principal.destructive_tool?("system_replace_instance")).to be(false)
    end

    it "may drive a plain replace" do
      expect {
        result = instance_tool.execute(params: { action: "system_replace_instance",
                                                 instance_id: failed.id,
                                                 operation_id: "inst-1" })
        expect(result[:success]).to be(true)
      }.to change(::Ai::DeferredOperation, :count).by(1)
    end

    # `reap: true` asks the replace to raise the very terminate the overlay
    # refuses this principal. Permitting it would re-open the denied door
    # through the permitted one.
    it "cannot reach the terminate through the replace" do
      expect {
        result = instance_tool.execute(params: { action: "system_replace_instance",
                                                 instance_id: failed.id,
                                                 operation_id: "inst-2", reap: true })
        expect(result[:success]).to be(false)
        expect(result[:error]).to match(/instance principal/i)
      }.not_to change(::Ai::DeferredOperation, :count)
    end
  end

  # Tripwire. A gated action returns before #call; reaching the dispatch arm
  # means something invoked #call directly and would otherwise have run a DR
  # replace (or a terminate) with no policy evaluation.
  describe "the #call dispatch arm" do
    it "refuses rather than performing the work" do
      %w[system_replace_instance system_reap_instance].each do |action|
        result = tool.send(:call, { action: action, instance_id: failed.id,
                                    operation_id: "direct" })

        expect(result[:success]).to be(false), "#{action} performed work from #call"
        expect(result[:error]).to match(/approval-gated/i)
      end

      expect(provider).not_to have_received(:terminate_instance)
      expect(spare.reload.pool_state).to eq("ready")
    end
  end
end
