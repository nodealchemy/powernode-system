# frozen_string_literal: true

require "rails_helper"

# Full-mode spec (loads only when the system extension is present). Mocks the SSH
# transport + cluster so it exercises the method's orchestration logic (command building,
# result mapping) without a real cluster.
RSpec.describe System::Deploy::KubernetesMethod do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:method) { described_class.new(account: account, user: user) }
  let(:node_instance) { instance_double("System::NodeInstance") }
  let(:k8s_node) { double("kubernetes_node", node_instance: node_instance) }
  let(:cluster) { instance_double(Devops::KubernetesCluster, id: "cl-1", name: "prod-k3s") }

  let(:restart_target) do
    Ai::Deploy::Target.new(kind: :project, config: { "cluster_id" => "cl-1", "deployment" => "web", "namespace" => "apps" })
  end
  let(:image_target) do
    Ai::Deploy::Target.new(kind: :project,
                           config: { "cluster_id" => "cl-1", "deployment" => "web", "container" => "app", "image" => "reg/web:v2" })
  end

  before do
    allow(method).to receive(:resolve_cluster).and_return(cluster)
    allow(method).to receive(:server_instance).with(cluster).and_return(node_instance)
  end

  def ssh_result(success, error = nil)
    instance_double(System::Runtime::Result, success?: success, error: error)
  end

  it "is available + keyed :kubernetes" do
    expect(described_class.key).to eq(:kubernetes)
    expect(described_class.available?).to be true
  end

  describe "#deploy! dry-run" do
    it "builds a rollout-restart command when no image/container given" do
      result = method.deploy!(target: restart_target, ref: "abc", dry_run: true)
      expect(result).to be_dry_run
      expect(result.commands.first).to include("rollout restart deployment/web -n apps")
    end

    it "builds a set-image command when image+container given" do
      result = method.deploy!(target: image_target, ref: "abc", dry_run: true)
      expect(result.commands.first).to include("set image deployment/web app=reg/web:v2")
    end

    it "fails without a deployment name" do
      t = Ai::Deploy::Target.new(kind: :project, config: { "cluster_id" => "cl-1" })
      expect(method.deploy!(target: t, ref: "x", dry_run: true)).to be_failed
    end
  end

  describe "#deploy! real run" do
    it "runs kubectl over SSH and maps success" do
      expect(System::SshExecutionService).to receive(:execute)
        .with(hash_including(instance: node_instance, sudo: true)).and_return(ssh_result(true))
      result = method.deploy!(target: restart_target, ref: "abc", dry_run: false)
      expect(result).to be_succeeded
    end

    it "maps an SSH failure to a failed result" do
      allow(System::SshExecutionService).to receive(:execute).and_return(ssh_result(false, "exit 1"))
      expect(method.deploy!(target: restart_target, ref: "abc", dry_run: false)).to be_failed
    end
  end

  describe "#verify_health + #rollback!" do
    let(:deploy_run) { instance_double(Ai::DeployRun, metadata: { "deployment" => "web", "namespace" => "apps" }) }

    it "verify_health is healthy when rollout status converges" do
      allow(System::SshExecutionService).to receive(:execute).and_return(ssh_result(true))
      expect(method.verify_health(target: restart_target, deploy_run: deploy_run)).to be_succeeded
    end

    it "rollback! runs kubectl rollout undo" do
      expect(System::SshExecutionService).to receive(:execute)
        .with(hash_including(sudo: true)).and_return(ssh_result(true))
      expect(method.rollback!(target: restart_target, deploy_run: deploy_run)).to be_rolled_back
    end
  end
end
