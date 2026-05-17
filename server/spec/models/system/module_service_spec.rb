# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::ModuleService, type: :model do
  describe "constants" do
    it "defines RESTART_POLICIES" do
      expect(described_class::RESTART_POLICIES).to eq(%w[always on-failure never])
    end

    it "defines HEALTH_METHODS" do
      expect(described_class::HEALTH_METHODS).to eq(%w[GET POST PUT])
    end
  end

  describe "associations" do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:node_module).class_name("System::NodeModule") }
    it {
      is_expected.to have_many(:outgoing_dependencies)
        .class_name("System::ModuleServiceDependency")
        .with_foreign_key(:module_service_id)
        .dependent(:destroy)
    }
    it {
      is_expected.to have_many(:incoming_dependencies)
        .class_name("System::ModuleServiceDependency")
        .with_foreign_key(:depends_on_module_service_id)
        .dependent(:destroy)
    }
    it { is_expected.to have_many(:dependencies).through(:outgoing_dependencies) }
    it { is_expected.to have_many(:dependents).through(:incoming_dependencies) }
  end

  describe "validations" do
    subject { build(:system_module_service) }

    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_length_of(:name).is_at_most(100) }
    it { is_expected.to validate_presence_of(:start_command) }
    it { is_expected.to validate_inclusion_of(:restart_policy).in_array(described_class::RESTART_POLICIES) }
    it { is_expected.to validate_inclusion_of(:health_method).in_array(described_class::HEALTH_METHODS) }
    it { is_expected.to validate_numericality_of(:health_interval_seconds).is_greater_than(0) }
    it { is_expected.to validate_numericality_of(:health_timeout_seconds).is_greater_than(0) }
    it { is_expected.to validate_numericality_of(:health_initial_delay_seconds).is_greater_than_or_equal_to(0) }

    it "enforces name uniqueness within node_module scope" do
      existing = create(:system_module_service, name: "rails")
      duplicate = build(:system_module_service, node_module: existing.node_module, account: existing.account, name: "rails")
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:name]).to include("has already been taken")
    end

    it "allows same name across different node_modules" do
      first = create(:system_module_service, name: "rails")
      second_module = create(:system_node_module, account: first.account)
      second = build(:system_module_service, node_module: second_module, account: first.account, name: "rails")
      expect(second).to be_valid
    end

    it "rejects an account_id that doesn't match the node_module's account" do
      other_account = create(:account)
      service = build(:system_module_service)
      service.account = other_account
      expect(service).not_to be_valid
      expect(service.errors[:account_id]).to include(/must match/)
    end
  end

  describe "scopes" do
    let!(:with_health) { create(:system_module_service, health_endpoint: "/up") }
    let!(:without_health) { create(:system_module_service, health_endpoint: nil) }

    it ".with_health_check returns only services with a health endpoint" do
      expect(described_class.with_health_check).to include(with_health)
      expect(described_class.with_health_check).not_to include(without_health)
    end

    it ".exposes_port matches services exposing a given port" do
      svc = create(:system_module_service, exposed_ports: [{ "port" => 3000, "protocol" => "tcp", "name" => "http" }])
      expect(described_class.exposes_port(3000)).to include(svc)
      expect(described_class.exposes_port(9999)).not_to include(svc)
    end
  end

  describe "jsonb default initialization" do
    it "initializes env, exposed_ports, capabilities, metadata to safe defaults" do
      svc = described_class.new
      expect(svc.env).to eq({})
      expect(svc.exposed_ports).to eq([])
      expect(svc.capabilities).to eq([])
      expect(svc.metadata).to eq({})
    end
  end
end
