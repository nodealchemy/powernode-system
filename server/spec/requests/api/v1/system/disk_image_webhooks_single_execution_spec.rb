# frozen_string_literal: true

require "rails_helper"

# IMP-4de09f201a0f — the autonomy gate's proceed branch ran the gated work TWICE.
#
# `Ai::AutonomyGate#evaluate` calls `deferred.execute_now!` on the
# auto_approve / notify_and_proceed branch, which runs the EXECUTOR. `gate!`
# then calls the caller's `on_proceed` closure. Where that closure performed
# the operation instead of merely rendering it, the operation happened twice.
#
# WHY THIS IS THE FILE THAT CATCHES IT. The double-execution is invisible for
# an idempotent action: a second `update!(status: "revoked")` on an already
# revoked row is a no-op, so a revoke spec stays green while the defect is
# fully present. Rotation MINTS material, so the executor's secret was minted,
# superseded by the closure's, and thrown away — two secrets and two fleet
# events for one operator action.
#
# WHAT THE FINDING GOT WRONG, recorded so it is not re-asserted: it said the
# deferred operation persisted the superseded plaintext, so an operator reading
# the audit trail to answer "which secret did we issue" got a dead answer. That
# was true until 2026-08-13, when DeferredOperation#execute_now! began
# completing through Ai::SensitiveParams.filter; `secret_plaintext` matches its
# `secret` rule, so the stored copy is masked. The filter is applied AT WRITE
# and is not retroactive, so rows completed before that date still hold a
# plaintext — a backfill question, not this task's.
#
# THE CONTRACT THESE EXAMPLES PIN: on the proceed branch the EXECUTOR is the
# sole authority and `on_proceed` only renders what it returned. Of roughly
# thirty hand-written closures in the tree, four had drifted off it — the two
# here, the instance-pool destroy below, and the Kubernetes cluster destroy in
# core. The deferred branch settles the argument on its own: there the closure
# never runs at all, so anything it alone performs simply does not happen for
# an operator whose action needed approval.
#
# NOT EVERY EXAMPLE HERE IS AN ORACLE FOR THE FIX. Four are — the two counters,
# the pool status, and the pool's 404. The redaction and authentication
# examples passed with the defect present and are PINS: they guard the two
# properties that made the defect survivable, so that a later change cannot
# quietly remove them.
RSpec.describe "Api::V1::System::DiskImageWebhooks gated actions run exactly once", type: :request do
  let(:account) { create(:account) }
  let(:operator) do
    user_with_permissions(
      "system.disk_image_webhooks.rotate_secret",
      "system.disk_image_webhooks.delete",
      account: account
    )
  end
  let(:webhook) { create(:system_disk_image_webhook, account: account) }

  def auto_approve_policy!
    allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
      { policy: "auto_approve", channels: [], conditions: {}, record: nil }
    )
  end

  def rotate!
    post "/api/v1/system/disk_image_webhooks/#{webhook.id}/rotate_secret",
         headers: auth_headers_for(operator).merge("Content-Type" => "application/json")
  end

  describe "rotate_secret on the proceed branch" do
    it "mints exactly one secret" do
      auto_approve_policy!
      # Counted on the MODEL, which is the only thing that can mint one, so the
      # count is of real rotations and not of a stubbed seam that a refactor
      # could route around.
      calls = 0
      allow_any_instance_of(::System::DiskImageWebhook).to receive(:rotate_secret!).and_wrap_original do |m, *a|
        calls += 1
        m.call(*a)
      end

      rotate!

      expect(response).to have_http_status(:ok)
      expect(calls).to eq(1),
        "expected the gated rotation to mint ONE secret, minted #{calls}. " \
        "Two means the executor and the on_proceed closure both performed it."
    end

    it "emits exactly one secret-rotated fleet event" do
      skip "EventBroadcaster not loaded" unless defined?(::System::Fleet::EventBroadcaster)
      auto_approve_policy!
      emitted = []
      allow(::System::Fleet::EventBroadcaster).to receive(:emit!) do |**kwargs|
        emitted << kwargs[:kind]
        nil
      end

      rotate!

      expect(response).to have_http_status(:ok)
      expect(emitted.count("system.disk_image_webhook_secret_rotated")).to eq(1),
        "expected ONE rotated event, got #{emitted.count('system.disk_image_webhook_secret_rotated')}"
    end

    # CORRECTION to this task's finding, pinned so it cannot be re-asserted.
    # The finding said the deferred operation's persisted result "records the
    # secret that is NOT the live one". It does not, as of 2026-08-13:
    # `DeferredOperation#execute_now!` completes the row through
    # `Ai::SensitiveParams.filter`, and `secret_plaintext` matches its `secret`
    # name rule, so what is stored is a MASK on every branch. The finding
    # described the code as it was BEFORE that date, and the filter is applied
    # at write rather than retroactively, so rows completed earlier still hold
    # a plaintext.
    #
    # That is correct behaviour and this example exists to keep it correct:
    # redaction-at-rest is the reason the double-execution was survivable, and
    # a future change that started persisting the plaintext would turn this
    # task's defect into the disclosure the finding described.
    it "persists no secret plaintext in the deferred operation's result" do
      auto_approve_policy!
      rotate!

      expect(response).to have_http_status(:ok)
      expect(json_response_data["secret_plaintext"]).to be_present

      op = ::Ai::DeferredOperation.where(account: account,
                                         action_category: "system.disk_image_webhook_rotate_secret").last
      expect(op).to be_present, "the gate should have opened a deferred operation for the audit trail"

      recorded = op.result.to_h.deep_stringify_keys.dig("data", "secret_plaintext")
      expect(recorded).not_to eq(json_response_data["secret_plaintext"]),
        "the deferred operation stored the live plaintext — redaction-at-rest has regressed"
      expect(op.result.to_json).not_to include(json_response_data["secret_plaintext"])
    end

    # The live secret must be the one the caller was handed. When two arms ran,
    # the SECOND won, so this held by accident; it must hold by construction
    # once one arm runs.
    it "returns the secret that actually authenticates a delivery" do
      auto_approve_policy!
      rotate!

      expect(response).to have_http_status(:ok)
      returned = json_response_data["secret_plaintext"]
      expect(returned).to be_present

      body = '{"ok":true}'
      signature = "sha256=#{::OpenSSL::HMAC.hexdigest('SHA256', returned, body)}"
      expect(webhook.reload.verify_signature(body, signature)).to be(true),
        "the returned plaintext does not authenticate — a second rotation superseded it."
    end
  end

  # FOUND BY THE AUDIT this task required of every gate! caller, and the worst
  # instance of the defect in the tree — worse than the rotation it was raised
  # for, because it is visible to the operator as an outright failure.
  #
  # Executors::InstancePool::DeletePool DESTROYS the pool. The closure then
  # called `@pool.update!(status: "archived") if @pool.persisted?` and rendered
  # `@pool.reload.to_summary`. `@pool` is the instance loaded BEFORE the gate,
  # so `persisted?` was still true in memory; the UPDATE matched no row and
  # passed silently, and the RELOAD then raised RecordNotFound. The operator
  # deleting a pool got 404 "not found" for a deletion that had SUCCEEDED —
  # the exact "404 over an operation that actually succeeded" failure the
  # #gate_create! documentation warns about.
  describe "instance pool destroy on the proceed branch" do
    let(:pool_writer) do
      user_with_permissions("system.node_instances.read", "system.instances.create", account: account)
    end
    let(:template) { create(:system_node_template, account: account) }
    let!(:pool) do
      ::System::InstancePool.create!(
        account: account, name: "gate-once-#{SecureRandom.hex(3)}",
        node_template: template, target_size: 1, min_size: 0, max_size: 5,
        lifecycle_class: "ephemeral", status: "active"
      )
    end

    it "reports success for a deletion that succeeded" do
      auto_approve_policy!

      delete "/api/v1/system/instance_pools/#{pool.id}",
             headers: auth_headers_for(pool_writer).merge("Content-Type" => "application/json")

      expect(::System::InstancePool.exists?(pool.id)).to be(false),
        "the executor should have destroyed the pool"
      expect(response).to have_http_status(:ok),
        "the pool was deleted but the response said #{response.status}: #{response.body[0, 200]}"
      expect(json_response_data["deleted"]).to be(true)
      expect(json_response_data["id"]).to eq(pool.id)
    end
  end

  describe "revoke on the proceed branch" do
    # Idempotent, so it cannot fail on a count of state changes. Counting the
    # WRITE is what makes the same defect visible here.
    it "writes the revoked status exactly once" do
      auto_approve_policy!
      writes = 0
      allow_any_instance_of(::System::DiskImageWebhook).to receive(:update!).and_wrap_original do |m, *a|
        writes += 1 if a.first.is_a?(Hash) && a.first.symbolize_keys.key?(:status)
        m.call(*a)
      end

      delete "/api/v1/system/disk_image_webhooks/#{webhook.id}",
             headers: auth_headers_for(operator).merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:ok)
      expect(webhook.reload.status).to eq("revoked")
      expect(writes).to eq(1),
        "expected ONE status write, got #{writes} — executor and closure both wrote."
    end
  end
end
