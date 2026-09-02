# frozen_string_literal: true

require "rails_helper"

# IMP-8c0f0fe9a8cf (APO-3b) — target_replicas used to be a write nothing read.
# This service is the reconciler that closes the loop: it converges the live
# replica count for a PlatformDeployment toward its declared target, and it
# refuses outright on the deployment that hosts THIS control plane (readiness
# doc §7 / INV-1 — the control plane never autonomously remediates its own
# hosting stack).
RSpec.describe System::Platform::ReplicaReconciler do
  let(:account)  { create(:account) }
  let(:template) { create(:system_node_template, account: account) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:deployment) do
    create(:system_platform_deployment, account: account, node_template: template, target_replicas: 1)
  end

  # `internal: true` is the trusted in-process shape (the autonomy reconcilers
  # build executors with user: nil and mean it). The permission-refusal
  # examples below build the OTHER shapes deliberately.
  subject(:reconciler) { described_class.new(account: account, internal: true) }

  def live_instance!
    create(:system_node_instance, node: node, account: account, status: "running")
  end

  # Provisioning is stubbed everywhere below: this spec is about the
  # convergence arithmetic and the refusals, not about the provider adapters.
  def stub_provision(count: 1)
    created = []
    allow(::System::ProvisioningService).to receive(:provision_instance) do
      inst = live_instance!
      created << inst
      ::System::Runtime::Result.ok(data: { instance: inst })
    end
    created
  end

  describe "#hub_deployment?" do
    it "is false when self_hosting_node_id is unset (the inert default)" do
      expect(reconciler.hub_deployment?(deployment)).to be false
    end

    it "is true when the deployment's template is the template of this plane's own hosting node" do
      SiteSetting.set("self_hosting_node_id", node.id)
      expect(reconciler.hub_deployment?(deployment)).to be true
    end

    it "is false for a deployment on a different template" do
      other_node = create(:system_node, account: account)
      SiteSetting.set("self_hosting_node_id", other_node.id)
      expect(reconciler.hub_deployment?(deployment)).to be false
    end
  end

  describe "#reconcile! — hub refusal" do
    before { SiteSetting.set("self_hosting_node_id", node.id) }

    it "refuses and provisions nothing, citing the self-remediation ban" do
      expect(::System::ProvisioningService).not_to receive(:provision_instance)
      deployment.update!(target_replicas: 3)

      result = reconciler.reconcile!(deployment)

      expect(result.ok?).to be false
      expect(result.refused_reason).to eq(:control_plane_self_remediation)
      expect(result.message).to match(/own hosting stack|self-remediat/i)
    end
  end

  describe "#reconcile! — scale out" do
    it "provisions the deficit and reports the new ids" do
      node
      live_instance!
      deployment.update!(target_replicas: 3)
      stub_provision

      result = reconciler.reconcile!(deployment)

      expect(result.ok?).to be true
      expect(result.actual_before).to eq(1)
      expect(result.provisioned_instance_ids.size).to eq(2)
      expect(result.actual_after).to eq(3)
    end

    it "is a no-op when the live count already matches the target" do
      node
      live_instance!
      expect(::System::ProvisioningService).not_to receive(:provision_instance)

      result = reconciler.reconcile!(deployment)

      expect(result.ok?).to be true
      expect(result.provisioned_instance_ids).to be_empty
      expect(result.terminated_instance_ids).to be_empty
    end

    it "clamps the per-pass delta to the configured maximum" do
      node
      SiteSetting.set(described_class::MAX_DELTA_SETTING_KEY, "1")
      deployment.update!(target_replicas: 5)
      stub_provision

      result = reconciler.reconcile!(deployment)

      expect(result.provisioned_instance_ids.size).to eq(1)
    end

    it "fails cleanly when the deployment's template has no Node to provision onto" do
      deployment.update!(target_replicas: 2)

      result = reconciler.reconcile!(deployment)

      expect(result.ok?).to be false
      expect(result.message).to match(/no System::Node/i)
    end
  end

  describe "#reconcile! — scale in" do
    before do
      node
      3.times { live_instance! }
      deployment.update!(target_replicas: 1)
    end

    it "does NOT terminate under the default require_approval policy" do
      expect(::System::ProvisioningService).not_to receive(:terminate_instance)

      result = reconciler.reconcile!(deployment)

      expect(result.ok?).to be true
      expect(result.terminated_instance_ids).to be_empty
      expect(result.pending_removal_instance_ids.size).to eq(2)
      expect(result.message).to include(described_class::SCALE_IN_ACTION_CATEGORY)
    end

    it "terminates the newest excess replicas when the policy auto-approves" do
      allow_any_instance_of(::Ai::InterventionPolicyService)
        .to receive(:resolve).and_return({ policy: "auto_approve" })
      allow(::System::ProvisioningService).to receive(:terminate_instance) do |instance:|
        instance.update_column(:status, "terminated")
        ::System::Runtime::Result.ok(data: {})
      end

      result = reconciler.reconcile!(deployment)

      expect(result.ok?).to be true
      expect(result.terminated_instance_ids.size).to eq(2)
      expect(result.pending_removal_instance_ids).to be_empty
    end

    it "records a provider refusal as a failure rather than a silent success" do
      allow_any_instance_of(::Ai::InterventionPolicyService)
        .to receive(:resolve).and_return({ policy: "auto_approve" })
      allow(::System::ProvisioningService).to receive(:terminate_instance)
        .and_return(::System::Runtime::Result.err(error: "instance is under an operator ops hold"))

      result = reconciler.reconcile!(deployment)

      expect(result.terminated_instance_ids).to be_empty
      expect(result.failures.size).to eq(2)
      expect(result.failures.first[:error]).to match(/ops hold/)
    end
  end

  # REVIEW FINDING (blocker-adjacent, reconciler half): the destroy must not be
  # reachable by spelling it "scale in". system.task.terminate is the platform's
  # ONE declared terminate category — System::Executors::TerminateInstance
  # resolves it and system_fleet_tool's declare_action names it — so an operator
  # who blocked THAT row must not be bypassed by the narrower new one.
  describe "#reconcile! — scale in resolves BOTH policy categories" do
    before do
      node
      3.times { live_instance! }
      deployment.update!(target_replicas: 1)
    end

    it "refuses to terminate when system.task.terminate does not auto-execute" do
      allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve) do |_svc, action_category:, **|
        { policy: action_category == described_class::SCALE_IN_ACTION_CATEGORY ? "auto_approve" : "block" }
      end
      expect(::System::ProvisioningService).not_to receive(:terminate_instance)

      result = reconciler.reconcile!(deployment)

      expect(result.terminated_instance_ids).to be_empty
      expect(result.message).to include(described_class::TERMINATE_ACTION_CATEGORY)
    end

    # ProvisioningService, not InstanceControlService: TerminateInstance's own
    # class comment enumerates the four controls that live ONLY in
    # ProvisioningService (the INV-1 fence, the SDWAN peer detach, the dev-cell
    # deploy-key revoke, the "terminated" meter event). A second destroy door
    # must not be the one that drops them.
    it "terminates through ProvisioningService, never InstanceControlService" do
      allow_any_instance_of(::Ai::InterventionPolicyService)
        .to receive(:resolve).and_return({ policy: "auto_approve" })
      allow(::System::ProvisioningService).to receive(:terminate_instance) do |instance:|
        instance.update_column(:status, "terminated")
        ::System::Runtime::Result.ok(data: {})
      end
      expect(::System::InstanceControlService).not_to receive(:execute)

      reconciler.reconcile!(deployment)

      expect(::System::ProvisioningService).to have_received(:terminate_instance).twice
    end
  end

  # REVIEW FINDING: the MCP door onto this service maps to
  # system.platform.scale, while every other door onto provision / terminate
  # requires system.instances.create / .control. Check the permission that
  # governs the PRIMITIVE, or the skill becomes a privilege escalation.
  describe "actuation permissions" do
    let(:scale_only) do
      create(:user, account: account, permissions: %w[system.platform.read system.platform.scale])
    end
    let(:full) do
      create(:user, account: account,
                    permissions: %w[system.platform.scale system.instances.create system.instances.control])
    end

    it "refuses to provision for a caller holding only system.platform.scale" do
      node
      deployment.update!(target_replicas: 3)
      expect(::System::ProvisioningService).not_to receive(:provision_instance)

      result = described_class.new(account: account, user: scale_only).reconcile!(deployment)

      expect(result.ok?).to be false
      expect(result.refused_reason).to eq(:insufficient_permission)
      expect(result.message).to include(described_class::PROVISION_PERMISSION)
    end

    it "provisions for a caller that holds system.instances.create" do
      node
      deployment.update!(target_replicas: 2)
      stub_provision

      result = described_class.new(account: account, user: full).reconcile!(deployment)

      expect(result.ok?).to be true
      expect(result.provisioned_instance_ids.size).to eq(2)
    end

    # An MCP instance principal arrives with NO user and is NOT internal. The
    # nil must fail closed, not read as "trusted in-process caller".
    it "refuses a userless, non-internal caller (the instance-principal shape)" do
      node
      deployment.update!(target_replicas: 3)
      expect(::System::ProvisioningService).not_to receive(:provision_instance)

      result = described_class.new(account: account).reconcile!(deployment)

      expect(result.ok?).to be false
      expect(result.refused_reason).to eq(:insufficient_permission)
    end

    it "refuses to terminate for a caller holding only system.platform.scale" do
      node
      3.times { live_instance! }
      deployment.update!(target_replicas: 1)
      allow_any_instance_of(::Ai::InterventionPolicyService)
        .to receive(:resolve).and_return({ policy: "auto_approve" })
      expect(::System::ProvisioningService).not_to receive(:terminate_instance)

      result = described_class.new(account: account, user: scale_only).reconcile!(deployment)

      expect(result.ok?).to be false
      expect(result.refused_reason).to eq(:insufficient_permission)
      expect(result.message).to include(described_class::TERMINATE_PERMISSION)
    end
  end

  # REVIEW FINDING: CLAUDE.md's bulk-operation rule sets the confirm-first
  # threshold at "more than 5 items", and a scale-out runs unattended with no
  # approval row behind it.
  describe "the per-pass clamp" do
    it "defaults to the bulk-operation threshold, not twice it" do
      expect(described_class::DEFAULT_MAX_DELTA).to eq(5)
    end
  end

  describe "the scale-in policy category" do
    it "is declared so an operator can retune it in the Autonomy modal" do
      declared = ::System::Governance::PolicyDeclarations::POLICY_SETS
                   .flat_map { |set| set[:policies].keys }
      expect(declared).to include(described_class::SCALE_IN_ACTION_CATEGORY)
    end
  end
end
