# frozen_string_literal: true

require "rails_helper"

# IMP-a18da6f5e05c — an APPROVED disk-image rollback recorded no fleet event.
#
# The mirror of IMP-4de09f201a0f. There, a domain event was emitted from both
# the executor and the controller closure and fired twice. Here it was emitted
# from the controller ONLY, on the arm reached when policy resolves to proceed
# inline, while System::Executors::DiskImage::RollbackPublication emitted
# nothing. So a rollback that was parked for approval and then approved rolled
# the platform back and wrote no event at all.
#
# WHICH ROLLBACKS WENT UNRECORDED IS THE POINT. Not a random sample: exactly
# the ones a human deliberated over. The seeded policy for
# system.disk_image_publication_rollback is require_approval, so on a
# deployment with an approval chain the approved path is the NORMAL path and
# the inline one is the exception. An operator reconstructing which image a
# platform was rolled back to, and when, was reading a log missing the
# deliberate rollbacks and containing only the automatic ones.
#
# The rule both tasks share: a domain event describing what happened to the
# resource belongs to the EXECUTOR, the only arm that runs on every branch the
# operation completes on. A request-context audit row is the narrow exception
# and belongs to the controller. Stated in Ai::GatedActions.
#
# TWO MORE DOORS reach the same executor with `deferred_operation: nil` —
# Ai::Tools::SystemFleetTool#revert_disk_image and
# System::Ai::Skills::DiskImageRollbackExecutor — so an MCP- or agent-initiated
# rollback also emitted nothing. Moving the emitter covers both. The last
# example pins that shape; it calls the executor directly rather than driving
# either tool, so it proves the emit and the nil-safety, not the tools' wiring.
RSpec.describe "Disk image rollback emits exactly one fleet event", type: :request do
  let(:account) { create(:account) }
  let(:operator) do
    user_with_permissions("system.platforms.rollback_disk_image", account: account)
  end
  let(:platform) { create(:system_node_platform, account: account) }

  # The currently-active publication, and the older one we roll back TO.
  let!(:prior) { create(:system_disk_image_publication, :published, account: account, node_platform: platform) }
  let!(:active) { create(:system_disk_image_publication, :published, account: account, node_platform: platform) }

  before { platform.update!(disk_image_file_object_id: active.file_object_id) }

  # Captured on the broadcaster rather than counted in the DB so the assertion
  # is about the EMIT, not about whatever a row happens to persist.
  def capture_events!
    events = []
    allow(::System::Fleet::EventBroadcaster).to receive(:emit!) do |**kwargs|
      events << kwargs
      nil
    end
    events
  end

  def rollbacks(events)
    events.select { |e| e[:kind] == "system.disk_image_rolled_back" }
  end

  def rollback!
    post "/api/v1/system/node_platforms/#{platform.id}/rollback_disk_image",
         params: { publication_id: prior.id }.to_json,
         headers: auth_headers_for(operator).merge("Content-Type" => "application/json")
  end

  # `approve_latest_deferred!` runs `execute_now!` on the parked row, which is
  # the tail of the approval path rather than the whole of it — it does not go
  # through ApprovalRequest#approve! and its after_update callback. That is the
  # right seam for THIS assertion, since the emit lives in the executor, but it
  # means these examples do not prove the approval callback wiring.
  describe "the APPROVED branch — the one that recorded nothing" do
    it "emits exactly one rolled-back event when the rollback is approved" do
      events = capture_events!

      # require_approval, never notify_and_proceed: the latter executes inline
      # and would leave nothing parked, silently exercising the branch that
      # already worked. The row is belt-and-braces — the service's default for
      # an unmatched category is already require_approval — and it is written
      # explicitly so this example does not silently change meaning if that
      # default ever does.
      ::Ai::InterventionPolicy.create!(
        account: account, ai_agent_id: nil, scope: "action_type",
        action_category: "system.disk_image_publication_rollback",
        policy: "require_approval", priority: 5, is_active: true
      )

      rollback!
      expect(response).to have_http_status(:accepted)
      expect(json_response_data["pending"]).to eq(true)
      expect(rollbacks(events)).to be_empty,
        "nothing has been rolled back yet — a parked request must not emit"

      approve_latest_deferred!

      expect(platform.reload.disk_image_file_object_id).to eq(prior.file_object_id),
        "the approved rollback should have moved the platform pointer"
      expect(rollbacks(events).size).to eq(1),
        "the approved rollback emitted #{rollbacks(events).size} events; " \
        "an operator reading the fleet log cannot see it happened."
    end

    it "carries the platform, the target and the prior artifact on the approved branch" do
      events = capture_events!
      ::Ai::InterventionPolicy.create!(
        account: account, ai_agent_id: nil, scope: "action_type",
        action_category: "system.disk_image_publication_rollback",
        policy: "require_approval", priority: 5, is_active: true
      )
      previously_active_file_object_id = platform.disk_image_file_object_id

      rollback!
      approve_latest_deferred!

      payload = rollbacks(events).first&.dig(:payload)
      expect(payload).to be_present
      expect(payload[:platform_id]).to eq(platform.id)
      expect(payload[:activated_publication_id]).to eq(prior.id)
      expect(payload[:prior_file_object_id]).to eq(previously_active_file_object_id)
      # Attribution survives the move: the controller's copy had by_user_id and
      # could never set it on this branch, because it never ran here.
      expect(payload[:by_user_id]).to eq(operator.id),
        "the approved rollback lost the requester — the fleet log cannot say who asked for it"
    end
  end

  describe "the INLINE branch — must not gain a second event" do
    it "emits exactly one rolled-back event" do
      events = capture_events!
      allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
        { policy: "auto_approve", channels: [], conditions: {}, record: nil }
      )

      rollback!

      expect(response).to have_http_status(:ok)
      expect(platform.reload.disk_image_file_object_id).to eq(prior.file_object_id)
      expect(rollbacks(events).size).to eq(1),
        "expected ONE event on the inline branch, got #{rollbacks(events).size}"
    end

    it "still renders the prior artifact id the operator UI reads" do
      allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
        { policy: "auto_approve", channels: [], conditions: {}, record: nil }
      )
      previously_active_file_object_id = platform.disk_image_file_object_id

      rollback!

      expect(response).to have_http_status(:ok)
      expect(json_response_data["platform_id"]).to eq(platform.id)
      expect(json_response_data["activated_publication_id"]).to eq(prior.id)
      expect(json_response_data["prior_file_object_id"]).to eq(previously_active_file_object_id)
    end
  end

  describe "a BLOCKED rollback" do
    it "emits nothing, because nothing happened" do
      events = capture_events!
      ::Ai::InterventionPolicy.create!(
        account: account, ai_agent_id: nil, scope: "action_type",
        action_category: "system.disk_image_publication_rollback",
        policy: "block", priority: 5, is_active: true
      )

      rollback!

      expect(response).to have_http_status(:unprocessable_content)
      expect(platform.reload.disk_image_file_object_id).to eq(active.file_object_id)
      expect(rollbacks(events)).to be_empty
    end
  end

  describe "the executor invoked with no deferred operation (the MCP and skill doors)" do
    it "emits one event, and does not raise on the nil attribution" do
      events = capture_events!

      ::System::Executors::DiskImage::RollbackPublication.execute(
        { target_publication_id: prior.id, platform_id: platform.id },
        deferred_operation: nil
      )

      expect(platform.reload.disk_image_file_object_id).to eq(prior.file_object_id)
      expect(rollbacks(events).size).to eq(1),
        "SystemFleetTool#revert_disk_image and DiskImageRollbackExecutor both call " \
        "the executor exactly like this; it must emit, and must not raise on the nil. " \
        "by_user_id is nil here because those callers drop the identity, which is " \
        "filed separately — not because no human asked."
    end
  end
end
