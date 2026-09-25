# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Ai::Skills::BaseSkillExecutor do
  let(:account) { create(:account) }

  describe ".skill_descriptor + .descriptor" do
    it "memoizes the frozen descriptor" do
      klass = Class.new(described_class) do
        skill_descriptor(
          name: "test_skill",
          description: "for spec",
          category: "fleet",
          inputs:  { id: { type: "string", required: true } },
          outputs: { id: :string }
        )
      end

      d = klass.descriptor
      expect(d).to be_frozen
      expect(d[:name]).to eq("test_skill")
      expect(d[:requires_approval]).to be false
      expect(d[:invocation_mode]).to eq("one_shot")
      expect(d[:domain]).to eq("system")
    end

    it "raises if descriptor was never declared" do
      klass = Class.new(described_class)
      expect { klass.descriptor }.to raise_error(NotImplementedError, /skill_descriptor/)
    end
  end

  describe "#execute keyword tolerance (dryrun 20260809c)" do
    # The composer hands every composed step a superset of inputs — notably
    # the shared `brief` — while executors declare strict keyword signatures.
    # Live, every docker_provision step failed `ArgumentError: unknown
    # keyword: :brief` before perform ran. execute now slices the inputs to
    # the keywords #perform declares, unless perform captures **rest (the
    # executor's explicit opt-in to extras).
    let(:strict_class) do
      Class.new(described_class) do
        skill_descriptor(
          name: "strict_skill", description: "for spec", category: "fleet",
          inputs: { node_instance_id: { type: "string", required: true } },
          outputs: {}
        )

        protected

        def perform(node_instance_id:, dry_run: false)
          success(received: { node_instance_id: node_instance_id, dry_run: dry_run })
        end
      end
    end

    let(:tolerant_class) do
      Class.new(described_class) do
        skill_descriptor(
          name: "tolerant_skill", description: "for spec", category: "fleet",
          inputs: { node_instance_id: { type: "string", required: true } },
          outputs: {}
        )

        protected

        def perform(node_instance_id:, **extras)
          success(received: { node_instance_id: node_instance_id, extras: extras })
        end
      end
    end

    it "slices undeclared keywords away from a strict perform signature" do
      result = strict_class.new(account: account)
                           .execute(node_instance_id: "i-1", brief: { "intent" => "x" }, dry_run: true)
      expect(result[:success]).to be true
      expect(result.dig(:data, :received)).to eq(node_instance_id: "i-1", dry_run: true)
    end

    it "passes everything through when perform captures **rest" do
      result = tolerant_class.new(account: account)
                             .execute(node_instance_id: "i-1", brief: { "intent" => "x" })
      expect(result[:success]).to be true
      expect(result.dig(:data, :received, :extras)).to eq(brief: { "intent" => "x" })
    end

    it "still enforces declared required inputs before slicing" do
      result = strict_class.new(account: account).execute(brief: {})
      expect(result[:success]).to be false
      expect(result[:error]).to match(/missing required input: node_instance_id/)
    end
  end

  describe ".binds_to" do
    # Targeted unregister — DON'T use a wholesale `reset!`. Under CI's
    # eager_load, @registrations is populated at boot with every binds_to
    # declaration in production code, and a `reset!` here would orphan
    # those for the rest of the suite (which is what bit crud_factory_spec).
    after do
      System::Ai::Skills::SkillBindings.unregister("System::Ai::Skills::ExampleBindsToExecutor")
    end

    it "registers the executor with SkillBindings under the named agents" do
      klass = Class.new(described_class) do
        def self.name; "System::Ai::Skills::ExampleBindsToExecutor"; end
        skill_descriptor(name: "ex", description: "x", category: "fleet",
                         inputs: {}, outputs: {})
        binds_to "fleet-autonomy", "system-concierge"
      end

      reg = System::Ai::Skills::SkillBindings.all.find { |r| r[:executor] == klass }
      expect(reg[:agents]).to include("fleet-autonomy", "system-concierge")
    end
  end

  describe "#initialize" do
    it "requires an account" do
      expect { described_class.new(account: nil) }
        .to raise_error(ArgumentError, /account is required/)
    end

    it "exposes account, agent, user via attr_readers" do
      agent = instance_double("Ai::Agent")
      user  = instance_double("User")
      inst  = described_class.new(account: account, agent: agent, user: user)

      expect(inst.account).to eq(account)
      expect(inst.agent).to   eq(agent)
      expect(inst.user).to    eq(user)
    end
  end

  describe "#execute (abstract enforcement)" do
    let(:abstract_klass) do
      Class.new(described_class) do
        skill_descriptor(name: "abstract", description: "x", category: "fleet",
                         inputs: {}, outputs: {})
      end
    end

    it "returns a failure result when #perform is not overridden" do
      result = abstract_klass.new(account: account).execute
      expect(result[:success]).to be false
      expect(result[:error]).to eq("This skill's #perform is not implemented")
    end
  end

  describe "#execute (happy path)" do
    let(:concrete_klass) do
      Class.new(described_class) do
        skill_descriptor(
          name: "echo", description: "echo for spec", category: "fleet",
          inputs:  { msg: { type: "string", required: true } },
          outputs: { msg: :string }
        )
        def perform(msg:)
          success(echoed: msg)
        end
      end
    end

    it "returns a success hash with the perform payload" do
      result = concrete_klass.new(account: account).execute(msg: "hi")
      expect(result).to eq(success: true, data: { echoed: "hi" })
    end
  end

  describe "#execute (required-input validation)" do
    let(:gated_klass) do
      Class.new(described_class) do
        skill_descriptor(
          name: "gated", description: "x", category: "fleet",
          inputs:  { id: { type: "string", required: true } },
          outputs: { id: :string }
        )
        def perform(id:); success(id: id); end
      end
    end

    it "fails when a required input is missing" do
      result = gated_klass.new(account: account).execute
      expect(result[:success]).to be false
      expect(result[:error]).to match(/missing required input: id/)
    end

    it "passes when the required input is provided" do
      result = gated_klass.new(account: account).execute(id: "x")
      expect(result).to eq(success: true, data: { id: "x" })
    end
  end

  describe "#execute (exception trapping)" do
    let(:raising_klass) do
      Class.new(described_class) do
        skill_descriptor(name: "boom", description: "x", category: "fleet",
                         inputs: {}, outputs: {})
        def perform; raise StandardError, "kaboom"; end
      end
    end

    # IMP-8552945f2672 — this used to assert result[:error] == "kaboom": the
    # #perform exception's OWN raw message, forwarded verbatim. #perform is
    # subclass-authored, unaudited code that can raise ANYTHING; that result
    # reaches the model provider via system_ingress_tool.rb#run_executor /
    # sdwan_tool.rb#run_skill_executor, which forward it verbatim.
    it "answers a generic caller-facing error, never the raw exception message" do
      result = raising_klass.new(account: account).execute
      expect(result[:success]).to be false
      expect(result[:error]).to eq("An internal error occurred processing this request.")
      expect(result[:error]).not_to include("kaboom")
    end

    it "still logs the full raw exception server-side via audit_log_error" do
      executor = raising_klass.new(account: account)
      expect(executor).to receive(:audit_log_error) do |e|
        expect(e).to be_a(StandardError)
        expect(e.message).to eq("kaboom")
      end
      executor.execute
    end

    # CallerFacingError is the ONE opt-in that survives to the caller — the
    # positive control proving the assertions above are not vacuously true
    # because EVERYTHING gets flattened regardless of what was raised.
    it "still forwards a CallerFacingError's own message" do
      caller_facing_klass = Class.new(described_class) do
        skill_descriptor(name: "boom_cf", description: "x", category: "fleet",
                         inputs: {}, outputs: {})
        def perform
          raise ::Ai::Tools::BaseTool::CallerFacingError, "widget_id not found in this account"
        end
      end
      result = caller_facing_klass.new(account: account).execute
      expect(result[:success]).to be false
      expect(result[:error]).to eq("widget_id not found in this account")
    end

    # ActiveRecord::RecordNotFound gets its own authored not-found text
    # (IMP-f6f80b585b19's not_found_message), not the generic default and not
    # the raw scoped-relation message (which would carry a
    # ` [WHERE ...]` suffix naming internal schema).
    it "answers ActiveRecord::RecordNotFound with the authored not-found text, never the WHERE-clause message" do
      not_found_klass = Class.new(described_class) do
        skill_descriptor(name: "boom_nf", description: "x", category: "fleet",
                         inputs: {}, outputs: {})
        def perform
          ::Account.where(id: account.id).find("does-not-exist")
        end
      end
      result = not_found_klass.new(account: account).execute
      expect(result[:success]).to be false
      expect(result[:error]).to eq(%(Couldn't find Account with 'id'="does-not-exist"))
      expect(result[:error]).not_to include("WHERE")
      expect(result[:error]).not_to include("accounts")
    end

    # IMP-8552945f2672 review round 3 — an authored static string, not
    # NotImplementedError's own message (which names the internal executor
    # class, and which Ruby itself raises too).
    it "answers an unbuilt #perform with an authored static string, never NotImplementedError's message" do
      abstract_klass = Class.new(described_class) do
        skill_descriptor(name: "boom_ni", description: "x", category: "fleet",
                         inputs: {}, outputs: {})
      end
      result = abstract_klass.new(account: account).execute
      expect(result[:success]).to be false
      expect(result[:error]).to eq("This skill's #perform is not implemented")
      expect(result[:error]).not_to include("must be defined")
    end

    # ActiveRecord::RecordInvalid is NOT forwarded — the operator direction is
    # literal: "forward ONLY CallerFacingError messages". Even though
    # RecordInvalid#message is structurally bounded to Rails's own validation
    # vocabulary plus the model's OWN `validates` declarations (unlike
    # PoolError/CompositionConflictError, which had raise sites wrapping
    # arbitrary inner content), full_messages is still a cross-tenant
    # existence oracle wherever a uniqueness validator is unscoped (e.g.
    # sdwan/network.rb's cidr_64, account_bgp.rb's as_number): "already
    # taken" discloses that some OTHER account holds the value the caller
    # supplied. So this authors its own text naming only the ATTRIBUTE that
    # failed, never the validation message and never a value.
    it "answers an authored message naming only the attribute, never RecordInvalid's own message" do
      invalid_klass = Class.new(described_class) do
        skill_descriptor(name: "boom_invalid", description: "x", category: "fleet",
                         inputs: {}, outputs: {})
        def perform
          account.update!(name: nil)
        end
      end
      result = invalid_klass.new(account: account).execute
      expect(result[:success]).to be false
      expect(result[:error]).to eq("Validation failed: name")
      expect(result[:error]).not_to include("blank")
      expect(result[:error]).not_to eq("An internal error occurred processing this request.")
    end

    # Mcp::ProtocolService::PermissionDeniedError is likewise NOT forwarded.
    # Every raise site of this class happens to interpolate only a safe
    # tool/action/permission name, but "only ever safe text so far" is a
    # weaker guarantee than CallerFacingError's explicit opt-in, and the
    # operator direction was literal about the whitelist — so this authors a
    # static stand-in instead of trusting e.message.
    it "answers a static denial message, never PermissionDeniedError's own message" do
      # The instance-deny overlay (IMP-0e6b216de843) raises this class when a
      # skill executor nests a tool call that turns out destroy-shaped for an
      # instance principal — see nested_executor_instance_principal_spec.rb,
      # which asserts /destroy-shaped|denied/i and still passes on this
      # static text because it says "denied".
      denied_klass = Class.new(described_class) do
        skill_descriptor(name: "boom_denied", description: "x", category: "fleet",
                         inputs: {}, outputs: {})
        def perform
          raise ::Mcp::ProtocolService::PermissionDeniedError,
                "Action 'system_delete_architecture' is destroy-shaped and is denied to every " \
                "instance principal, whatever it was granted"
        end
      end
      result = denied_klass.new(account: account).execute
      expect(result[:success]).to be false
      expect(result[:error]).to eq("Permission denied for this action")
      expect(result[:error]).not_to include("destroy-shaped")
      expect(result[:error]).not_to include("system_delete_architecture")
    end
  end

  # IMP-8552945f2672 review round 3 — a subclass's LOCAL rescue arm returns
  # an ordinary failure result, so #audit_log_error never fires for it.
  # safe_error_text itself must keep the cause for the operator: a server-side
  # log line and the finish event's `withheld_error`, while the caller still
  # sees only the generic text.
  describe "#execute (local rescue arm keeps the cause server-side)" do
    let(:local_arm_klass) do
      Class.new(described_class) do
        skill_descriptor(name: "local_arm", description: "x", category: "fleet",
                         inputs: {}, outputs: {})
        def perform
          raise StandardError, "docker daemon: connection refused at /var/run/internal.sock"
        rescue StandardError => e
          failure(safe_error_text(e))
        end
      end
    end

    it "returns the generic text but logs and audits the raw cause" do
      logged = []
      allow(Rails.logger).to receive(:error).and_wrap_original do |m, msg = nil, &blk|
        logged << (msg || blk&.call).to_s
        m.call(msg, &blk)
      end
      finished = []
      allow(::System::Fleet::EventBroadcaster).to receive(:emit!).and_wrap_original do |m, **kw|
        finished << kw[:payload] if kw[:kind] == described_class::EVENT_KIND_FINISHED
        m.call(**kw)
      end

      result = local_arm_klass.new(account: account).execute

      expect(result[:error]).to eq("An internal error occurred processing this request.")
      expect(logged).to include(a_string_including("StandardError", "connection refused at /var/run/internal.sock"))
      expect(finished.size).to eq(1)
      expect(finished.first["error"]).to eq("An internal error occurred processing this request.")
      expect(finished.first["withheld_error"]).to include("connection refused at /var/run/internal.sock")
    end

    it "records nothing for a CallerFacingError, which is forwarded verbatim" do
      forwarded_klass = Class.new(described_class) do
        skill_descriptor(name: "local_arm_cf", description: "x", category: "fleet",
                         inputs: {}, outputs: {})
        def perform
          raise ::Ai::Tools::BaseTool::CallerFacingError, "widget_id not found in this account"
        rescue StandardError => e
          failure(safe_error_text(e))
        end
      end
      finished = []
      allow(::System::Fleet::EventBroadcaster).to receive(:emit!).and_wrap_original do |m, **kw|
        finished << kw[:payload] if kw[:kind] == described_class::EVENT_KIND_FINISHED
        m.call(**kw)
      end

      result = forwarded_klass.new(account: account).execute

      expect(result[:error]).to eq("widget_id not found in this account")
      expect(finished.first).not_to have_key("withheld_error")
    end
  end

  describe "#tool helper" do
    let(:tool_klass) do
      Class.new do
        attr_reader :account, :agent, :user, :internal, :call_origin
        # Mirrors Ai::Tools::BaseTool#initialize, `internal:` and `call_origin:`
        # included. The helper declares a userless executor as an in-process
        # system caller rather than leaving the tool to infer it
        # (IMP-9030413bc292), and names the door its tools are built through
        # (MCP identity plan: skill_executor).
        def initialize(account:, agent: nil, user: nil, internal: false, call_origin: nil)
          @account     = account
          @agent       = agent
          @user        = user
          @internal    = internal
          @call_origin = call_origin
        end
      end
    end

    let(:concrete) do
      tk = tool_klass
      Class.new(described_class) do
        skill_descriptor(name: "tools", description: "x", category: "fleet",
                         inputs: {}, outputs: {})
        define_method(:perform) do
          built = tool(tk)
          success(account_id: built.account.id, internal: built.internal, user_id: built.user&.id,
                  call_origin: built.call_origin)
        end
      end
    end

    it "builds the tool with the executor's account/agent/user, through the skill executor's door" do
      result = concrete.new(account: account).execute
      expect(result[:success]).to be true
      expect(result[:data][:account_id]).to eq(account.id)
      expect(result[:data][:call_origin]).to eq(::Ai::Tools::CallOrigin::SKILL_EXECUTOR)
    end

    # IMP-9030413bc292 — a userless executor IS an in-process system caller
    # (System::Fleet::DecisionEngine builds autonomy executors with user: nil),
    # so it says so explicitly instead of relying on the tool reading `user.nil?`
    # as "internal" — an inference that also swept in MCP instance principals.
    it "declares a userless executor's tool calls as internal" do
      result = concrete.new(account: account).execute
      expect(result[:data][:internal]).to be true
    end

    it "does not mark a user-bearing executor's tool calls as internal" do
      user = create(:user, account: account)
      result = concrete.new(account: account, user: user).execute

      expect(result[:data][:internal]).to be false
      expect(result[:data][:user_id]).to eq(user.id)
    end
  end

  describe "#success / #failure shape" do
    let(:klass) do
      Class.new(described_class) do
        skill_descriptor(name: "shape", description: "x", category: "fleet",
                         inputs: {}, outputs: {})
        def perform(mode:)
          mode == "ok" ? success(value: 1) : failure("nope")
        end
      end
    end

    it "returns canonical success shape" do
      expect(klass.new(account: account).execute(mode: "ok"))
        .to eq(success: true, data: { value: 1 })
    end

    it "returns canonical failure shape" do
      expect(klass.new(account: account).execute(mode: "no"))
        .to eq(success: false, error: "nope")
    end
  end
end
