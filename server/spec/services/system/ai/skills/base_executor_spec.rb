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

  describe ".binds_to" do
    after { System::Ai::Skills::SkillBindings.reset! }

    it "registers the executor with SkillBindings under the named agents" do
      klass = Class.new(described_class) do
        def self.name; "System::Ai::Skills::ExampleBindsToExecutor"; end
        skill_descriptor(name: "ex", description: "x", category: "fleet",
                         inputs: {}, outputs: {})
        binds_to "Fleet Autonomy", "System Concierge"
      end

      reg = System::Ai::Skills::SkillBindings.all.find { |r| r[:executor] == klass }
      expect(reg[:agents]).to include("Fleet Autonomy", "System Concierge")
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
      expect(result[:error]).to match(/#perform must be defined/)
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

    it "wraps uncaught StandardError in a failure result" do
      result = raising_klass.new(account: account).execute
      expect(result[:success]).to be false
      expect(result[:error]).to eq("kaboom")
    end
  end

  describe "#tool helper" do
    let(:tool_klass) do
      Class.new do
        attr_reader :account, :agent, :user
        def initialize(account:, agent: nil, user: nil)
          @account = account
          @agent   = agent
          @user    = user
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
          success(account_id: built.account.id)
        end
      end
    end

    it "builds the tool with the executor's account/agent/user" do
      result = concrete.new(account: account).execute
      expect(result[:success]).to be true
      expect(result[:data][:account_id]).to eq(account.id)
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
