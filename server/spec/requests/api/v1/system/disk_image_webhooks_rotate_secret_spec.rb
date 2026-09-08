# frozen_string_literal: true

require "rails_helper"

# IMP-b5b9544fc993 — rotate_secret rendered no webhook_url.
#
# `create` returns webhook_url; `rotate_secret` did not, yet both are typed on
# the frontend as one response with webhook_url REQUIRED, and CiWebhooksTab
# renders `Webhook URL: ${createdSecret.webhook_url}` for whichever of the two
# produced the value. So after a rotation the operator read
# "Webhook URL: undefined" in the modal that is shown exactly once and is their
# only chance to copy the new secret — a panel telling them to update their CI
# configuration while reporting the URL as undefined.
#
# The path is asserted against the MODEL's emitted value rather than a literal
# repeated here. The literal itself is pinned, separately and deliberately, by
# frontend .../services/api/diskImageWebhookPath.contract.test.ts — without
# that file this spec and the code could drift together and stay green, so do
# not delete it believing this spec covers the same ground.
#
# BOTH gate branches are exercised. The inline branch renders through the
# controller; the deferred branch renders through
# Executors::DiskImage::TriggerWebhook, and that copy was missing entirely, so
# an operator whose rotation was approved asynchronously received a secret with
# no URL beside it.
RSpec.describe "Api::V1::System::DiskImageWebhooks rotate_secret", type: :request do
  let(:account) { create(:account) }
  let(:operator) do
    user_with_permissions("system.disk_image_webhooks.rotate_secret", account: account)
  end
  let(:creator) do
    user_with_permissions(
      "system.disk_image_webhooks.create",
      "system.disk_image_webhooks.rotate_secret",
      account: account
    )
  end
  let(:webhook) { create(:system_disk_image_webhook, account: account) }

  def rotate!
    post "/api/v1/system/disk_image_webhooks/#{webhook.id}/rotate_secret",
         headers: auth_headers_for(operator).merge("Content-Type" => "application/json")
  end

  def auto_approve_policy!
    allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
      { policy: "auto_approve", channels: [], conditions: {}, record: nil }
    )
  end

  it "returns the webhook_url alongside the new secret" do
    auto_approve_policy!
    rotate!

    expect(response).to have_http_status(:ok)
    expect(json_response_data["secret_plaintext"]).to be_present

    serialized_path = webhook.reload.webhook_url_path

    expect(json_response_data["webhook_url"]).to be_present,
      "rotate_secret rendered no webhook_url; the operator's one-time modal shows 'undefined'"
    expect(json_response_data["webhook_url"]).to end_with(serialized_path)
  end

  it "returns the same webhook_url that create returned for that webhook" do
    # One-builder invariant. Both actions call the same helper today, so this
    # cannot catch a wrong path — the contract test does that. What it catches
    # is someone giving rotate its own builder, after which rotating would hand
    # the operator a URL differing from the one they configured in CI, with
    # nothing in either response signalling the change.
    auto_approve_policy!

    post "/api/v1/system/disk_image_webhooks",
         params: { label: "release-pipeline" }.to_json,
         headers: auth_headers_for(creator).merge("Content-Type" => "application/json")
    expect(response).to have_http_status(:ok)
    created_url = json_response_data["webhook_url"]
    created_id  = json_response_data.dig("disk_image_webhook", "id")
    expect(created_url).to be_present

    post "/api/v1/system/disk_image_webhooks/#{created_id}/rotate_secret",
         headers: auth_headers_for(operator).merge("Content-Type" => "application/json")

    expect(response).to have_http_status(:ok)
    expect(json_response_data["webhook_url"]).to eq(created_url)
  end
  it "carries the webhook_url on the DEFERRED branch too" do
    # require_approval, not notify_and_proceed: the latter runs the executor
    # immediately, which leaves nothing parked to approve. A real policy row
    # rather than a stub, so policy resolution is exercised too.
    ::Ai::InterventionPolicy.create!(
      account: account, ai_agent_id: nil, scope: "action_type",
      action_category: "system.disk_image_webhook_rotate_secret",
      policy: "require_approval", priority: 5, is_active: true
    )
    rotate!
    expect(response).to have_http_status(:accepted)
    expect(json_response_data["pending"]).to eq(true)

    # execute_now! hands back the executor's raw return wrapped in the
    # standard success/data envelope; the reveal-once slot carries the same
    # payload to the approval-decision response.
    result = approve_latest_deferred!.fetch(:data)

    expect(result[:secret_plaintext]).to be_present
    url = result[:webhook_url]
    expect(url).to be_present,
      "the deferred rotate returned no webhook_url; an asynchronously approved " \
      "rotation hands the operator a secret with nothing to paste it beside"
    expect(url).to end_with(webhook.reload.webhook_url_path)
  end
end
