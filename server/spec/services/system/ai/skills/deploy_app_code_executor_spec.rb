# frozen_string_literal: true

require "rails_helper"

# AI-Driven Provisioning M3 — slice 2. Mirrors
# provision_full_stack_executor_spec.rb in shape; adapts for the
# repo-deploy contract (CodeDeployService stub from Slice A) and the
# ProvisioningCodeDeployment ledger row.
RSpec.describe System::Ai::Skills::DeployAppCodeExecutor do
  let(:account)       { create(:account) }
  let(:platform_obj)  { create(:system_node_platform, account: account) }
  let(:template)      { create(:system_node_template, account: account, node_platform: platform_obj) }
  let(:provider)      { create(:system_provider, account: account) }
  let(:region)        { create(:system_provider_region, account: account, provider: provider) }
  let(:itype)         { create(:system_provider_instance_type, account: account, provider: provider) }
  let(:node)          { create(:system_node, account: account, node_template: template) }
  let(:node_instance) do
    create(:system_node_instance,
           node: node,
           provider_region: region,
           provider_instance_type: itype)
  end
  let(:mission)       { create(:ai_mission, account: account) }
  let(:exec)          { described_class.new(account: account) }

  # Slice A ships `System::CodeDeployService.call` but `.tear_down` is
  # part of THIS slice's cross-slice contract for rollback (and may not
  # be implemented yet). Use a non-verifying double so we can stub
  # forward-looking methods without coupling to Slice A's current
  # surface area.
  let(:code_deploy_service) { double("System::CodeDeployService") }
  before do
    stub_const("System::CodeDeployService", code_deploy_service)
  end

  describe ".descriptor" do
    it "advertises the deploy_app_code contract" do
      d = described_class.descriptor

      expect(d[:name]).to eq("deploy_app_code")
      expect(d[:category]).to eq("devops")
      expect(d.dig(:inputs, :node_instance_id, :required)).to be true
      expect(d.dig(:inputs, :repo_url, :required)).to be true
      expect(d.dig(:inputs, :branch, :required)).to be false
      expect(d.dig(:inputs, :branch, :default)).to eq("main")
      expect(d.dig(:inputs, :start_command, :required)).to be false
      expect(d.dig(:inputs, :deploy_key_id, :required)).to be false
      expect(d.dig(:inputs, :mission_id, :required)).to be false
      expect(d[:outputs]).to include(:deployment_id, :commit_sha, :public_url)
      expect(d[:rollback]).to eq(:rollback_deploy_app_code)
      expect(d[:requires_approval]).to be false
      expect(d[:blast_radius]).to eq(:low)
    end
  end

  describe "#execute" do
    context "with missing required inputs" do
      it "rejects an empty repo_url" do
        r = exec.execute(node_instance_id: node_instance.id, repo_url: "  ", mission_id: mission.id)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/repo_url is required/)
      end

      it "rejects a missing node_instance_id" do
        r = exec.execute(node_instance_id: "", repo_url: "https://example.com/repo.git", mission_id: mission.id)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/node_instance_id is required/)
      end

      it "rejects an unknown node_instance" do
        r = exec.execute(node_instance_id: SecureRandom.uuid,
                         repo_url: "https://example.com/repo.git",
                         mission_id: mission.id)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/node_instance not found/)
      end

      it "rejects an unknown mission_id" do
        r = exec.execute(node_instance_id: node_instance.id,
                         repo_url: "https://example.com/repo.git",
                         mission_id: SecureRandom.uuid)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/mission not found/)
      end

      it "rejects a non-dry-run with no mission_id" do
        r = exec.execute(node_instance_id: node_instance.id,
                         repo_url: "https://example.com/repo.git")
        expect(r[:success]).to be false
        expect(r[:error]).to match(/mission_id is required/)
      end
    end

    context "in dry_run mode" do
      it "returns a plan without invoking CodeDeployService or creating a row" do
        expect(code_deploy_service).not_to receive(:call)

        r = exec.execute(node_instance_id: node_instance.id,
                         repo_url: "https://github.com/me/app.git",
                         branch: "develop",
                         start_command: "npm start",
                         dry_run: true)

        expect(r[:success]).to be true
        expect(r[:data][:dry_run]).to be true
        expect(r[:data][:planned_actions].size).to eq(2)
        expect(r[:data][:planned_actions].first[:step]).to eq("create_deployment_record")
        expect(r[:data][:planned_actions].last[:step]).to eq("code_deploy_service")
        expect(::Ai::ProvisioningCodeDeployment.count).to eq(0)
      end

      it "tolerates the brief: kwarg PlanComposer injects" do
        r = exec.execute(node_instance_id: node_instance.id,
                         repo_url: "https://github.com/me/app.git",
                         dry_run: true,
                         brief: { use_case: "deploy_my_code" })

        expect(r[:success]).to be true
      end
    end

    context "happy path with a public repo" do
      before do
        allow(code_deploy_service).to receive(:call).and_return(
          success: true,
          commit_sha: "abc123def456",
          public_url: "https://app.example.com"
        )
      end

      it "creates a deployment row, calls CodeDeployService, and lands in 'running'" do
        r = exec.execute(node_instance_id: node_instance.id,
                         repo_url: "https://github.com/me/app.git",
                         branch: "main",
                         start_command: "npm start",
                         mission_id: mission.id)

        expect(r[:success]).to be true
        expect(r[:requires_approval]).to be false
        d = r[:data]
        expect(d[:deployment_id]).to be_present
        expect(d[:commit_sha]).to eq("abc123def456")
        expect(d[:public_url]).to eq("https://app.example.com")

        deployment = ::Ai::ProvisioningCodeDeployment.find(d[:deployment_id])
        expect(deployment.status).to eq("running")
        expect(deployment.commit_sha).to eq("abc123def456")
        expect(deployment.public_url).to eq("https://app.example.com")
        expect(deployment.deployed_at).to be_present
        expect(deployment.last_error).to be_nil
        expect(deployment.mission).to eq(mission)
        expect(deployment.node_instance).to eq(node_instance)

        expect(code_deploy_service).to have_received(:call).with(
          hash_including(
            node_instance: node_instance,
            repo_url: "https://github.com/me/app.git",
            branch: "main",
            start_command: "npm start",
            deploy_key: nil
          )
        )
      end
    end

    context "with a private repo (deploy_key_id)" do
      before do
        allow(code_deploy_service).to receive(:call).and_return(
          success: true,
          commit_sha: "deadbeef",
          public_url: "https://private-app.example.com"
        )
      end

      it "forwards the deploy_key_id to CodeDeployService" do
        r = exec.execute(node_instance_id: node_instance.id,
                         repo_url: "git@github.com:me/private.git",
                         branch: "main",
                         deploy_key_id: "secret-abc",
                         mission_id: mission.id)

        expect(r[:success]).to be true
        expect(code_deploy_service).to have_received(:call).with(
          hash_including(deploy_key: "secret-abc")
        )
      end
    end

    context "when CodeDeployService fails" do
      before do
        allow(code_deploy_service).to receive(:call).and_return(
          success: false,
          error: "ssh: connection refused"
        )
      end

      it "marks the deployment failed with last_error and returns success: false" do
        r = exec.execute(node_instance_id: node_instance.id,
                         repo_url: "https://github.com/me/app.git",
                         mission_id: mission.id)

        expect(r[:success]).to be false
        expect(r[:error]).to match(/ssh: connection refused/)

        # The executor still creates a deployment row so the operator
        # can see what failed and where.
        expect(r[:deployment_id]).to be_present
        deployment = ::Ai::ProvisioningCodeDeployment.find(r[:deployment_id])
        expect(deployment.status).to eq("failed")
        expect(deployment.last_error).to match(/ssh: connection refused/)
      end
    end

    context "when CodeDeployService raises" do
      before do
        allow(code_deploy_service).to receive(:call).and_raise(StandardError, "boom")
      end

      it "swallows the exception and returns failure" do
        r = exec.execute(node_instance_id: node_instance.id,
                         repo_url: "https://github.com/me/app.git",
                         mission_id: mission.id)

        expect(r[:success]).to be false
        expect(r[:error]).to match(/boom/)
      end
    end
  end

  describe "#rollback_deploy_app_code" do
    let(:deployment) do
      ::Ai::ProvisioningCodeDeployment.create!(
        mission: mission,
        node_instance: node_instance,
        repo_url: "https://github.com/me/app.git",
        branch: "main",
        status: "running",
        commit_sha: "abc",
        public_url: "https://app.example.com",
        deployed_at: Time.current
      )
    end

    it "tears down on the node and marks the deployment 'rolled_back'" do
      allow(code_deploy_service).to receive(:tear_down)
        .with(node_instance: node_instance)
        .and_return(success: true)

      result = exec.rollback_deploy_app_code(deployment_id: deployment.id)

      expect(result[:success]).to be true
      expect(result[:errors]).to be_empty
      expect(deployment.reload.status).to eq("rolled_back")
    end

    it "collects errors when tear_down fails but does not raise" do
      allow(code_deploy_service).to receive(:tear_down)
        .with(node_instance: node_instance)
        .and_return(success: false, error: "ssh closed")

      result = exec.rollback_deploy_app_code(deployment_id: deployment.id)

      expect(result[:success]).to be false
      expect(result[:errors].first).to include(resource: "deployment", id: deployment.id)
      expect(result[:errors].first[:error]).to match(/ssh closed/)
      # Status NOT updated to rolled_back since tear_down failed.
      expect(deployment.reload.status).to eq("running")
    end

    it "collects errors when tear_down raises but does not propagate the exception" do
      allow(code_deploy_service).to receive(:tear_down).and_raise(StandardError, "boom")

      result = exec.rollback_deploy_app_code(deployment_id: deployment.id)

      expect(result[:success]).to be false
      expect(result[:errors].first[:error]).to match(/boom/)
    end

    it "reports an error when the deployment_id is unknown" do
      result = exec.rollback_deploy_app_code(deployment_id: SecureRandom.uuid)

      expect(result[:success]).to be false
      expect(result[:errors].first[:error]).to match(/not found/)
    end

    it "ignores extra kwargs the runner may forward (commit_sha, public_url, etc.)" do
      allow(code_deploy_service).to receive(:tear_down)
        .with(node_instance: node_instance)
        .and_return(success: true)

      result = exec.rollback_deploy_app_code(
        deployment_id: deployment.id,
        commit_sha: "abc",
        public_url: "https://app.example.com"
      )

      expect(result[:success]).to be true
      expect(deployment.reload.status).to eq("rolled_back")
    end

    it "tolerates node_instance_ids forwarded by a sibling rollback hook" do
      allow(code_deploy_service).to receive(:tear_down)
        .with(node_instance: node_instance)
        .and_return(success: true)

      result = exec.rollback_deploy_app_code(
        deployment_id: deployment.id,
        node_instance_ids: [node_instance.id]
      )

      expect(result[:success]).to be true
    end
  end
end
