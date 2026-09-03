# frozen_string_literal: true

require "rails_helper"

# IMP-68403ec0358d — general-purpose caller attribution for pool acquisitions.
#
# BEFORE: System::InstancePoolService#acquire! wrote EXACTLY two columns on the
# winning member (`pool_state: "claimed"`, `pool_acquired_at: Time.current`) and
# emitted nothing. The only trace of an acquirer was a Rails.logger.info line
# carrying pool_id and member_id — no caller identity at all. System::CiRunnerLease
# is the one attribution-bearing wrapper around acquire!, and it is specific to
# Gitea Act runner leases; the other four callers recorded nothing.
#
# WHY THE ORACLE IS "SURVIVES A RELEASE", NOT "IS WRITTEN AT ACQUIRE TIME.
# #release! CLEARS the member's claim columns on every disposition it has
# (`pool_acquired_at: nil` on both the reuse and the recycle branch), so
# attribution stored ON THE MEMBER ROW would be erased by the return — and
# "who used this last month" is the only question attribution exists to answer.
# An example that asserted only the acquire-time value would pass against that
# rejected design. Every example below therefore reads the attribution back
# AFTER the release has completed.
#
# ALL THREE DISPOSITIONS ARE COVERED, deliberately. #release! has three, not
# two: "reused" (opt-in reuse_without_reset pools), "recycled" (the default) and
# "errored" — the branch where terminate_member fails and the member rests at
# pool_state="errored" with a VM that may still exist and still bill. A billing
# VM with nobody recorded against it is the exact case attribution exists for,
# and it is the one a two-way happy/recycled model loses.
RSpec.describe "pool claim attribution", type: :service do
  let(:account) { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }
  let(:provider_region) { create(:system_provider_region) }
  let(:provider_instance_type) { create(:system_provider_instance_type) }

  let(:pool) do
    System::InstancePool.create!(
      account: account,
      node_template: node_template,
      name: "attribution-pool",
      target_size: 1,
      min_size: 0,
      max_size: 5,
      lifecycle_class: "ephemeral",
      status: "active",
      provider_region: provider_region,
      provider_instance_type: provider_instance_type
    )
  end

  def seed_ready_member
    node = create(:system_node, account: account, node_template: node_template,
                                lifecycle_class: "ephemeral")
    create(:system_node_instance,
           node: node,
           name: "member-#{SecureRandom.hex(3)}",
           variety: "cloud",
           status: "running",
           provider_region: provider_region,
           provider_instance_type: provider_instance_type,
           instance_pool_id: pool.id,
           pool_state: "ready",
           pool_warming_started_at: 5.minutes.ago)
  end

  def claim_events
    System::FleetEvent.where(account: account, kind: "system.pool.claimed").order(:emitted_at)
  end

  def release_events
    System::FleetEvent.where(account: account, kind: "system.pool.released").order(:emitted_at)
  end

  # The full round trip, returning what an auditor would have to work with
  # after the member is back in (or out of) circulation.
  def acquire_then_release(reuse: false, terminate_ok: true)
    member = seed_ready_member
    pool.update!(metadata: { "reuse_without_reset" => true }) if reuse
    allow(::System::ProvisioningService).to receive(:terminate_instance).and_return(
      terminate_ok ? ::System::Runtime::Result.ok : ::System::Runtime::Result.err(error: "provider refused")
    )

    service = System::InstancePoolService.new(account: account)
    acquired = service.acquire!(pool_id: pool.id,
                                acquired_by: "ci-job-12345",
                                acquired_for: "build-pipeline-1234")
    claim_id = service.last_claim_id

    disposition = System::InstancePoolService.release!(instance: acquired.reload, pool: pool.reload)

    { member: acquired.reload, claim_id: claim_id, disposition: disposition }
  end

  describe "#acquire! with caller attribution" do
    it "records the acquirer and the workload on a durable claim record" do
      service = System::InstancePoolService.new(account: account)
      member = seed_ready_member

      service.acquire!(pool_id: pool.id,
                       acquired_by: "ci-job-12345",
                       acquired_for: "build-pipeline-1234")

      expect(claim_events.count).to eq(1)
      event = claim_events.last
      expect(event.node_instance_id).to eq(member.id)
      expect(event.correlation_id).to eq(service.last_claim_id).and be_present
      expect(event.payload).to include(
        "acquired_by" => "ci-job-12345",
        "acquired_for" => "build-pipeline-1234",
        "pool_id" => pool.id,
        "pool_name" => pool.name
      )
    end

    it "still records a claim when the caller supplies no attribution" do
      seed_ready_member
      System::InstancePoolService.acquire!(account: account, pool_id: pool.id)

      expect(claim_events.count).to eq(1)
      expect(claim_events.last.payload["acquired_by"]).to be_nil
    end
  end

  # THE ORACLE. Read AFTER the release, on each of the three dispositions.
  describe "attribution after the member is released" do
    it "survives the reuse-without-reset disposition" do
      result = acquire_then_release(reuse: true)

      expect(result[:disposition]).to eq("reused")
      # The claim columns really are gone — this is what a column-based design
      # would have lost.
      expect(result[:member].pool_acquired_at).to be_nil
      expect(result[:member].pool_state).to eq("ready")

      closed = release_events.last
      expect(closed.correlation_id).to eq(result[:claim_id])
      expect(closed.payload).to include(
        "disposition" => "reused",
        "acquired_by" => "ci-job-12345",
        "acquired_for" => "build-pipeline-1234"
      )
    end

    it "survives the recycled disposition" do
      result = acquire_then_release(reuse: false, terminate_ok: true)

      expect(result[:disposition]).to eq("recycled")
      expect(result[:member].pool_acquired_at).to be_nil

      closed = release_events.last
      expect(closed.correlation_id).to eq(result[:claim_id])
      expect(closed.payload).to include(
        "disposition" => "recycled",
        "acquired_by" => "ci-job-12345",
        "acquired_for" => "build-pipeline-1234"
      )
    end

    # The disposition the first draft of this capability would have lost: the
    # member rests at pool_state="errored" with a VM that may still be running
    # and billing. Nobody recorded against a billing VM is the whole point.
    it "survives the errored disposition, where the VM may still exist and bill" do
      result = acquire_then_release(reuse: false, terminate_ok: false)

      expect(result[:disposition]).to eq("errored")
      expect(result[:member].pool_state).to eq("errored")

      closed = release_events.last
      expect(closed.correlation_id).to eq(result[:claim_id])
      expect(closed.payload).to include(
        "disposition" => "errored",
        "acquired_by" => "ci-job-12345",
        "acquired_for" => "build-pipeline-1234"
      )
    end

    it "reports how long the claim was held, so the record can be costed" do
      result = acquire_then_release(reuse: false, terminate_ok: true)

      expect(release_events.last.payload["held_seconds"]).to be_a(Numeric).and be >= 0
    end
  end

  # A member claimed before this capability shipped has no claim event to
  # correlate to. The release must still be recorded rather than raising or
  # being skipped — the disposition is the half of the record that cannot be
  # reconstructed later.
  describe "release of a claim that predates the ledger" do
    it "records the disposition with a null claim id instead of failing" do
      node = create(:system_node, account: account, node_template: node_template,
                                  lifecycle_class: "ephemeral")
      legacy = create(:system_node_instance,
                      node: node, variety: "cloud", status: "running",
                      provider_region: provider_region,
                      provider_instance_type: provider_instance_type,
                      instance_pool_id: pool.id,
                      pool_state: "claimed",
                      pool_warming_started_at: 1.hour.ago,
                      pool_acquired_at: 30.minutes.ago)
      allow(::System::ProvisioningService).to receive(:terminate_instance)
        .and_return(::System::Runtime::Result.ok)

      expect { System::InstancePoolService.release!(instance: legacy, pool: pool) }.not_to raise_error

      closed = release_events.last
      expect(closed).to be_present
      expect(closed.node_instance_id).to eq(legacy.id)
      expect(closed.payload["disposition"]).to eq("recycled")
      expect(closed.payload["claim_id"]).to be_nil
    end
  end

  # Attribution that is silently dropped is worse than none: the caller
  # believes it was recorded. The claim event is written INSIDE acquire!'s
  # transaction and is not routed through EventBroadcaster.emit!, whose
  # `rescue StandardError => nil` would swallow the loss.
  describe "fail-closed on a claim the ledger cannot record" do
    it "rolls the claim back rather than handing out an unattributed member" do
      member = seed_ready_member
      allow(::System::FleetEvent).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "ledger down")

      expect do
        System::InstancePoolService.acquire!(account: account, pool_id: pool.id, acquired_by: "auditor")
      end.to raise_error(ActiveRecord::StatementInvalid)

      expect(member.reload.pool_state).to eq("ready")
      expect(member.pool_acquired_at).to be_nil
    end
  end

  describe "the MCP door" do
    let(:tool) { Ai::Tools::SystemFleetTool.new(account: account, internal: true) }

    it "declares acquired_by and acquired_for so they are not silently dropped" do
      params = Ai::Tools::SystemFleetTool.action_definitions
                                         .fetch("system_acquire_pooled_instance")[:parameters]

      expect(params.keys).to include(:acquired_by, :acquired_for)
      expect(params[:acquired_by][:required]).to be false
      expect(params[:acquired_for][:required]).to be false
    end

    it "carries the declared attribution through to the durable claim record" do
      member = seed_ready_member

      r = tool.execute(params: { action: "system_acquire_pooled_instance",
                                 pool_id: pool.id,
                                 acquired_by: "ci-job-12345",
                                 acquired_for: "build-pipeline-1234" })

      expect(r[:success]).to be true
      expect(r.dig(:data, :claim, :id)).to be_present
      expect(r.dig(:data, :claim, :acquired_by)).to eq("ci-job-12345")

      event = claim_events.last
      expect(event.node_instance_id).to eq(member.id)
      expect(event.correlation_id).to eq(r.dig(:data, :claim, :id))
      expect(event.payload["acquired_for"]).to eq("build-pipeline-1234")
    end
  end
end
