# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::InferenceDeploymentService, type: :model do
  let(:account) { create(:account) }

  before do
    create(:system_node_module, account: account, name: "gpu-nvidia-runtime", variety: "subscription",
                                config: { "gpu_runtime" => { "container_runtime" => "nvidia" } })
    create(:system_node_module, account: account, name: "inference-ollama", variety: "subscription",
                                config: { "inference" => { "api_port" => 11_434, "default_model" => "llama3.1:8b" } })
  end

  let(:gpu_type) do
    create(:system_provider_instance_type, account: account,
                                           gpu_count: 1, gpu_type: "Quadro RTX 4000", gpu_memory_mb: 8192)
  end
  let(:instance) { create(:system_node_instance, account: account, status: "running", provider_instance_type: gpu_type) }

  it "assigns both modules and registers an ollama provider at the endpoint" do
    result = described_class.deploy!(account: account, instance: instance, endpoint_override: "http://10.0.0.5:11434")

    expect(result.module_assignment_ids.size).to eq(2)
    assigned = System::NodeModuleAssignment.where(node: instance.node)
                                           .joins(:node_module).pluck("system_node_modules.name")
    expect(assigned).to contain_exactly("gpu-nvidia-runtime", "inference-ollama")

    provider = Ai::Provider.find(result.provider_id)
    expect(provider.provider_type).to eq("ollama")
    expect(provider.api_endpoint).to eq("http://10.0.0.5:11434")
    expect(provider.is_active).to be(true)
    expect(provider).to be_valid
    expect(result.endpoint).to eq("http://10.0.0.5:11434")
    expect(result.model).to eq("llama3.1:8b")
  end

  it "is idempotent — re-deploy reuses assignments + provider" do
    described_class.deploy!(account: account, instance: instance, endpoint_override: "http://10.0.0.5:11434")
    assignments = System::NodeModuleAssignment.count
    providers   = Ai::Provider.count

    described_class.deploy!(account: account, instance: instance, endpoint_override: "http://10.0.0.5:11434")

    expect(System::NodeModuleAssignment.count).to eq(assignments)
    expect(Ai::Provider.count).to eq(providers)
  end

  it "honors an explicit model override on the provider" do
    result = described_class.deploy!(account: account, instance: instance,
                                     endpoint_override: "http://10.0.0.5:11434", model: "qwen2.5:14b")
    provider = Ai::Provider.find(result.provider_id)
    expect(result.model).to eq("qwen2.5:14b")
    expect(provider.supported_models.map { |m| m["id"] }).to include("qwen2.5:14b")
  end

  it "raises a DeploymentError when a required module is missing from the catalog" do
    System::NodeModule.where(account: account, name: "inference-ollama").delete_all
    expect do
      described_class.deploy!(account: account, instance: instance, endpoint_override: "http://x:11434")
    end.to raise_error(described_class::DeploymentError, /inference-ollama/)
  end
end
