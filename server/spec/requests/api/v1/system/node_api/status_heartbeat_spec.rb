# frozen_string_literal: true

require "rails_helper"

# Exercises the rewritten heartbeat endpoint (M0.M / M2 — agent post-enroll
# heartbeat). The endpoint persists into NodeInstance's dedicated runtime
# columns via record_heartbeat! and AASM-transitions the instance from a
# pre-running state into running on first heartbeat.
RSpec.describe "Api::V1::System::NodeApi::Status#heartbeat", type: :request do
  let(:account)       { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }
  let(:node)          { create(:system_node, account: account, node_template: node_template) }
  let(:instance)      { create(:system_node_instance, node: node, status: "pending") }

  let!(:active_cert) do
    System::NodeCertificate.create!(
      node_instance: instance,
      serial:         SecureRandom.hex(16),
      subject:        "CN=#{instance.id}",
      not_before:     1.hour.ago,
      not_after:      90.days.from_now,
      issuer_subject: "CN=Powernode Internal CA"
    )
  end

  let(:headers) do
    { "X-Forwarded-Tls-Client-Cert-Info" => CGI.escape(%(Subject="CN=#{instance.id}")) }
  end

  let(:body) do
    {
      boot_id:        "boot-test-1",
      agent_version:  "1.0.0-test",
      architecture:   "amd64",
      uptime_seconds: 42,
      module_digests: { "system-base" => "sha256:aaaa" },
      mount_state:    "mounted"
    }
  end

  describe "POST /api/v1/system/node_api/status/heartbeat" do
    it "persists telemetry into the dedicated NodeInstance columns" do
      post "/api/v1/system/node_api/status/heartbeat", params: body, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json.dig("data", "acknowledged")).to be(true)
      expect(json.dig("data", "next_poll_seconds")).to eq(30)

      instance.reload
      expect(instance.last_heartbeat_at).to be_within(5.seconds).of(Time.current)
      expect(instance.agent_version).to eq("1.0.0-test")
      expect(instance.boot_id).to eq("boot-test-1")
      expect(instance.running_module_digests).to eq("system-base" => "sha256:aaaa")
    end

    it "transitions pending → running on first heartbeat" do
      expect(instance.status).to eq("pending")

      post "/api/v1/system/node_api/status/heartbeat", params: body, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(instance.reload.status).to eq("running")
    end

    it "leaves status unchanged when already running" do
      instance.update!(status: "running")

      post "/api/v1/system/node_api/status/heartbeat", params: body, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(instance.reload.status).to eq("running")
    end

    # IMP-42cf03360656: a transient partition (or the presumed-dead reap)
    # leaves the instance in status "error". Once the agent's heartbeats
    # resume, this endpoint must self-heal it back to running instead of
    # stranding a healthy instance forever.
    it "recovers a stranded :error instance back to running once heartbeats resume" do
      instance.update!(status: "error")

      post "/api/v1/system/node_api/status/heartbeat", params: body, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(instance.reload.status).to eq("running")
    end

    it "tolerates a missing module_digests body field" do
      body.delete(:module_digests)
      post "/api/v1/system/node_api/status/heartbeat", params: body, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(instance.reload.running_module_digests).to eq({})
    end

    it "rejects requests with no auth token" do
      post "/api/v1/system/node_api/status/heartbeat", params: body, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it "persists booted_image_git_sha when provided" do
      booted_sha = "abc123def456"
      body[:booted_image_git_sha] = booted_sha

      post "/api/v1/system/node_api/status/heartbeat", params: body, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      instance.reload
      expect(instance.booted_image_git_sha).to eq(booted_sha)
    end

    it "tolerates missing booted_image_git_sha body field" do
      body.delete(:booted_image_git_sha)
      post "/api/v1/system/node_api/status/heartbeat", params: body, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      instance.reload
      expect(instance.booted_image_git_sha).to be_nil
    end

    it "preserves booted_image_git_sha when not provided and boot_id unchanged (agent restart)" do
      instance.update!(booted_image_git_sha: "existing-sha", boot_id: "boot-test-1")
      body.delete(:booted_image_git_sha)

      post "/api/v1/system/node_api/status/heartbeat", params: body, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      instance.reload
      expect(instance.booted_image_git_sha).to eq("existing-sha")
    end

    it "clears booted_image_git_sha when not provided and boot_id changed (new boot into old image)" do
      instance.update!(booted_image_git_sha: "old-sha", boot_id: "boot-old")
      body.delete(:booted_image_git_sha)
      body[:boot_id] = "boot-test-1"

      post "/api/v1/system/node_api/status/heartbeat", params: body, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      instance.reload
      expect(instance.boot_id).to eq("boot-test-1")
      expect(instance.booted_image_git_sha).to be_nil
    end

    it "updates booted_image_git_sha when provided and different" do
      instance.update!(booted_image_git_sha: "old-sha")
      new_sha = "new-sha-xyz"
      body[:booted_image_git_sha] = new_sha

      post "/api/v1/system/node_api/status/heartbeat", params: body, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      instance.reload
      expect(instance.booted_image_git_sha).to eq(new_sha)
    end

    it "persists booted_image_git_sha alongside other heartbeat fields" do
      booted_sha = "test-boot-sha"
      new_digest = { "system-enhanced" => "sha256:bbbb" }
      body[:booted_image_git_sha] = booted_sha
      body[:module_digests] = new_digest
      body[:architecture] = "arm64"

      post "/api/v1/system/node_api/status/heartbeat", params: body, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      instance.reload
      expect(instance.booted_image_git_sha).to eq(booted_sha)
      expect(instance.running_module_digests).to include(new_digest)
      expect(instance.architecture).to eq("arm64")
    end

    describe "boot image upgrade reconciliation (campaign 019f505f inc 2)" do
      it "completes an in-flight upgrade_boot_image task when booted sha matches the target" do
        target_sha = "target-upgrade-abc123"
        user = create(:user, account: account)

        # Create an in-flight upgrade_boot_image task with target sha
        task = System::Task.create!(
          account: account,
          operable: instance,
          command: "upgrade_boot_image",
          status: "pending",
          initiated_by: user,
          options: {
            "target_git_sha" => target_sha,
            "uki_oci_ref" => "ghcr.io/uki:1.0",
            "uki_sha256" => "sha256:uuuu",
            "cosign_identity_regexp" => "https://github.com/test",
            "cosign_issuer_regexp" => "https://token.actions.githubusercontent.com",
            "download_path" => "/api/v1/system/node_api/boot_image/download"
          }
        )

        # Heartbeat reports the target sha as booted
        body[:booted_image_git_sha] = target_sha

        post "/api/v1/system/node_api/status/heartbeat", params: body, headers: headers, as: :json

        expect(response).to have_http_status(:ok)

        # The reconciler should have completed the task
        expect(task.reload.status).to eq("complete")

        # Instance records the heartbeat
        instance.reload
        expect(instance.booted_image_git_sha).to eq(target_sha)
      end

      it "leaves in-flight task alone when booted sha does not match (waiting for reboot)" do
        target_sha = "target-pending-xyz"
        booted_sha = "current-running-sha"
        user = create(:user, account: account)

        task = System::Task.create!(
          account: account,
          operable: instance,
          command: "upgrade_boot_image",
          status: "pending",
          initiated_by: user,
          options: {
            "target_git_sha" => target_sha,
            "uki_oci_ref" => "ghcr.io/uki:1.0",
            "uki_sha256" => "sha256:uuuu"
          }
        )

        # Heartbeat reports current (not yet upgraded) image
        body[:booted_image_git_sha] = booted_sha

        post "/api/v1/system/node_api/status/heartbeat", params: body, headers: headers, as: :json

        expect(response).to have_http_status(:ok)

        # Task should still be in-flight, waiting for node to boot into target image
        expect(task.reload.status).to eq("pending")

        instance.reload
        expect(instance.booted_image_git_sha).to eq(booted_sha)
      end

      it "fails an upgrade_boot_image task if it has timed out and target sha not reached" do
        target_sha = "target-timeout-test"
        booted_sha = "old-image-sha"
        user = create(:user, account: account)

        # Create an old task (older than TIMEOUT_SECONDS = 900s by default)
        task = System::Task.create!(
          account: account,
          operable: instance,
          command: "upgrade_boot_image",
          status: "pending",
          initiated_by: user,
          created_at: 20.minutes.ago,
          options: {
            "target_git_sha" => target_sha,
            "uki_oci_ref" => "ghcr.io/uki:1.0"
          }
        )

        # Heartbeat reports the old image still booted
        body[:booted_image_git_sha] = booted_sha

        post "/api/v1/system/node_api/status/heartbeat", params: body, headers: headers, as: :json

        expect(response).to have_http_status(:ok)

        # Reconciler should fail the timed-out task
        expect(task.reload.status).to eq("failed")
        expect(task.error_message).to include("not confirmed")
        expect(task.error_message).to include("900s")
      end

      it "does not run reconciler when no in-flight upgrade task exists (cheap no-op)" do
        # No upgrade task created

        body[:booted_image_git_sha] = "any-sha"

        post "/api/v1/system/node_api/status/heartbeat", params: body, headers: headers, as: :json

        expect(response).to have_http_status(:ok)

        # Should complete without error
        instance.reload
        expect(instance.booted_image_git_sha).to eq("any-sha")
      end
    end
  end
end
