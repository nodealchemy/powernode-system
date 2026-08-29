# frozen_string_literal: true

require "rails_helper"

# IMP-8d944d656c0b — BOTH PUBLIC-IP ENDPOINTS FAIL CLOSED ON EVERY REQUEST.
#
# THIS SPEC DOCUMENTS A LIVE DEFECT. It is NOT an endorsement of the behaviour
# it pins. The operator has PARKED the disposition (restore the two commands vs
# delete the two endpoints), so this spec records what the shipped code does
# today and stays honest under either ruling:
#
#   * under RESTORE it becomes the regression test that must FLIP — the
#     expectations below invert to "a task row lands, the operation completes";
#   * under DELETE it goes away with the endpoint it exercises.
#
# THE CHAIN (each link verified, not assumed):
#
#   NodeInstanceGating#gate_ip_action composes the category as a VARIABLE —
#   "system.task.#{event}" (node_instance_gating.rb:110) — with event coming
#   from node_instances_controller.rb:251 / :277. Neither
#   `associate_public_ip` nor `disassociate_public_ip` is in
#   System::Task::COMMANDS, so:
#
# TWO COMMITS REMOVED THESE VERBS, AND THE FAILURE MODE THIS SPEC PINS DATES
# FROM THE SECOND. 58702a16 ("retire the thirteen zero-caller dispatch verbs")
# dropped them from ExecutionDispatcher::COMMAND_REGISTRY and deleted
# System::Runtime::ManagePublicIp, but left COMMANDS alone — so in that window
# the Task INSERTED and failed later in the worker as "Unsupported command", a
# failed task row rather than a failed request. 04be5e5b ("restore the four
# dispatch verbs that DO have a producer, and make Task::COMMANDS a real
# validation") is what turned COMMANDS into an inclusion validation without
# these two, and only from there does the insert itself fail and produce the
# 422 below. Both windows are bugs; they are DIFFERENT bugs, with different
# signatures, and a restore that re-adds the commands without a dispatch route
# lands back in the first one.
#
#     Ai::AutonomyGate#evaluate CREATES an Ai::DeferredOperation (autonomy_gate.rb:80)
#       -> auto_approve => deferred.execute_now! runs it INLINE, in-request
#          (autonomy_gate.rb:88). Nothing is "parked": parking is the
#          require_approval branch, which these two categories do not take.
#         -> System::Executors::ExecuteTask#perform task.save! (execute_task.rb:30)
#           -> ActiveRecord::RecordInvalid, from
#              `validates :command, inclusion: { in: COMMANDS }, ... if: :command_changed?`
#              (task.rb) — on create the attribute goes nil -> value, which
#              reads as CHANGED, so the guard fires on every insert
#         -> Ai::DeferredOperation#execute_now! rescue: fail!(e) then re-raise
#            (deferred_operation.rb:168-171)
#       -> Ai::AutonomyGate#evaluate rescue returns :blocked (autonomy_gate.rb:101-104)
#     -> gate_ip_action renders 422 (node_instance_gating.rb:131-133)
#
# WHY THE ROWS, NOT THE STATUS. A status-only assertion is worthless here: 422
# is also what this endpoint returns for a physical instance, a local-hypervisor
# instance, a missing public IP, and a genuine policy block. The only assertions
# that distinguish "the command vocabulary refuses to insert" from those are the
# ROWS — no System::Task at all, and exactly one Ai::DeferredOperation left
# `failed` carrying the validation message.
#
# The pre-existing coverage at
# spec/controllers/api/v1/system/node_instances_controller_spec.rb:152-165
# asserts only the 403 arm for these two actions, which is precisely why this
# drifted unseen past commit 04be5e5b.
RSpec.describe "system node instance public-IP endpoints (gate outcome)", type: :request do
  let(:user) do
    user_with_permissions("system.instances.control", "system.instances.read",
                          "system.nodes.read")
  end
  let(:account) { user.account }

  # The default provider factory is `aws` — deliberately NOT local_qemu, so
  # NodeInstanceGating#local_hypervisor_rejection_message returns nil and the
  # request reaches the gate instead of short-circuiting on the provider check.
  let(:provider)        { create(:system_provider, account: account, provider_type: "aws") }
  let(:provider_region) { create(:system_provider_region, account: account, provider: provider) }
  let(:node)            { create(:system_node, account: account) }
  let!(:instance) do
    create(:system_node_instance, node: node, provider_region: provider_region,
                                  variety: "cloud", status: "running",
                                  public_ip_address: "203.0.113.10")
  end

  # A fresh spec account carries no Ai::InterventionPolicy rows and the service
  # falls through to its require_approval default, which on this install parks
  # an approval request (Ai::ApprovalChain IS core, so AutonomyGate's core-mode
  # auto-proceed fork never runs). PRODUCTION resolves these two categories to
  # auto_approve, so the rows are seeded here in exactly the shape the seed
  # writes (MANUAL_OPERATION_SCOPE + MANUAL_OPERATION_ATTRIBUTES). Without them
  # the spec would exercise the approval branch and never reach the insert that
  # is broken.
  #
  # THE VERB IS A LITERAL NOW, AND THAT IS A CHANGE WORTH READING (IMP-944567d41689).
  # This used to `.fetch` it from PolicyDeclarations::MANUAL_OPERATION_POLICIES,
  # with a raise saying a missing key meant either the DELETE disposition had
  # been executed or something was wrong. Neither happened. That constant is now
  # DERIVED from System::Task::COMMANDS, and these two verbs were never in
  # COMMANDS — so they left the declaration as a consequence of removing 19
  # phantom categories, not as a ruling on these two endpoints. The disposition
  # is STILL PARKED: the routes, NodeInstancesController#associate_public_ip /
  # #disassociate_public_ip and NodeInstanceGating#gate_ip_action are all
  # untouched, and this spec still pins the same 422.
  #
  # WHAT DID CHANGE, and it is operator-visible: these two categories are no
  # longer REGISTERED either (the engine derives registration from the same
  # constant). Production still carries both rows from the 07-16 seed run —
  # nothing deletes them, db:seed is first-boot only — so they keep rendering in
  # the Autonomy modal while PATCH /api/v1/system/autonomy now refuses to save
  # an edit to them. `db/seeds/system_autonomy_orphan_cleanup.rb` is the sweep
  # that would collect them, and it is seed-gated too.
  #
  # Under RESTORE this literal goes back to reading the declaration (the verbs
  # would be derived again the moment the commands rejoin COMMANDS). Under
  # DELETE this spec goes away with the endpoint it exercises.
  #
  # A `let`, not a constant: a bare constant assigned inside a describe block
  # lands on Object, which is this repo's recorded duplicate-constant clobber
  # class.
  let(:production_public_ip_verb) { "auto_approve" }

  before do
    %w[system.task.associate_public_ip system.task.disassociate_public_ip].each do |category|
      declarations = ::System::Governance::PolicyDeclarations

      ::Ai::InterventionPolicy.create!(
        account: account,
        action_category: category,
        **declarations::MANUAL_OPERATION_SCOPE,
        policy: production_public_ip_verb,
        **declarations::MANUAL_OPERATION_ATTRIBUTES
      )
    end
  end

  def post_ip_action(action)
    post "/api/v1/system/nodes/#{node.id}/node_instances/#{instance.id}/#{action}",
         headers: auth_headers_for(user)
  end

  # The rows are the oracle. `command` names the verb the endpoint composed, so
  # a task inserted under any other command would not acquit this endpoint.
  def assert_fails_closed!(command)
    operations = ::Ai::DeferredOperation.where(action_category: "system.task.#{command}")

    expect(::System::Task.count).to eq(0),
                                    "a System::Task row landed; the command vocabulary no longer refuses " \
                                    "#{command.inspect} and this spec must be inverted (see header)"
    expect(operations.count).to eq(1),
                                "expected exactly one deferred operation for system.task.#{command}"

    operation = operations.first
    expect(operation.status).to eq("failed")
    # Pins the LINK, not just the outcome: the failure has to be the command
    # inclusion validation, not a cross-account refusal, a missing operable or
    # any other RecordInvalid the same rescue would swallow identically.
    expect(operation.error_message).to include("ActiveRecord::RecordInvalid")
    expect(operation.error_message).to match(/Command is not included in the list/i)
  end

  describe "POST .../associate_public_ip" do
    it "creates no task and leaves a failed deferred operation (CURRENT BROKEN BEHAVIOUR)" do
      post_ip_action("associate_public_ip")
      assert_fails_closed!("associate_public_ip")
    end
  end

  describe "POST .../disassociate_public_ip" do
    it "creates no task and leaves a failed deferred operation (CURRENT BROKEN BEHAVIOUR)" do
      post_ip_action("disassociate_public_ip")
      assert_fails_closed!("disassociate_public_ip")
    end
  end

  # The sibling lifecycle verb through the SAME concern, same gate, same
  # executor — it differs only in that `stop` IS in System::Task::COMMANDS.
  # Without this arm a future breakage of the whole gate surface would leave
  # the two expectations above still green and still reading as a public-IP
  # finding.
  describe "the control arm (proves the gate surface itself works)" do
    before do
      ::Ai::InterventionPolicy.create!(
        account: account,
        action_category: "system.task.stop",
        **::System::Governance::PolicyDeclarations::MANUAL_OPERATION_SCOPE,
        policy: "auto_approve",
        **::System::Governance::PolicyDeclarations::MANUAL_OPERATION_ATTRIBUTES
      )
    end

    it "inserts a task for a listed command through the same executor" do
      post "/api/v1/system/nodes/#{node.id}/node_instances/#{instance.id}/stop",
           headers: auth_headers_for(user)

      expect(::System::Task.where(command: "stop").count).to eq(1)
      expect(::Ai::DeferredOperation.find_by(action_category: "system.task.stop").status)
        .to eq("completed")
    end
  end
end
