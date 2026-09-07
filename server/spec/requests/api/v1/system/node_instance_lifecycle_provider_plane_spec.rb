# frozen_string_literal: true

require "rails_helper"

# Campaign 01a0790b increment 1 — THE REST LIFECYCLE ARMS ACTUATE THE PROVIDER,
# AND MINT NO System::Task.
#
# WHAT WAS BROKEN. NodeInstanceGating#gate_or_execute routed all four lifecycle
# verbs through System::Executors::ExecuteTask, which inserts a System::Task.
# On this fleet nothing actuated that row correctly:
#
#   * the SERVER arm (worker_api/tasks/:id/execute) 404s for EVERY task id —
#     it scopes through System::Node.where(worker: current_worker) and
#     node.worker_id is NULL on every node;
#   * the AGENT arm does pull it (node_api serves every pending row with no
#     command filter) and applies systemd UNIT verbs: `stop` fails
#     validateUnit for want of options["unit"], and `terminate` runs
#     `systemctl reboot` — the VM comes back instead of being destroyed.
#
# The in-thread provider call that would have masked this
# (#execute_local_provider_action_sync!) was gated on
# provider_type == "local_qemu". THIS FLEET IS PROXMOX, so it never fired.
#
# WHY A PROXMOX PROVIDER IS LOAD-BEARING IN EVERY EXAMPLE BELOW. With a
# local_qemu provider the old code path ALSO reached the adapter, so a spec
# written against local_qemu would have passed before this change and proves
# nothing. The provider_type here is the discriminator, not decoration.
#
# WHY THE ABSENCE OF A TASK ROW IS ASSERTED, NOT JUST THE ADAPTER CALL. A Task
# is a message to the on-node agent. These are provider-plane operations the
# agent cannot perform, so a row would be re-introducing the exact defect —
# and, per the agent handler registry, a stray `terminate` row is specifically
# what reboots the machine instead of destroying it.
RSpec.describe "system node instance lifecycle (provider plane)", type: :request do
  let(:user) { user_with_permissions("system.instances.control", "system.instances.read", "system.nodes.read") }
  let(:account) { user.account }

  let(:provider) { create(:system_provider, account: account, provider_type: "proxmox") }
  let(:provider_region) { create(:system_provider_region, account: account, provider: provider) }
  let(:node) { create(:system_node, account: account) }
  let!(:instance) do
    create(:system_node_instance, node: node, provider_region: provider_region,
                                  variety: "cloud", status: "running")
  end

  # A fresh spec account carries no Ai::InterventionPolicy rows and the gate
  # falls through to its require_approval default, which parks an approval
  # request and never reaches the executor. Seeded in the shape the seed writes.
  before do
    %w[start stop reboot terminate].each do |verb|
      declarations = ::System::Governance::PolicyDeclarations
      ::Ai::InterventionPolicy.create!(
        account: account,
        action_category: "system.task.#{verb}",
        **declarations::MANUAL_OPERATION_SCOPE,
        policy: "auto_approve",
        **declarations::MANUAL_OPERATION_ATTRIBUTES
      )
    end
  end

  def lifecycle_post(action)
    post "/api/v1/system/nodes/#{node.id}/node_instances/#{instance.id}/#{action}",
         headers: auth_headers_for(user)
  end

  describe "start / stop / reboot route to InstanceControlService" do
    %w[start stop reboot].each do |verb|
      it "#{verb} actuates the provider and creates no System::Task" do
        # `running` can stop and reboot but not start; park the row where the
        # verb under test is legal so the example exercises routing, not AASM.
        instance.update_column(:status, verb == "start" ? "stopped" : "running")

        expect(::System::InstanceControlService)
          .to receive(:execute)
          .with(hash_including(instance: instance, action: verb.to_sym))
          .and_return(::System::Runtime::Result.ok(data: {}))

        expect { lifecycle_post(verb) }.not_to change(::System::Task, :count)

        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe "terminate routes to ProvisioningService, not the Task lane" do
    it "calls ProvisioningService.terminate_instance and creates no System::Task" do
      expect(::System::ProvisioningService)
        .to receive(:terminate_instance)
        .with(hash_including(instance: instance))
        .and_return(::System::Runtime::Result.ok(data: {}))

      expect { lifecycle_post("terminate") }.not_to change(::System::Task, :count)

      expect(response).to have_http_status(:ok)
    end
  end

  # IMP-8be9408b506f. The fence keys on the self_hosting_node_id SiteSetting and
  # is INERT while unset — which is its production state today, so an example
  # that did not set it would pass vacuously against an unarmed control.
  #
  # EVERY example here stubs the PROVIDER ADAPTER, never InstanceControlService.
  # The fence lives INSIDE that service, so stubbing the service would skip the
  # very code under test and the example would pass identically if the fence
  # were armed and broken. The adapter is the real oracle: "did this reach the
  # machine, or not".
  describe "INV-1 self-management fence" do
    let(:adapter) { instance_double("System::Providers::BaseProvider", provider_type: "proxmox") }

    before { instance.update_column(:config, instance.config.merge("cloud_instance_id" => "example-host/qemu/100")) }

    it "refuses stop against this deployment's own hosting node WITHOUT reaching the provider" do
      ::SiteSetting.set(::System::Autonomy::SelfManagementFence::SELF_HOSTING_NODE_ID_KEY, node.id)

      # 422 alone proves nothing — a bad AASM state, an ops hold and a policy
      # block all return it. Not reaching the adapter is what distinguishes a
      # fence refusal from any of those.
      expect(::System::Providers::Registry).not_to receive(:for_instance)

      lifecycle_post("stop")

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("INV-1")
      expect(instance.reload.status).to eq("running")
    end

    it "reaches the provider for an instance on a DIFFERENT node" do
      other_node = create(:system_node, account: account)
      ::SiteSetting.set(::System::Autonomy::SelfManagementFence::SELF_HOSTING_NODE_ID_KEY, other_node.id)

      allow(::System::Providers::Registry).to receive(:for_instance).and_return(adapter)
      expect(adapter).to receive(:stop_instance).with("example-host/qemu/100", force: false)
                                                .and_return({ success: true })

      lifecycle_post("stop")
      expect(response).to have_http_status(:ok)
    end

    it "reaches the provider when self_hosting_node_id is unset (the production default)" do
      expect(::SiteSetting.get(::System::Autonomy::SelfManagementFence::SELF_HOSTING_NODE_ID_KEY)).to be_blank

      allow(::System::Providers::Registry).to receive(:for_instance).and_return(adapter)
      expect(adapter).to receive(:stop_instance).and_return({ success: true })

      lifecycle_post("stop")
      expect(response).to have_http_status(:ok)
    end
  end

  # The two guards catch different hazards and neither implies the other, so
  # each must refuse ON ITS OWN — which means each example must arrange the
  # OTHER guard to be genuinely inactive, not merely assumed inactive.
  describe "the ops hold and the fence are independent" do
    let(:service) { ::System::InstanceControlService.new }

    it "the fence refuses while NO ops hold is present" do
      ::SiteSetting.set(::System::Autonomy::SelfManagementFence::SELF_HOSTING_NODE_ID_KEY, node.id)
      # Asserted, not assumed: an earlier draft stubbed ops_held? to false,
      # which is what a fresh factory row already returns — so it established
      # nothing about independence.
      expect(instance.ops_held?).to be(false)

      result = service.execute(instance: instance, action: :reboot)

      expect(result.success?).to be(false)
      expect(result.error).to include("INV-1")
    end

    it "the ops hold refuses while the fence is INERT" do
      expect(::SiteSetting.get(::System::Autonomy::SelfManagementFence::SELF_HOSTING_NODE_ID_KEY)).to be_blank
      allow(instance).to receive(:ops_held?).and_return(true)
      allow(instance).to receive(:ops_hold_summary).and_return("disk work")

      result = service.execute(instance: instance, action: :reboot)

      expect(result.success?).to be(false)
      expect(result.error).to include("ops hold")
      expect(result.error).not_to include("INV-1")
    end

    it "force: true does NOT bypass the fence" do
      ::SiteSetting.set(::System::Autonomy::SelfManagementFence::SELF_HOSTING_NODE_ID_KEY, node.id)

      result = service.execute(instance: instance, action: :reboot, force: true)

      expect(result.success?).to be(false)
      expect(result.error).to include("INV-1")
    end

    it "start stays allowed against the self-hosting node, and reaches the provider" do
      ::SiteSetting.set(::System::Autonomy::SelfManagementFence::SELF_HOSTING_NODE_ID_KEY, node.id)
      instance.update_column(:status, "stopped")
      instance.update_column(:config, instance.config.merge("cloud_instance_id" => "example-host/qemu/100"))

      # Behaviour, not a private method's return value: if the plane is serving
      # this call its host is already running, so a start is a no-op rather
      # than self-management — and it must actually get through.
      adapter = instance_double("System::Providers::BaseProvider", provider_type: "proxmox")
      allow(::System::Providers::Registry).to receive(:for_instance).and_return(adapter)
      expect(adapter).to receive(:start_instance).and_return({ success: true })

      result = service.execute(instance: instance, action: :start)
      expect(result.success?).to be(true)
    end
  end
end
