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

  # F4-13: deploys that should end ACTIVE stub a healthy ollama probe.
  def stub_healthy_endpoint!(endpoint = "http://10.0.0.5:11434")
    stub_request(:get, "#{endpoint}/api/tags").to_return(status: 200, body: '{"models":[]}')
  end

  it "assigns both modules and registers an ollama provider at the endpoint" do
    stub_healthy_endpoint!
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
    stub_healthy_endpoint!
    described_class.deploy!(account: account, instance: instance, endpoint_override: "http://10.0.0.5:11434")
    assignments = System::NodeModuleAssignment.count
    providers   = Ai::Provider.count

    described_class.deploy!(account: account, instance: instance, endpoint_override: "http://10.0.0.5:11434")

    expect(System::NodeModuleAssignment.count).to eq(assignments)
    expect(Ai::Provider.count).to eq(providers)
  end

  # Audit F4-13 — the provider was registered is_active: true at the computed
  # endpoint immediately, before the (asynchronously applied) modules were
  # running, so platform agents routed inference traffic to an endpoint that
  # served nothing.
  describe "endpoint health gating (F4-13)" do
    it "registers the provider INACTIVE when the endpoint probe fails" do
      stub_request(:get, "http://10.0.0.5:11434/api/tags").to_timeout

      result = described_class.deploy!(account: account, instance: instance,
                                       endpoint_override: "http://10.0.0.5:11434")

      provider = Ai::Provider.find(result.provider_id)
      expect(provider.is_active).to be(false)
      expect(result.provider_active).to be(false)
    end

    it "re-deploy re-probes and activates a previously inactive provider" do
      stub_request(:get, "http://10.0.0.5:11434/api/tags").to_timeout
      described_class.deploy!(account: account, instance: instance,
                              endpoint_override: "http://10.0.0.5:11434")

      stub_healthy_endpoint!
      result = described_class.deploy!(account: account, instance: instance,
                                       endpoint_override: "http://10.0.0.5:11434")

      expect(Ai::Provider.find(result.provider_id).is_active).to be(true)
      expect(result.provider_active).to be(true)
    end
  end

  # Audit F4-13 — GPU_MODULE was hardcoded to gpu-nvidia-runtime.
  describe "accelerator parameterization (F4-13)" do
    it "deploys an alternate accelerator runtime module" do
      create(:system_node_module, account: account, name: "gpu-amd-runtime", variety: "subscription",
                                  config: { "gpu_runtime" => { "container_runtime" => "amd" } })
      stub_healthy_endpoint!

      described_class.deploy!(account: account, instance: instance,
                              endpoint_override: "http://10.0.0.5:11434", accelerator: "amd")

      assigned = System::NodeModuleAssignment.where(node: instance.node)
                                             .joins(:node_module).pluck("system_node_modules.name")
      expect(assigned).to contain_exactly("gpu-amd-runtime", "inference-ollama")
    end
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
