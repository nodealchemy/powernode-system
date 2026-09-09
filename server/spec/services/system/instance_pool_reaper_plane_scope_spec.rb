# frozen_string_literal: true

require "rails_helper"

# Environment campaign, increment 7 — the pool reaper's DESTRUCTIVE arms are
# scoped by plane.
#
# The reaper is a 60s sweep with no principal: it cannot park an approval, so
# every gate the rest of the platform grew during this campaign passed it by. It
# terminated a stuck warming member, a ready member past TTL and an errored one
# on ANY plane, which on the control plane means an autonomous provider
# terminate of a control-plane VM with a log line for an audit trail.
#
# It now asks the plane's own rules the same question the gate would
# (Ai::EnvironmentPolicyOverlay over a permissive baseline, category
# system.instance_terminate) and, where the plane would escalate, withholds:
# flag the members, emit one event, report it in the summary. dev and ci — the
# planes whose pools exist to churn — are untouched.
RSpec.describe System::InstancePoolService, "reaper plane scope" do
  let(:account) { create(:account) }
  let(:provider_region) { create(:system_provider_region) }
  let(:provider_instance_type) { create(:system_provider_instance_type) }

  def pool_in(slug)
    environment = account.environments.find_by!(slug: slug)
    template = create(:system_node_template, account: account, environment: environment)
    System::InstancePool.create!(
      account: account, node_template: template, name: "pool-#{slug}",
      target_size: 2, min_size: 0, max_size: 5,
      lifecycle_class: "ephemeral", status: "active",
      provider_region: provider_region, provider_instance_type: provider_instance_type
    )
  end

  # A member the destructive warming arm would take: stuck warming well past
  # the timeout, with a provider identity so a terminate is a real call.
  def stuck_warming_member(pool)
    node = create(:system_node, account: account, node_template: pool.node_template)
    create(:system_node_instance,
           node: node, variety: "cloud", status: "pending",
           provider_region: provider_region, provider_instance_type: provider_instance_type,
           instance_pool_id: pool.id, pool_state: "warming",
           pool_warming_started_at: 2.hours.ago,
           cloud_instance_id: "pve1/qemu/#{rand(100..999)}")
  end

  before { allow(::System::ProvisioningService).to receive(:terminate_instance) }

  context "on ci — a plane whose pools exist to churn" do
    it "still destroys a stuck warming member, and says nothing about planes" do
      pool = pool_in("ci")
      member = stuck_warming_member(pool)

      result = described_class.recycle_stale_members!(pool: pool)

      expect(result[:warming_to_errored]).to eq(1)
      expect(result[:withheld_by_plane]).to be_nil
      expect(member.reload.pool_state).to eq("errored")
      expect(::System::ProvisioningService).to have_received(:terminate_instance).with(instance: member)
      expect(System::FleetEvent.where(account: account,
                                      kind: "system.pool.recycle_withheld_by_plane")).to be_empty
    end
  end

  context "on ops — protected, and a terminate is destructive" do
    it "withholds the terminate, flags the member and emits one event" do
      pool = pool_in("ops")
      member = stuck_warming_member(pool)

      result = described_class.recycle_stale_members!(pool: pool)

      expect(result[:withheld_by_plane]).to match(/environment ops is protected/)
      expect(result[:withheld_members]).to eq(1)
      expect(result[:environment_slug]).to eq("ops")
      expect(result[:warming_to_errored]).to be_nil

      member.reload
      expect(member.pool_state).to eq("warming")
      expect(member.config["pool_recycle_withheld_at"]).to be_present
      expect(member.config["pool_recycle_withheld_reason"]).to match(/protected/)
      expect(::System::ProvisioningService).not_to have_received(:terminate_instance)

      events = System::FleetEvent.where(account: account, kind: "system.pool.recycle_withheld_by_plane")
      expect(events.count).to eq(1)
      expect(events.first.payload["environment_slug"]).to eq("ops")
      expect(events.first.payload["withheld_member_count"]).to eq(1)
      expect(events.first.payload["action_category"]).to eq("system.instance_terminate")
    end

    it "proceeds for an operator forcing the phase — a person is what the escalation is for" do
      pool = pool_in("ops")
      member = stuck_warming_member(pool)

      result = described_class.recycle_stale_members!(pool: pool, actor: :operator)

      expect(result[:withheld_by_plane]).to be_nil
      expect(result[:warming_to_errored]).to eq(1)
      expect(::System::ProvisioningService).to have_received(:terminate_instance).with(instance: member)
    end
  end

  context "on prod — supervised" do
    it "withholds under the supervised rule, not the protected one" do
      pool = pool_in("prod")
      stuck_warming_member(pool)

      result = described_class.recycle_stale_members!(pool: pool)

      expect(result[:withheld_by_plane]).to match(/environment prod is supervised/)
    end
  end

  context "when an operator has configured the plane" do
    it "withholds on dev too, once dev lists the category" do
      # Configured BEFORE the pool is built: the pool's `environment`
      # association is loaded once, so a later update would leave this example
      # asserting against a stale copy of the row and passing for the wrong
      # reason (it did, on the first run).
      account.environments.find_by!(slug: "dev")
             .update!(approval_required_categories: [ "system.instance_*" ])
      pool = pool_in("dev")
      stuck_warming_member(pool)

      result = described_class.recycle_stale_members!(pool: pool)

      expect(result[:withheld_by_plane]).to match(/environment dev requires approval/)
    end
  end

  # A failure to ASK is not permission to destroy.
  it "withholds when the plane check itself raises" do
    pool = pool_in("ci")
    stuck_warming_member(pool)
    allow(::Ai::EnvironmentPolicyOverlay).to receive(:apply).and_raise(StandardError, "boom")

    result = described_class.recycle_stale_members!(pool: pool)

    expect(result[:withheld_by_plane]).to match(/plane check failed: StandardError/)
    expect(::System::ProvisioningService).not_to have_received(:terminate_instance)
  end
end
