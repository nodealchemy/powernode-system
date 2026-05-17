# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::ModuleServiceDependency, type: :model do
  describe "constants" do
    it "defines KINDS" do
      expect(described_class::KINDS).to eq(%w[start_before requires_health softdep])
    end
  end

  describe "associations" do
    it {
      is_expected.to belong_to(:module_service)
        .class_name("System::ModuleService")
        .inverse_of(:outgoing_dependencies)
    }
    it {
      is_expected.to belong_to(:depends_on_module_service)
        .class_name("System::ModuleService")
        .inverse_of(:incoming_dependencies)
    }
  end

  describe "validations" do
    subject { build(:system_module_service_dependency) }

    it { is_expected.to validate_inclusion_of(:kind).in_array(described_class::KINDS) }

    it "rejects self-reference" do
      svc = create(:system_module_service)
      dep = build(:system_module_service_dependency, module_service: svc, depends_on_module_service: svc)
      expect(dep).not_to be_valid
      expect(dep.errors[:depends_on_module_service_id]).to include(/can't depend on itself/)
    end

    it "rejects edge between services in different node_modules" do
      svc_a = create(:system_module_service)
      svc_b = create(:system_module_service)
      dep = build(:system_module_service_dependency, module_service: svc_a, depends_on_module_service: svc_b)
      expect(dep).not_to be_valid
      expect(dep.errors[:depends_on_module_service_id]).to include(/same node_module/)
    end

    it "rejects duplicate edges" do
      node_module = create(:system_node_module)
      svc_a = create(:system_module_service, node_module: node_module)
      svc_b = create(:system_module_service, node_module: node_module)
      create(:system_module_service_dependency, module_service: svc_a, depends_on_module_service: svc_b)
      duplicate = build(:system_module_service_dependency, module_service: svc_a, depends_on_module_service: svc_b)
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:module_service_id]).to include("already depends on this service")
    end

    it "rejects edges that would create a cycle" do
      node_module = create(:system_node_module)
      svc_a = create(:system_module_service, node_module: node_module)
      svc_b = create(:system_module_service, node_module: node_module)
      svc_c = create(:system_module_service, node_module: node_module)

      create(:system_module_service_dependency, module_service: svc_a, depends_on_module_service: svc_b)
      create(:system_module_service_dependency, module_service: svc_b, depends_on_module_service: svc_c)

      cycle_edge = build(:system_module_service_dependency, module_service: svc_c, depends_on_module_service: svc_a)
      expect(cycle_edge).not_to be_valid
      expect(cycle_edge.errors[:depends_on_module_service_id]).to include(/circular/)
    end
  end

  describe "scopes" do
    let!(:start_before_dep) do
      svc_a = create(:system_module_service)
      svc_b = create(:system_module_service, node_module: svc_a.node_module)
      create(:system_module_service_dependency, module_service: svc_a, depends_on_module_service: svc_b, kind: "start_before")
    end

    let!(:softdep) do
      svc_a = create(:system_module_service)
      svc_b = create(:system_module_service, node_module: svc_a.node_module)
      create(:system_module_service_dependency, module_service: svc_a, depends_on_module_service: svc_b, kind: "softdep")
    end

    it ".start_ordering excludes softdep edges" do
      expect(described_class.start_ordering).to include(start_before_dep)
      expect(described_class.start_ordering).not_to include(softdep)
    end
  end
end
