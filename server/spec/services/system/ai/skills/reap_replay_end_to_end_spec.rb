# frozen_string_literal: true

require "rails_helper"

# IMP-4e49eb79c5e0 — the APO-4 reap replay was PINNED AT BOTH ENDS and driven
# at neither.
#
# What already had coverage before this file:
#
#   * replace_instance_executor_spec asserts a `reap: true` replace parks an
#     Ai::DeferredOperation whose action_category is system.instance_reap and
#     whose executor_class is ReapInstanceExecutor — i.e. the ROW is right;
#   * reap_instance_executor_spec asserts that ReapInstanceExecutor, called
#     with `gated: true`, terminates through the provider — i.e. the EXECUTOR
#     is right when someone calls it.
#
# Neither drives the middle. Between them sit Ai::ApprovalRequest's release,
# Ai::DeferredOperation#execute_now!, #assert_source_within_account!, and
# BaseSkillExecutor.execute's rebuild of the executor from the stored params —
# and a params-key mismatch, a source anchor the account assertion rejects, or
# an executor_class that no longer resolves would leave BOTH existing specs
# green while a released approval terminated nothing at all. That is the
# "deferral to an unbuilt component" shape: an operator sees an approval card,
# approves it, and the box stays up.
#
# The oracle here is the PROVIDER CALL and the instance row, never the
# operation's own status: `complete!` stamps a row whether or not the terminate
# happened, so asserting on the row's state would pass for a replay that ran
# nothing.
RSpec.describe "APO-4 reap replay, approval to terminate (IMP-4e49eb79c5e0)", type: :service do
  let(:account)                { create(:account) }
  let(:node_template)          { create(:system_node_template, account: account) }
  let(:provider_region)        { create(:system_provider_region) }
  let(:provider_instance_type) { create(:system_provider_instance_type) }

  let(:pool) do
    System::InstancePool.create!(
      account: account, node_template: node_template, name: "dr-pool",
      target_size: 2, min_size: 1, max_size: 4, lifecycle_class: "ephemeral",
      status: "active", provider_region: provider_region,
      provider_instance_type: provider_instance_type
    )
  end

  def pool_member(pool_state:, status:)
    node = create(:system_node, account: account, node_template: node_template)
    create(:system_node_instance,
           node: node, name: "m-#{SecureRandom.hex(3)}", variety: "cloud",
           status: status, provider_region: provider_region,
           provider_instance_type: provider_instance_type,
           instance_pool_id: pool.id, pool_state: pool_state,
           pool_warming_started_at: 5.minutes.ago)
  end

  let!(:failed) { pool_member(pool_state: "claimed", status: "error") }
  let!(:spare)  { pool_member(pool_state: "ready",   status: "running") }

  let(:provider) { instance_double(System::Providers::MockProvider, provider_type: "mock") }

  before do
    allow(System::Providers::Registry).to receive(:for_volume).and_return(provider)
    allow(System::Providers::Registry).to receive(:for_instance).and_return(provider)
    allow(provider).to receive(:detach_volume).and_return({ success: true })
    allow(provider).to receive(:attach_volume).and_return({ success: true, device: "/dev/sdf" })
    allow(provider).to receive(:terminate_instance).and_return({ success: true })
  end

  # The whole point is that NOTHING is stubbed between the replace and the
  # terminate: the replace parks the row the gate wrote, and the release is the
  # only thing that happens next.
  def replace_asking_for_reap(operation_id: "op-e2e")
    System::Ai::Skills::ReplaceInstanceExecutor
      .new(account: account, agent: nil, user: nil)
      .execute(gated: true, instance_id: failed.id, operation_id: operation_id, reap: true)
  end

  def parked_reap
    Ai::DeferredOperation.where(account_id: account.id,
                                action_category: "system.instance_reap")
                         .order(:created_at).last
  end

  it "terminates the failed instance when the parked reap is released" do
    result = replace_asking_for_reap

    expect(result[:success]).to be(true), "the replace failed: #{result[:error]}"
    expect(result.dig(:data, :reap_decision)).to eq("pending")
    expect(provider).not_to have_received(:terminate_instance)

    operation = parked_reap
    expect(operation).to be_present, "the replace parked no reap operation to release"

    operation.execute_now!

    expect(provider).to have_received(:terminate_instance).once
  end

  it "carries the replace's operation_id through the replay onto the reap event" do
    replace_asking_for_reap(operation_id: "op-carried")

    parked_reap.execute_now!

    event = System::FleetEvent
              .where(account_id: account.id, kind: "system.instance_replace.reap")
              .where("payload->>'operation_id' = ?", "op-carried").first

    expect(event).to be_present,
                     "the replay lost the replace's idempotency key, so a re-release " \
                     "would terminate a second time"
    expect(event.payload["failed_instance_id"]).to eq(failed.id)
  end

  # The replay MUST NOT park a second approval for the decision that just
  # completed — BaseSkillExecutor.execute passes `gated: true` for exactly this
  # reason, and a regression there is invisible to both existing specs.
  it "parks no second approval on the released reap" do
    replace_asking_for_reap(operation_id: "op-once")
    operation = parked_reap

    expect { operation.execute_now! }.not_to change(Ai::DeferredOperation, :count)
  end

  # A release that lands twice (operator double-click, retried worker) must not
  # ask the provider to terminate twice. Recorded here because the end-to-end
  # drive is the only place the two brakes are visible together: the operation's
  # own state machine refuses a second run outright (`completed` has no
  # start_execution transition), and the executor's operation_id/FleetEvent
  # idempotency — the one reap_instance_executor_spec exercises directly — sits
  # behind it. Neither is load-bearing alone.
  it "cannot be released twice into a second terminate" do
    replace_asking_for_reap(operation_id: "op-double")
    operation = parked_reap
    operation.execute_now!

    expect { Ai::DeferredOperation.find(operation.id).execute_now! }
      .to raise_error(AASM::InvalidTransition)

    expect(provider).to have_received(:terminate_instance).once
  end

  # The approval-request door, not just the operation door: an operator
  # releases an Ai::ApprovalRequest, and it is that release which is supposed
  # to reach #execute_now!. If the two are not wired, every example above still
  # passes while the card an operator actually sees does nothing.
  it "terminates when the operator's approval request is approved" do
    replace_asking_for_reap(operation_id: "op-card")

    request = Ai::ApprovalRequest.where(account_id: account.id,
                                        source_type: "Ai::DeferredOperation",
                                        source_id: parked_reap.id).last
    expect(request).to be_present, "no approval card was raised for the reap"

    # #approve! flips the status, and the after_update callback is what reaches
    # Ai::DeferredOperation#execute_now!. Driving the CARD rather than the
    # operation is the point: it is the only thing an operator touches.
    request.approve!

    expect(provider).to have_received(:terminate_instance).once
  end
end
