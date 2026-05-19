# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Ai::Skills::CrudFactory do
  let(:account) { create(:account) }
  let(:tool_stub) { instance_double(::Ai::Tools::SystemArchitectureCatalogTool) }

  describe "ROUTES" do
    it "covers the architecture CRUD operations" do
      expect(described_class::ROUTES.keys).to contain_exactly(
        [ "architecture", "create" ],
        [ "architecture", "update" ],
        [ "architecture", "delete" ]
      )
    end

    it "routes architecture operations to SystemArchitectureCatalogTool" do
      described_class::ROUTES.each_value do |(tool_class, _action)|
        expect(tool_class).to eq(::Ai::Tools::SystemArchitectureCatalogTool)
      end
    end
  end

  describe "#crud_perform" do
    let(:subclass) do
      Class.new(described_class) do
        def self.name; "System::Ai::Skills::ExampleCreateExecutor"; end
        skill_descriptor(
          name: "example_create", description: "spec", category: "fleet",
          inputs:  { name: { type: "string", required: true } },
          outputs: { architecture: :object }
        )

        def perform(name:)
          crud_perform(resource: "architecture", operation: "create", payload: { name: name })
        end
      end
    end

    before do
      allow(::Ai::Tools::SystemArchitectureCatalogTool).to receive(:new).and_return(tool_stub)
    end

    it "dispatches to the registered tool action and wraps the success result" do
      expect(tool_stub).to receive(:execute)
        .with(params: { name: "amd64", action: "system_create_architecture" })
        .and_return(success: true, data: { id: "arch-1", name: "amd64" })

      result = subclass.new(account: account).execute(name: "amd64")

      expect(result[:success]).to be true
      expect(result[:data]).to eq(id: "arch-1", name: "amd64")
    end

    it "wraps a tool failure in the canonical failure shape" do
      expect(tool_stub).to receive(:execute).and_return(success: false, error: "permission denied")

      result = subclass.new(account: account).execute(name: "amd64")

      expect(result[:success]).to be false
      expect(result[:error]).to eq("permission denied")
    end

    it "fails with an explicit error for unknown routes" do
      klass = Class.new(described_class) do
        def self.name; "System::Ai::Skills::BadRouteExecutor"; end
        skill_descriptor(
          name: "bad_route", description: "spec", category: "fleet",
          inputs:  {}, outputs: {}
        )
        def perform
          crud_perform(resource: "nonexistent", operation: "whatever", payload: {})
        end
      end

      result = klass.new(account: account).execute
      expect(result[:success]).to be false
      expect(result[:error]).to match(/unsupported CrudFactory route: nonexistent\/whatever/)
    end
  end

  describe "ArchitectureCreateExecutor (canonical subclass)" do
    it "is a CrudFactory subclass" do
      expect(System::Ai::Skills::ArchitectureCreateExecutor.ancestors).to include(described_class)
    end

    it "binds to Fleet Autonomy" do
      reg = System::Ai::Skills::SkillBindings.all
        .find { |r| r[:executor] == System::Ai::Skills::ArchitectureCreateExecutor }
      expect(reg).not_to be_nil
      expect(reg[:agents]).to include("Fleet Autonomy")
    end

    it "delegates name + family to system_create_architecture action" do
      allow(::Ai::Tools::SystemArchitectureCatalogTool).to receive(:new).and_return(tool_stub)
      expect(tool_stub).to receive(:execute)
        .with(params: hash_including(
          action: "system_create_architecture",
          name: "loongarch64",
          family: "other"
        ))
        .and_return(success: true, data: { id: "arch-x" })

      result = System::Ai::Skills::ArchitectureCreateExecutor
        .new(account: account)
        .execute(name: "loongarch64", family: "other")

      expect(result[:success]).to be true
    end
  end

  describe "ArchitectureUpdateExecutor (canonical subclass)" do
    it "delegates architecture_id + attributes to system_update_architecture action" do
      allow(::Ai::Tools::SystemArchitectureCatalogTool).to receive(:new).and_return(tool_stub)
      expect(tool_stub).to receive(:execute)
        .with(params: hash_including(
          action: "system_update_architecture",
          architecture_id: "arch-x",
          attributes: { description: "updated" }
        ))
        .and_return(success: true, data: { id: "arch-x" })

      result = System::Ai::Skills::ArchitectureUpdateExecutor
        .new(account: account)
        .execute(architecture_id: "arch-x", attributes: { description: "updated" })

      expect(result[:success]).to be true
    end
  end

  describe "ArchitectureDeleteExecutor (canonical subclass)" do
    it "delegates architecture_id to system_delete_architecture action" do
      allow(::Ai::Tools::SystemArchitectureCatalogTool).to receive(:new).and_return(tool_stub)
      expect(tool_stub).to receive(:execute)
        .with(params: hash_including(
          action: "system_delete_architecture",
          architecture_id: "arch-x"
        ))
        .and_return(success: true, data: { deleted: true, architecture_id: "arch-x" })

      result = System::Ai::Skills::ArchitectureDeleteExecutor
        .new(account: account)
        .execute(architecture_id: "arch-x")

      expect(result[:success]).to be true
    end
  end
end
