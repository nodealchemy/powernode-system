# frozen_string_literal: true

require "rails_helper"

# APO-1c (IMP-7e2bdc1774e4) — `requires_approval: true` on a skill descriptor
# used to be DESCRIPTIVE ONLY.
#
# BaseSkillExecutor#execute validated inputs, logged two lines and called
# #perform. Zero of the 55 executors referenced a policy seam, while 14 of them
# declared `requires_approval: true` in their descriptor — so an operator reading a descriptor saw a
# promise the code did not keep, and Ai::InterventionPolicy constrained the 60 s
# autonomy tick loop ONLY (System::Fleet::DecisionEngine resolves the policy
# itself before invoking). Every other door onto the same executors — the MCP
# arms (SdwanTool#run_skill_executor, SystemIngressTool#run_executor,
# SystemFleetTool), the REST controllers, and the Concierge router, which ran
# the executor and THEN rendered a confirmation card from the result — carried
# no policy check at all.
#
# These examples pin the gate at the one place every one of those doors passes:
# BEFORE #perform.
RSpec.describe "System::Ai::Skills::BaseSkillExecutor policy gate" do
  let(:account) { create(:account) }
  let(:user)    { create(:user, account: account) }

  # A named constant, because Ai::AutonomyGate stores `executor_class` as a
  # string and replays it by constantizing — an anonymous Class.new has no name
  # to store. stub_const rather than a bare constant assignment: a constant
  # assigned inside a describe block lands on Object and clobbers across files.
  let(:gated_class) do
    Class.new(System::Ai::Skills::BaseSkillExecutor) do
      # Records every instance that actually reached #perform, so an example can
      # tell "ran in-process on the caller's instance" from "ran on a rebuilt
      # one" and from "never ran".
      def self.performed_on
        @performed_on ||= []
      end

      skill_descriptor(
        name: "zz_gated_fixture",
        description: "gating fixture",
        category: "fleet",
        requires_approval: true,
        inputs: { widget_id: { type: "string", required: true } },
        outputs: { widget_id: :string }
      )

      protected

      def perform(widget_id:)
        self.class.performed_on << object_id
        success(widget_id: widget_id)
      end
    end
  end

  let(:ungated_class) do
    Class.new(System::Ai::Skills::BaseSkillExecutor) do
      def self.performed_on
        @performed_on ||= []
      end

      skill_descriptor(
        name: "zz_ungated_fixture",
        description: "no approval declared",
        category: "fleet",
        inputs: { widget_id: { type: "string", required: true } },
        outputs: {}
      )

      protected

      def perform(widget_id:)
        self.class.performed_on << object_id
        success(widget_id: widget_id)
      end
    end
  end

  before do
    stub_const("ZzGatedFixtureExecutor", gated_class)
    stub_const("ZzUngatedFixtureExecutor", ungated_class)
  end

  def policy!(verdict)
    Ai::InterventionPolicy.create!(
      account: account, action_category: "system.zz_gated_fixture",
      scope: "action_type", policy: verdict, priority: 10, is_active: true
    )
  end

  describe "the action category" do
    it "derives <domain>.<skill name> when the descriptor declares none" do
      expect(ZzGatedFixtureExecutor.action_category).to eq("system.zz_gated_fixture")
    end

    # The escape hatch that keeps the gate off a SECOND SPELLING of a control an
    # operator already has. Two real executors need it: the service-discovery
    # composer (registered as system.service_discovery_compose, not ...composer)
    # and the boot-image drift rollout (the tick loop gates it as
    # system.node_boot_image_drift).
    it "prefers an explicit action_category: on the descriptor" do
      klass = Class.new(System::Ai::Skills::BaseSkillExecutor) do
        skill_descriptor(
          name: "zz_renamed_fixture", description: "d", category: "fleet",
          requires_approval: true, action_category: "system.pre_existing_control",
          inputs: {}, outputs: {}
        )
      end

      expect(klass.action_category).to eq("system.pre_existing_control")
    end

    # THE RATCHET LIVES ELSEWHERE, deliberately: a gated executor whose category
    # is registered nowhere cannot be tuned by an operator
    # (System::AutonomyActions#update refuses it), so the gate would be stuck at
    # the require_approval default forever. That invariant is asserted over the
    # REAL executors in
    # spec/lib/powernode_system/autonomy_categories_registration_spec.rb, which
    # is where the registration it checks lives.
    it "matches a registered category for every real gated executor (see the registration spec)" do
      expect(Ai::InterventionPolicy.category_registered?(
               System::Ai::Skills::ExposeServicePublicTcpExecutor.action_category
             )).to be true
    end
  end

  describe "an executor that declares requires_approval: true" do
    it "does NOT reach #perform when policy resolves to require_approval" do
      policy!("require_approval")

      result = ZzGatedFixtureExecutor.new(account: account, user: user)
                                     .execute(widget_id: "w-1")

      expect(ZzGatedFixtureExecutor.performed_on).to be_empty,
        "requires_approval is descriptive only — #perform ran before any policy was consulted"
      # APO-1f (IMP-117b34656921): the PLATFORM'S pending envelope, not a
      # failure. The full shape is pinned in
      # base_skill_executor_pending_envelope_spec.rb.
      expect(result[:pending]).to be true
      expect(result.dig(:data, :message)).to match(/Approval required: system\.zz_gated_fixture/)
      expect(result.dig(:data, :message)).to include(Ai::ApprovalRequest.last.id)
    end

    # THE ROLLBACK-FAKING ORACLE, restated for APO-1f.
    #
    # Ai::Provisioning::SkillCompositionRunner reads every non-control key on a
    # FAILURE envelope as a resource this run created (#failure_outputs_from
    # strips only success/error/message/errors/failures/partial) and hands what
    # survives to the step's rollback hook before stamping it compensated. A
    # parked approval created nothing, so the ids this envelope now carries must
    # never reach that path — which they cannot, because a parked envelope is no
    # longer a failure at all. The runner's own half (park, do not roll back) is
    # pinned in spec/services/ai/provisioning/skill_composition_runner_parked_approval_spec.rb.
    it "is not a failure envelope, so the runner's rollback path is unreachable for it" do
      policy!("require_approval")

      result = ZzGatedFixtureExecutor.new(account: account, user: user)
                                     .execute(widget_id: "w-1")

      expect(result[:success]).to be true
      expect(result[:error]).to be_nil
    end

    it "parks a DeferredOperation naming this executor, so the approval can be replayed" do
      policy!("require_approval")

      ZzGatedFixtureExecutor.new(account: account, user: user).execute(widget_id: "w-1")

      op = Ai::DeferredOperation.where(account: account).last
      expect(op).to be_present
      expect(op.action_category).to eq("system.zz_gated_fixture")
      expect(op.executor_class).to eq("ZzGatedFixtureExecutor")
      expect(op.params.deep_symbolize_keys).to eq(widget_id: "w-1")
    end

    it "refuses outright when policy blocks, without reaching #perform" do
      policy!("block")

      result = ZzGatedFixtureExecutor.new(account: account, user: user)
                                     .execute(widget_id: "w-1")

      expect(ZzGatedFixtureExecutor.performed_on).to be_empty
      expect(result[:success]).to be false
      expect(result[:error]).to match(/blocked by policy/i)
    end

    it "defaults to gating when NO policy row matches — the descriptor is the floor" do
      result = ZzGatedFixtureExecutor.new(account: account, user: user)
                                     .execute(widget_id: "w-1")

      expect(ZzGatedFixtureExecutor.performed_on).to be_empty
      expect(result[:pending]).to be true
    end

    it "runs IN-PROCESS on the caller's own instance under an auto-execute policy" do
      policy!("notify_and_proceed")

      executor = ZzGatedFixtureExecutor.new(account: account, user: user)
      result = executor.execute(widget_id: "w-1")

      expect(result[:success]).to be true
      # The SAME object, not one Ai::DeferredOperation rebuilt from a row: a
      # rebuild drops the instance provenance #tool reads (IMP-0e6b216de843).
      expect(ZzGatedFixtureExecutor.performed_on).to eq([ executor.object_id ])
      expect(Ai::DeferredOperation.where(account: account).count).to eq(0)
    end

    it "validates declared inputs BEFORE the gate — a doomed call parks no approval" do
      policy!("require_approval")

      result = ZzGatedFixtureExecutor.new(account: account, user: user).execute

      expect(result[:success]).to be false
      expect(result[:error]).to match(/missing required input: widget_id/)
      expect(Ai::DeferredOperation.where(account: account).count).to eq(0)
    end
  end

  describe "gated: true — the autonomy tick loop's opt-out" do
    # System::Fleet::DecisionEngine resolves the InterventionPolicy itself
    # (#invoke_skill, and #execute_approved! replaying an approved request)
    # before it builds the executor, so a second gate here would park an
    # approval for a decision that was already made.
    it "skips the gate entirely" do
      policy!("require_approval")

      result = ZzGatedFixtureExecutor.new(account: account, user: nil)
                                     .execute(gated: true, widget_id: "w-1")

      expect(result[:success]).to be true
      expect(ZzGatedFixtureExecutor.performed_on.size).to eq(1)
      expect(Ai::DeferredOperation.where(account: account).count).to eq(0)
    end

    it "does not leak the gated keyword into #perform" do
      result = ZzGatedFixtureExecutor.new(account: account, user: nil)
                                     .execute(gated: true, widget_id: "w-1")

      expect(result.dig(:data, :widget_id)).to eq("w-1")
    end
  end

  describe "an executor that does NOT declare requires_approval" do
    it "is untouched — no policy resolution, no deferred operation" do
      result = ZzUngatedFixtureExecutor.new(account: account, user: user)
                                       .execute(widget_id: "w-1")

      expect(result[:success]).to be true
      expect(ZzUngatedFixtureExecutor.performed_on.size).to eq(1)
      expect(Ai::DeferredOperation.where(account: account).count).to eq(0)
    end
  end

  describe "nested executors (#executor)" do
    let(:composer_class) do
      Class.new(System::Ai::Skills::BaseSkillExecutor) do
        skill_descriptor(
          name: "zz_composer_fixture",
          description: "nests a gated peer",
          category: "fleet",
          requires_approval: true,
          inputs: { widget_id: { type: "string", required: true } },
          outputs: {}
        )

        protected

        def perform(widget_id:)
          success(inner: executor(ZzGatedFixtureExecutor).execute(widget_id: widget_id))
        end
      end
    end

    let(:ungated_composer_class) do
      Class.new(System::Ai::Skills::BaseSkillExecutor) do
        skill_descriptor(
          name: "zz_ungated_composer_fixture",
          description: "declares no approval, still nests a gated peer",
          category: "fleet",
          inputs: { widget_id: { type: "string", required: true } },
          outputs: {}
        )

        protected

        def perform(widget_id:)
          success(inner: executor(ZzGatedFixtureExecutor).execute(widget_id: widget_id))
        end
      end
    end

    before do
      stub_const("ZzComposerFixtureExecutor", composer_class)
      stub_const("ZzUngatedComposerFixtureExecutor", ungated_composer_class)
    end

    def composer_policy!(verdict)
      Ai::InterventionPolicy.create!(
        account: account, action_category: "system.zz_composer_fixture",
        scope: "action_type", policy: verdict, priority: 10, is_active: true
      )
    end

    # A NESTED PEER NEVER PARKS. Ai::DeferredOperation#execute_now! replays the
    # CHILD alone, so an approval parked halfway down a composition can never
    # resume the composer — approving it would run one step of a plan whose
    # remaining steps are gone. The operator-visible unit is the outermost call.
    it "does not park a second approval under a composer whose own gate cleared" do
      composer_policy!("notify_and_proceed")
      policy!("require_approval")

      result = ZzComposerFixtureExecutor.new(account: account, user: user)
                                        .execute(widget_id: "w-1")

      expect(result[:success]).to be true
      expect(result.dig(:data, :inner, :success)).to be true
      expect(Ai::DeferredOperation.where(account: account).count).to eq(0)
    end

    # The case that broke a live lane before it was written down: the composer
    # declares NO approval of its own, so there is no parent clearance to
    # inherit. Gating the child on its own default would have turned every such
    # composition into a per-child approval storm reported as a failed plan.
    it "does not park under an UNGATED composer either" do
      policy!("require_approval")

      result = ZzUngatedComposerFixtureExecutor.new(account: account, user: user)
                                               .execute(widget_id: "w-1")

      expect(result[:success]).to be true
      expect(result.dig(:data, :inner, :success)).to be true
      expect(Ai::DeferredOperation.where(account: account).count).to eq(0)
    end

    # DENY STILL WINS. Not parking is not the same as not gating: an operator
    # who blocks the child's category has said no to the action however it is
    # reached, and a composer must not be a door around that.
    it "still refuses a nested peer whose OWN category is blocked" do
      composer_policy!("notify_and_proceed")
      policy!("block")

      result = ZzComposerFixtureExecutor.new(account: account, user: user)
                                        .execute(widget_id: "w-1")

      expect(ZzGatedFixtureExecutor.performed_on).to be_empty
      expect(result.dig(:data, :inner, :success)).to be false
      expect(result.dig(:data, :inner, :error)).to match(/blocked by policy/i)
    end

    it "refuses a blocked nested peer under an UNGATED composer too" do
      policy!("block")

      result = ZzUngatedComposerFixtureExecutor.new(account: account, user: user)
                                               .execute(widget_id: "w-1")

      expect(ZzGatedFixtureExecutor.performed_on).to be_empty
      expect(result.dig(:data, :inner, :error)).to match(/blocked by policy/i)
    end
  end

  describe ".execute(params, deferred_operation:) — the approval replay seam" do
    # Ai::DeferredOperation#execute_now! calls this after a chain approves. It
    # has to exist, or every parked skill approval is a dead end.
    it "rebuilds the executor and runs it with the gate already satisfied" do
      policy!("require_approval")

      op = Ai::DeferredOperation.create!(
        account: account, action_category: "system.zz_gated_fixture",
        executor_class: "ZzGatedFixtureExecutor", params: { "widget_id" => "w-9" },
        requested_by: user
      )

      result = ZzGatedFixtureExecutor.execute(op.params, deferred_operation: op)

      expect(result[:success]).to be true
      expect(result.dig(:data, :widget_id)).to eq("w-9")
      # No SECOND approval parked by the replay.
      expect(Ai::DeferredOperation.where(account: account).count).to eq(1)
    end
  end
end
