# frozen_string_literal: true

require "rails_helper"

# IMP-64d9f2cdff63 — the actuator for OrphanPoolGuestSensor's detections.
#
# Destroys a provider guest that is named for an ephemeral pool and that no
# platform row knows. Every claim is re-checked at execution time rather than
# trusted from the signal, because an approval can sit for hours:
#
#   * the guest is still an orphan of THIS ephemeral pool, and still listed by
#     the provider under that id and name;
#   * the terminate is NAME-VERIFIED — the provider refuses to destroy the guest
#     at that id unless it is still the one the signal named, so a recycled id
#     cannot turn "reap the orphan" into "destroy whatever holds the number now".
#
# Plane placement (operator direction): ci / ephemeral proceeds, a protected
# plane parks. That is not re-implemented here — the lane's inputs name the
# pool, the environment resolver places the pool in its plane, and the overlay
# escalates a destructive category in a protected plane. The "the gate" examples
# below run that through the executor's own gate, end to end.
RSpec.describe System::Ai::Skills::ReapOrphanPoolGuestExecutor, type: :service do
  let(:account)                { create(:account) }
  let(:node_template)          { create(:system_node_template, account: account) }
  let(:provider_region)        { create(:system_provider_region, account: account) }
  let(:provider_instance_type) { create(:system_provider_instance_type, account: account) }
  let(:connection)             { instance_double("System::ProviderConnection") }
  let(:adapter)                { instance_double("System::Providers::BaseProvider") }
  let(:guest_name)             { "ci-builders-pool-1789188789-0-20260912045310-cc99" }
  let(:cloud_id)               { "pve1/qemu/9002" }

  let!(:pool) { make_pool("ci-builders") }

  # `provider_region`/`provider_instance_type` above are reused (not rebuilt)
  # for the default `owner: account` pool because other examples stub
  # `Registry.for(connection, region: provider_region)` against that exact
  # object — an `owner: other` pool (ambiguous-name case) needs its OWN
  # account's catalog row instead, or InstancePool now refuses the save
  # (IMP-b9f4b900f00b).
  def make_pool(name, lifecycle_class: "ephemeral", owner: account, template: node_template)
    region = owner == account ? provider_region : create(:system_provider_region, account: owner)
    type   = owner == account ? provider_instance_type : create(:system_provider_instance_type, account: owner)
    System::InstancePool.create!(
      account: owner, node_template: template, name: name,
      target_size: 1, min_size: 0, max_size: 3, lifecycle_class: lifecycle_class, status: "active",
      provider_region: region, provider_instance_type: type
    )
  end

  def listing(*guests, success: true, truncated: false)
    { success: success, truncated: truncated,
      instances: guests.map { |name, id| { cloud_instance_id: id, name: name, status: "running" } } }
  end

  before do
    allow(System::Providers::Registry).to receive(:find_connection_for_region).and_return(connection)
    allow(System::Providers::Registry).to receive(:for).with(connection, region: provider_region).and_return(adapter)
    allow(adapter).to receive(:supports?).with(:sync).and_return(true)
    allow(adapter).to receive(:list_instances).and_return(listing([ guest_name, cloud_id ]))
  end

  def reap(name: guest_name, cloud_instance_id: cloud_id, pool_id: pool.id, gated: true, user: nil)
    described_class.new(account: account, agent: nil, user: user)
                   .execute(gated: gated, instance_pool_id: pool_id, cloud_instance_id: cloud_instance_id,
                            guest_name: name)
  end

  it "declares its own destructive action_category" do
    expect(described_class.action_category).to eq("system.pool_guest_reap")
  end

  it "terminates the guest by id AND expected name" do
    expect(adapter).to receive(:terminate_instance)
      .with(cloud_id, expected_name: guest_name).and_return(success: true, status: "terminated")

    result = reap

    expect(result[:success]).to be true
    expect(result[:data]).to include(reaped: true, cloud_instance_id: cloud_id, guest_name: guest_name)
  end

  it "reports an already-gone guest as nothing left to reap when the inventory no longer lists it" do
    allow(adapter).to receive(:list_instances).and_return(listing([ "someone-else", cloud_id ]))
    expect(adapter).not_to receive(:terminate_instance)

    result = reap

    expect(result[:success]).to be true
    expect(result[:data]).to include(reaped: false, already_gone: true)
  end

  it "refuses, without terminating, when the inventory cannot be read" do
    allow(adapter).to receive(:list_instances).and_return(listing(success: false))
    expect(adapter).not_to receive(:terminate_instance)

    expect(reap[:success]).to be false
  end

  it "refuses, without terminating, when the inventory is truncated" do
    allow(adapter).to receive(:list_instances).and_return(listing([ guest_name, cloud_id ], truncated: true))
    expect(adapter).not_to receive(:terminate_instance)

    expect(reap[:success]).to be false
  end

  it "reports a provider NotFound from the terminate as already gone" do
    allow(adapter).to receive(:terminate_instance)
      .and_return(success: false, error_code: "NotFound", error: "Instance not found")

    expect(reap[:data]).to include(reaped: false, already_gone: true)
  end

  it "reports a raised ResourceNotFoundError from the terminate as already gone" do
    allow(adapter).to receive(:terminate_instance)
      .and_raise(System::Providers::BaseProvider::ResourceNotFoundError, "gone")

    result = reap

    expect(result[:success]).to be true
    expect(result[:data]).to include(reaped: false, already_gone: true)
  end

  it "refuses when the id now holds a DIFFERENT guest" do
    allow(adapter).to receive(:terminate_instance).and_return(
      success: false, error_code: System::Providers::BaseProvider::GUEST_NAME_MISMATCH,
      error: "PVE terminate refused: pve1/qemu/9002 is guest \"sdwan-testbed-a\""
    )

    result = reap

    expect(result[:success]).to be false
    expect(result[:error]).to include("sdwan-testbed-a")
  end

  it "refuses when a platform row has come to know the guest since it was reported" do
    node = create(:system_node, account: account, node_template: node_template)
    row = create(:system_node_instance, node: node, status: "running")
    row.merge_config!("provider_guest_name" => guest_name)
    expect(adapter).not_to receive(:terminate_instance)

    result = reap

    expect(result[:success]).to be false
    expect(result[:error]).to match(/no longer an orphan/i)
  end

  it "refuses a guest that is not named for the pool" do
    expect(adapter).not_to receive(:terminate_instance)

    result = reap(name: "sdwan-testbed-a")

    expect(result[:success]).to be false
    expect(result[:error]).to match(/not named for pool/i)
  end

  it "refuses a guest a longer-named pool of the account claims" do
    make_pool("ci-builders-pool-gpu", lifecycle_class: "spot")
    expect(adapter).not_to receive(:terminate_instance)

    expect(reap(name: "ci-builders-pool-gpu-pool-1-0")[:success]).to be false
  end

  it "refuses once the pool is no longer ephemeral" do
    pool.update!(lifecycle_class: "spot")
    expect(adapter).not_to receive(:terminate_instance)

    expect(reap[:error]).to match(/not ephemeral/i)
  end

  it "refuses when another account also has a pool of that name" do
    other = create(:account)
    make_pool("ci-builders", owner: other, template: create(:system_node_template, account: other))
    expect(adapter).not_to receive(:terminate_instance)

    expect(reap[:error]).to match(/ambiguous/i)
  end

  it "refuses a pool outside the account" do
    expect(adapter).not_to receive(:terminate_instance)

    expect(reap(pool_id: SecureRandom.uuid)[:success]).to be false
  end

  # The sensor also lists a pool's preferred regions, which can sit behind a
  # different connection: the reap asks THAT region's inventory, not the pool's.
  it "confirms and reaps in the preferred region the guest was listed in" do
    elsewhere = create(:system_provider_region, account: account)
    pool.update!(preferred_regions: [ elsewhere.id ])
    other_adapter = instance_double("System::Providers::BaseProvider")
    allow(adapter).to receive(:list_instances).and_return(listing)
    allow(System::Providers::Registry).to receive(:for).with(connection, region: elsewhere).and_return(other_adapter)
    allow(other_adapter).to receive(:supports?).with(:sync).and_return(true)
    allow(other_adapter).to receive(:list_instances).and_return(listing([ guest_name, cloud_id ]))
    expect(other_adapter).to receive(:terminate_instance)
      .with(cloud_id, expected_name: guest_name).and_return(success: true, status: "terminated")

    result = described_class.new(account: account, agent: nil, user: nil)
                            .execute(gated: true, instance_pool_id: pool.id, cloud_instance_id: cloud_id,
                                     guest_name: guest_name, provider_region_id: elsewhere.id)

    expect(result[:data]).to include(reaped: true)
  end

  it "refuses a region that is not one of the pool's" do
    foreign = create(:system_provider_region)
    expect(adapter).not_to receive(:terminate_instance)

    result = described_class.new(account: account, agent: nil, user: nil)
                            .execute(gated: true, instance_pool_id: pool.id, cloud_instance_id: cloud_id,
                                     guest_name: guest_name, provider_region_id: foreign.id)

    expect(result[:error]).to match(/not one of pool/i)
  end

  it "refuses when the pool's region has no usable provider connection" do
    allow(System::Providers::Registry).to receive(:find_connection_for_region).and_return(nil)

    expect(reap[:success]).to be false
  end

  # The executor's own gate, through Ai::EnvironmentResolution and the overlay,
  # with the category's auto_approve verdict: runs in an unprotected plane,
  # parks in a protected one.
  describe "the gate" do
    let(:user) { create(:user, account: account) }

    before do
      Ai::InterventionPolicy.create!(account: account, action_category: "system.pool_guest_reap",
                                     scope: "action_type", policy: "auto_approve", priority: 10, is_active: true)
      allow(adapter).to receive(:terminate_instance).and_return(success: true, status: "terminated")
    end

    it "proceeds for a pool in an unprotected plane" do
      pool.update!(environment: account.environments.find_by!(slug: "dev"))

      result = reap(gated: false, user: user)

      expect(result[:success]).to be true
      expect(result.dig(:data, :reaped)).to be true
    end

    it "parks for approval, destroying nothing, for a pool in a protected plane" do
      pool.update!(environment: account.environments.find_by!(slug: "ops"))

      result = reap(gated: false, user: user)

      expect(result.dig(:data, :pending)).to be true
      expect(adapter).not_to have_received(:terminate_instance)
    end
  end

  describe "the fleet lane" do
    let(:binding) { System::Fleet::DecisionEngine::SIGNAL_BINDINGS["system.pool_guest_orphaned"] }
    let(:signal) do
      System::Fleet::Signal.from_hash(
        "kind" => "system.pool_guest_orphaned", "severity" => "high",
        "payload" => { "instance_pool_id" => pool.id, "environment_id" => pool.environment_id,
                       "cloud_instance_id" => cloud_id, "guest_name" => guest_name,
                       "provider_region_id" => provider_region.id },
        "fingerprint" => "pool_guest_orphaned:#{cloud_id}:#{guest_name}"
      )
    end

    it "binds the orphan signal to this executor under the reap category, owned by the Capacity Manager" do
      expect(binding).to include(skill: described_class, action_category: "system.pool_guest_reap",
                                 side_effectful: true, owner: "capacity-manager")
      expect(binding[:input_mapper].call(signal)).to eq(
        instance_pool_id: pool.id, cloud_instance_id: cloud_id, guest_name: guest_name,
        provider_region_id: provider_region.id
      )
    end

    it "declares the category for the Capacity Manager as auto-proceeding (ci / ephemeral auto)" do
      expect(System::Governance::PolicyDeclarations::CAPACITY_MANAGER_POLICIES["system.pool_guest_reap"])
        .to eq("auto_approve")
    end

    it "places the lane in the pool's plane: an unprotected plane proceeds" do
      ci = create(:ai_environment, account: account, slug: "ci-lane", is_protected: false)
      pool.update!(environment: ci)

      placed = Ai::EnvironmentResolution.resolve(account: account, params: binding[:input_mapper].call(signal))

      expect(placed).to eq(ci)
      expect(Ai::EnvironmentPolicyOverlay.escalation_reason(placed, "system.pool_guest_reap")).to be_nil
    end

    it "places the lane in the pool's plane: a protected plane parks it" do
      ops = create(:ai_environment, account: account, slug: "ops-lane", is_protected: true,
                                    default_decision_authority: "monitored")
      pool.update!(environment: ops)

      placed = Ai::EnvironmentResolution.resolve(account: account, params: binding[:input_mapper].call(signal))

      expect(placed).to eq(ops)
      expect(Ai::EnvironmentPolicyOverlay.escalation_reason(placed, "system.pool_guest_reap"))
        .to match(/protected/)
    end
  end
end
