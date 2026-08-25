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

  # Root cause B fix — System::NodeInstance#mark_pool_ready! previously had
  # ZERO callers, so nothing ever promoted a pool-provisioned instance out
  # of pool_state="warming", regardless of how healthy it was. A successful
  # heartbeat is the platform's evidence that the on-node agent enrolled and
  # is alive, so it's the trigger point (NodeInstance#promote_pool_ready!,
  # called unconditionally from this endpoint).
  describe "pool warming -> ready promotion (heartbeat-driven)" do
    let(:provider_region)       { create(:system_provider_region) }
    let(:provider_instance_type) { create(:system_provider_instance_type) }
    let(:pool) do
      System::InstancePool.create!(
        account: account,
        node_template: node_template,
        name: "heartbeat-promo-pool",
        target_size: 1,
        min_size: 1,
        max_size: 3,
        lifecycle_class: "ephemeral",
        status: "active",
        provider_region: provider_region,
        provider_instance_type: provider_instance_type
      )
    end

    context "when the instance is a pooled 'warming' member" do
      let(:instance) do
        create(:system_node_instance, node: node, status: "pending",
                                       instance_pool_id: pool.id, pool_state: "warming",
                                       pool_warming_started_at: 1.minute.ago)
      end

      it "promotes pool_state warming -> ready on a successful heartbeat" do
        post "/api/v1/system/node_api/status/heartbeat", params: body, headers: headers, as: :json

        expect(response).to have_http_status(:ok)
        expect(instance.reload.pool_state).to eq("ready")
      end

      it "emits a system.pool.member_ready FleetEvent scoped to the instance" do
        expect {
          post "/api/v1/system/node_api/status/heartbeat", params: body, headers: headers, as: :json
        }.to change {
          System::FleetEvent.where(kind: "system.pool.member_ready", node_instance_id: instance.id).count
        }.by(1)
      end

      it "is idempotent — a second heartbeat does not re-promote or double-emit" do
        post "/api/v1/system/node_api/status/heartbeat", params: body, headers: headers, as: :json
        post "/api/v1/system/node_api/status/heartbeat", params: body, headers: headers, as: :json

        expect(instance.reload.pool_state).to eq("ready")
        expect(
          System::FleetEvent.where(kind: "system.pool.member_ready", node_instance_id: instance.id).count
        ).to eq(1)
      end
    end

    context "when the instance is a pooled member already 'ready' (no-op guard)" do
      let(:instance) do
        create(:system_node_instance, node: node, status: "running",
                                       instance_pool_id: pool.id, pool_state: "ready",
                                       pool_warming_started_at: 10.minutes.ago)
      end

      it "leaves pool_state unchanged and emits no promotion event" do
        expect {
          post "/api/v1/system/node_api/status/heartbeat", params: body, headers: headers, as: :json
        }.not_to change {
          System::FleetEvent.where(kind: "system.pool.member_ready", node_instance_id: instance.id).count
        }

        expect(response).to have_http_status(:ok)
        expect(instance.reload.pool_state).to eq("ready")
      end
    end

    context "when the instance is NOT in a pool (operator-owned, legacy path)" do
      it "is a no-op — no pool_state change, no FleetEvent" do
        expect(instance.instance_pool_id).to be_nil

        expect {
          post "/api/v1/system/node_api/status/heartbeat", params: body, headers: headers, as: :json
        }.not_to change { System::FleetEvent.where(kind: "system.pool.member_ready").count }

        expect(response).to have_http_status(:ok)
        expect(instance.reload.pool_state).to be_nil
      end
    end

    # `restart_after_update` fires HERE, not at promotion: the heartbeat is the
    # exact moment the platform learns what the instance has materialized.
    context "restart_after_update" do
      let(:platform_rec) { create(:system_node_platform, account: account) }
      let(:category)     { create(:system_node_module_category, account: account) }
      let(:extension) do
        create(:system_node_module, account: account, node_platform: platform_rec,
               category: category, name: "powernode-extension-system")
      end
      let(:backend) do
        create(:system_node_module, account: account, node_platform: platform_rec,
               category: category, name: "powernode-hub-backend")
      end
      let(:digest) { "sha256:#{'d' * 64}" }

      before do
        node.node_modules << extension
        node.node_modules << backend
        extension.update!(config: extension.config.merge(
          "restart_after_update" => [ { "module" => "powernode-hub-backend", "services" => [ "rails" ] } ]
        ))
        version = System::NodeModuleVersion.create!(
          node_module: extension, version_number: 1,
          mask: [], file_spec: [], package_spec: [], config: {}, oci_digest: digest
        )
        extension.update!(current_version: version, current_version_number: 1)
        System::RestartAfterUpdate.arm!(node_module: extension, version: version)
      end

      it "enqueues the computed unit restart when the heartbeat reports the promoted digest" do
        body[:module_digests] = { extension.id => digest }

        expect {
          post "/api/v1/system/node_api/status/heartbeat", params: body, headers: headers, as: :json
        }.to change { instance.tasks.where(command: "restart").count }.by(1)

        expect(response).to have_http_status(:ok)
        expect(instance.tasks.where(command: "restart").last.options["unit"])
          .to eq("powernode-#{backend.id}-rails.service")
      end

      it "enqueues nothing while the heartbeat still reports the old digest" do
        body[:module_digests] = { extension.id => "sha256:#{'e' * 64}" }

        expect {
          post "/api/v1/system/node_api/status/heartbeat", params: body, headers: headers, as: :json
        }.not_to change { instance.tasks.where(command: "restart").count }
      end
    end
  end

  # The agent's poll loop does not filter by status and re-executes anything
  # this endpoint returns. A unit restart whose completion report was lost —
  # which is exactly what happens when the restarted unit IS the platform —
  # must not be handed back, or it restarts every ~30s forever.
  describe "GET /api/v1/system/node_api/status/tasks" do
    let(:unit) { "powernode-#{SecureRandom.uuid}-rails.service" }

    def offered_ids
      get "/api/v1/system/node_api/status/tasks", headers: headers, as: :json
      JSON.parse(response.body).dig("data", "tasks").map { |t| t["id"] }
    end

    let(:provenance) { { "scope" => "unit", "unit" => unit, "restart_after_update" => { "triggers" => [] } } }

    it "offers a unit restart that has not been picked up yet" do
      task = System::Task.create!(account: account, operable: instance, command: "restart",
                                  status: "pending", options: provenance)

      expect(offered_ids).to include(task.id)
    end

    it "withholds a unit restart that is already in flight" do
      task = System::Task.create!(account: account, operable: instance, command: "restart",
                                  status: "pending", options: provenance)
      task.update_columns(status: "running")

      expect(offered_ids).not_to include(task.id)
    end

    # An in-flight unit restart the feature did not create is never settled by
    # it, so withholding it would strand the task `running` forever.
    it "still offers an in-flight unit restart it does not own" do
      task = System::Task.create!(account: account, operable: instance, command: "restart",
                                  status: "pending", options: { "scope" => "unit", "unit" => unit })
      task.update_columns(status: "running")

      expect(offered_ids).to include(task.id)
    end

    it "still offers an in-flight task that is not a unit restart" do
      task = System::Task.create!(account: account, operable: instance, command: "sync_modules",
                                  status: "pending")
      task.update_columns(status: "running")

      expect(offered_ids).to include(task.id)
    end
  end
end
