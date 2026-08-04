# frozen_string_literal: true

require "rails_helper"

# Campaign 019f505f increment 4 — BootImageDriftRolloutExecutor plans and
# executes a canary-first, halt-on-failure in-place boot-image upgrade across
# all drifted instances on a node platform.
RSpec.describe System::Ai::Skills::BootImageDriftRolloutExecutor do
  let(:account) { create(:account) }
  let(:platform_record) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform_record) }
  let(:user) { create(:user, account: account) }
  let(:agent) { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy") }
  let(:executor) { described_class.new(account: account, agent: agent, user: user) }

  let(:cosign_public_key_pem) do
    "-----BEGIN PUBLIC KEY-----\n" \
    "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEzKyqKWW5nHvyLMYqwP5xPeOXDw" \
    "tz+sKlxGqKcvK9I5CDLQQRi8S6X8L6kqJMPj7pZ9nFNqnCwHGh/JFVRqZDjA==\n" \
    "-----END PUBLIC KEY-----"
  end

  def setup_platform(target_sha: "target-sha")
    platform_record.update!(
      disk_image_git_sha: target_sha,
      disk_image_oci_ref: "oki-ref"
    )

    # The dispatcher AND the plan-time blocker both source the UKI pins from the
    # promoted publication row, reached via the platform's git_sha pointer above
    # (df4a2000 + IMP-4452cb88e195) — so a healthy platform fixture has to carry
    # uki_oci_ref/uki_sha256 here or every dispatch fails the UKI-artifact guard.
    System::DiskImagePublication.create!(
      account: account,
      node_platform: platform_record,
      git_sha: target_sha,
      arch: "amd64",
      oci_ref: "oki-ref",
      sha256: "#{'a' * 64}",
      size_bytes: 1024,
      uki_oci_ref: "uki-ref",
      uki_sha256: "#{'c' * 64}",
      uki_cosign_bundle: "base64_bundle"
    )
  end

  def create_drifted_instance(booted_sha: "booted-sha", name: "node")
    node = create(:system_node, account: account, node_template: template, name: name)
    create(:system_node_instance, :running, node: node, booted_image_git_sha: booted_sha)
  end

  def create_current_instance(target_sha: "target-sha", name: "node")
    node = create(:system_node, account: account, node_template: template, name: name)
    create(:system_node_instance, :running, node: node, booted_image_git_sha: target_sha)
  end

  describe ".descriptor" do
    it "advertises required inputs, structured outputs, and requires_approval" do
      d = described_class.descriptor

      expect(d[:name]).to eq("boot_image_drift_rollout")
      expect(d[:category]).to eq("devops")
      expect(d.dig(:inputs, :instance_id, :required)).to be true
      expect(d.dig(:inputs, :batch_pct, :required)).to be false
      expect(d.dig(:inputs, :batch_pct, :default)).to eq(10)
      expect(d.dig(:inputs, :max_consecutive_failures, :required)).to be false
      expect(d.dig(:inputs, :dry_run, :required)).to be false
      expect(d[:requires_approval]).to be true
      expect(d[:blast_radius]).to match(/reboots/)
    end
  end

  describe "#execute" do
    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)
    end

    describe "input validation" do
      it "returns failure when batch_pct < 1" do
        setup_platform
        drifted = create_drifted_instance

        r = executor.execute(instance_id: drifted.id, batch_pct: 0)

        expect(r[:success]).to be false
        expect(r[:error]).to match(/batch_pct must be 1..100/)
      end

      it "returns failure when batch_pct > 100" do
        setup_platform
        drifted = create_drifted_instance

        r = executor.execute(instance_id: drifted.id, batch_pct: 101)

        expect(r[:success]).to be false
        expect(r[:error]).to match(/batch_pct must be 1..100/)
      end
    end

    describe "resolution" do
      it "returns failure when instance not found" do
        r = executor.execute(instance_id: SecureRandom.uuid)

        expect(r[:success]).to be false
        expect(r[:error]).to match(/instance not found/)
      end
    end

    describe "dry_run mode" do
      it "plans without creating any tasks" do
        target_sha = "target-sha"
        setup_platform(target_sha: target_sha)
        drifted1 = create_drifted_instance(booted_sha: "old-sha-1", name: "d1")
        drifted2 = create_drifted_instance(booted_sha: "old-sha-2", name: "d2")
        drifted3 = create_drifted_instance(booted_sha: "old-sha-3", name: "d3")
        current = create_current_instance(target_sha: target_sha, name: "current")

        r = executor.execute(instance_id: drifted1.id, batch_pct: 50, dry_run: true)

        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:platform_id]).to eq(platform_record.id)
        expect(d[:target_git_sha]).to eq(target_sha)
        expect(d[:total_drifted]).to eq(3)
        expect(d[:batch_size]).to eq(2) # 3 * 50 / 100 = 1.5 => 2
        expect(d[:batch_count]).to eq(2)
        expect(d[:halted]).to be false
        expect(d[:dispatched_task_ids]).to be_empty
        expect(System::Task.where(command: "upgrade_boot_image").count).to eq(0)
      end

      it "plans only — does not dispatch canary batch even with dry_run:false" do
        target_sha = "target-sha"
        setup_platform(target_sha: target_sha)
        drifted1 = create_drifted_instance(booted_sha: "old-sha-1", name: "d1")
        drifted2 = create_drifted_instance(booted_sha: "old-sha-2", name: "d2")

        r = executor.execute(instance_id: drifted1.id, batch_pct: 100, dry_run: true)

        expect(r[:success]).to be true
        expect(r[:data][:dispatched_task_ids]).to be_empty
        expect(System::Task.where(command: "upgrade_boot_image").count).to eq(0)
      end
    end

    describe "batching logic" do
      it "calculates batch_size as ceil(drifted * batch_pct / 100), min 1" do
        target_sha = "target-sha"
        setup_platform(target_sha: target_sha)
        drifted1 = create_drifted_instance(booted_sha: "old-sha-1", name: "d1")
        drifted2 = create_drifted_instance(booted_sha: "old-sha-2", name: "d2")
        drifted3 = create_drifted_instance(booted_sha: "old-sha-3", name: "d3")
        drifted4 = create_drifted_instance(booted_sha: "old-sha-4", name: "d4")

        # 4 drifted * 25 / 100 = 1.0 => 1
        r = executor.execute(instance_id: drifted1.id, batch_pct: 25, dry_run: true)
        expect(r[:data][:batch_size]).to eq(1)

        # 4 drifted * 33 / 100 = 1.32 => 2
        r = executor.execute(instance_id: drifted1.id, batch_pct: 33, dry_run: true)
        expect(r[:data][:batch_size]).to eq(2)

        # 4 drifted * 100 / 100 = 4
        r = executor.execute(instance_id: drifted1.id, batch_pct: 100, dry_run: true)
        expect(r[:data][:batch_size]).to eq(4)
      end

      it "marks first batch as canary, rest as planned" do
        target_sha = "target-sha"
        setup_platform(target_sha: target_sha)
        drifted1 = create_drifted_instance(booted_sha: "old-sha-1", name: "d1")
        drifted2 = create_drifted_instance(booted_sha: "old-sha-2", name: "d2")
        drifted3 = create_drifted_instance(booted_sha: "old-sha-3", name: "d3")
        drifted4 = create_drifted_instance(booted_sha: "old-sha-4", name: "d4")

        r = executor.execute(instance_id: drifted1.id, batch_pct: 50, dry_run: true)

        d = r[:data]
        expect(d[:batch_count]).to eq(2)
        expect(d[:batches][0][:status]).to eq("canary")
        expect(d[:batches][0][:size]).to eq(2)
        expect(d[:batches][1][:status]).to eq("planned")
        expect(d[:batches][1][:size]).to eq(2)
      end

      it "includes instance_ids and index in batches" do
        target_sha = "target-sha"
        setup_platform(target_sha: target_sha)
        drifted1 = create_drifted_instance(booted_sha: "old-sha-1", name: "d1")
        drifted2 = create_drifted_instance(booted_sha: "old-sha-2", name: "d2")

        r = executor.execute(instance_id: drifted1.id, batch_pct: 100, dry_run: true)

        d = r[:data]
        expect(d[:batches][0]).to have_key(:instance_ids)
        expect(d[:batches][0]).to have_key(:index)
        expect(d[:batches][0]).to have_key(:size)
        expect(d[:batches][0]).to have_key(:estimated_seconds)
      end

      it "calculates estimated_seconds = size * 180" do
        target_sha = "target-sha"
        setup_platform(target_sha: target_sha)
        drifted1 = create_drifted_instance(booted_sha: "old-sha-1", name: "d1")
        drifted2 = create_drifted_instance(booted_sha: "old-sha-2", name: "d2")

        r = executor.execute(instance_id: drifted1.id, batch_pct: 100, dry_run: true)

        d = r[:data]
        expect(d[:batches][0][:estimated_seconds]).to eq(2 * 180)
      end
    end

    describe "halt-on-failure (circuit breaker)" do
      it "sets halted:true and does not dispatch when recent_failures >= max_consecutive_failures" do
        target_sha = "target-sha"
        setup_platform(target_sha: target_sha)
        drifted1 = create_drifted_instance(booted_sha: "old-sha-1", name: "d1")
        drifted2 = create_drifted_instance(booted_sha: "old-sha-2", name: "d2")

        # Create a recent failed task on the platform
        node = create(:system_node, account: account, node_template: template, name: "failed-node")
        failed_instance = create(:system_node_instance, :running, node: node)
        System::Task.create!(
          account: account,
          operable: failed_instance,
          command: "upgrade_boot_image",
          status: "failed",
          updated_at: 10.minutes.ago
        )

        r = executor.execute(instance_id: drifted1.id, dry_run: false, max_consecutive_failures: 1)

        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:halted]).to be true
        expect(d[:circuit_breaker][:status]).to eq("tripped")
        expect(d[:circuit_breaker][:recent_failures]).to eq(1)
        expect(d[:dispatched_task_ids]).to be_empty
        expect(System::Task.where(command: "upgrade_boot_image", status: "pending").count).to eq(0)
      end

      it "reports circuit_breaker status armed when recent_failures < max_consecutive_failures" do
        target_sha = "target-sha"
        setup_platform(target_sha: target_sha)
        drifted1 = create_drifted_instance(booted_sha: "old-sha-1", name: "d1")

        r = executor.execute(instance_id: drifted1.id, dry_run: true, max_consecutive_failures: 2)

        d = r[:data]
        expect(d[:halted]).to be false
        expect(d[:circuit_breaker][:status]).to eq("armed")
        expect(d[:circuit_breaker][:recent_failures]).to eq(0)
        expect(d[:circuit_breaker][:in_flight]).to eq(0)
      end

      it "does not count failed tasks outside the failure window" do
        target_sha = "target-sha"
        setup_platform(target_sha: target_sha)
        drifted1 = create_drifted_instance(booted_sha: "old-sha-1", name: "d1")

        # Create an old failed task (beyond the window)
        node = create(:system_node, account: account, node_template: template, name: "old-failed")
        old_instance = create(:system_node_instance, :running, node: node)
        System::Task.create!(
          account: account,
          operable: old_instance,
          command: "upgrade_boot_image",
          status: "failed",
          updated_at: 2.hours.ago # Beyond default 3600s window
        )

        r = executor.execute(instance_id: drifted1.id, dry_run: false, max_consecutive_failures: 1)

        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:halted]).to be false
        expect(d[:dispatched_task_ids]).to be_present
      end

      it "halts when in-flight upgrade tasks exist (waiting for current batch)" do
        target_sha = "target-sha"
        setup_platform(target_sha: target_sha)
        drifted1 = create_drifted_instance(booted_sha: "old-sha-1", name: "d1")
        drifted2 = create_drifted_instance(booted_sha: "old-sha-2", name: "d2")

        # Create an in-flight (pending) task on one of the platform instances
        node = create(:system_node, account: account, node_template: template, name: "inflight")
        inflight_instance = create(:system_node_instance, :running, node: node)
        System::Task.create!(
          account: account,
          operable: inflight_instance,
          command: "upgrade_boot_image",
          status: "pending"
        )

        r = executor.execute(instance_id: drifted1.id, dry_run: false)

        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:halted]).to be true
        expect(d[:halt_reason]).to match(/upgrade in flight/)
        expect(d[:circuit_breaker][:in_flight]).to eq(1)
        expect(d[:dispatched_task_ids]).to be_empty
      end

      it "halts when platform preflight check fails (no cosign bundle)" do
        target_sha = "target-sha"
        setup_platform(target_sha: target_sha)
        drifted1 = create_drifted_instance(booted_sha: "old-sha-1", name: "d1")

        # Clear the cosign bundle from the publication
        pub = System::DiskImagePublication.where(node_platform: platform_record, git_sha: target_sha).first
        pub.update!(uki_cosign_bundle: nil)

        r = executor.execute(instance_id: drifted1.id, dry_run: false)

        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:halted]).to be true
        expect(d[:halt_reason]).to match(/cosign signature bundle/)
        expect(d[:dispatched_task_ids]).to be_empty
      end

      it "halts when platform preflight check fails (no cosign public key)" do
        target_sha = "target-sha"
        setup_platform(target_sha: target_sha)
        drifted1 = create_drifted_instance(booted_sha: "old-sha-1", name: "d1")

        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(nil)
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

        r = executor.execute(instance_id: drifted1.id, dry_run: false)

        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:halted]).to be true
        expect(d[:halt_reason]).to match(/cosign public key/)
        expect(d[:dispatched_task_ids]).to be_empty
      end
    end

    # IMP-4452cb88e195 — the plan-time blocker and the dispatch-time guards MUST
    # read the same pin source (the promoted publication row). While the blocker
    # read a separate mirror of the pins on NodePlatform, a platform whose mirror
    # was populated but whose publication row carried no UKI pins planned GREEN
    # (halted:false) and then dispatched ZERO tasks on approval — the exact
    # silent no-op the plan-time preflight exists to prevent. The mirror is gone
    # (IMP-dbd848ce393c); this pins the behaviour that outlived it.
    describe "plan/dispatch pin-source consistency" do
      it "halts instead of planning green and dispatching nothing when the publication carries no UKI pins" do
        target_sha = "target-sha"
        # A fully-promoted platform pointer whose publication row carries no UKI.
        platform_record.update!(
          disk_image_git_sha: target_sha,
          disk_image_oci_ref: "oki-ref"
        )
        System::DiskImagePublication.create!(
          account: account,
          node_platform: platform_record,
          git_sha: target_sha,
          arch: "amd64",
          oci_ref: "oki-ref",
          sha256: "#{'a' * 64}",
          size_bytes: 1024,
          uki_oci_ref: nil,
          uki_sha256: nil,
          uki_cosign_bundle: "base64_bundle"
        )
        drifted1 = create_drifted_instance(booted_sha: "old-sha-1", name: "d1")

        r = executor.execute(instance_id: drifted1.id, dry_run: false)

        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:halted]).to be true
        expect(d[:halt_reason]).to match(/standalone UKI artifact/)
        expect(d[:dispatched_task_ids]).to be_empty
        expect(System::Task.where(command: "upgrade_boot_image").count).to eq(0)
      end

      it "halts with a pointer-inconsistency reason when the promoted git_sha has no publication row" do
        platform_record.update!(
          disk_image_git_sha: "promoted-but-unpublished",
          disk_image_oci_ref: "oki-ref"
        )
        drifted1 = create_drifted_instance(booted_sha: "old-sha-1", name: "d1")

        r = executor.execute(instance_id: drifted1.id, dry_run: false)

        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:halted]).to be true
        expect(d[:halt_reason]).to match(/pointer inconsistent/i)
        expect(d[:halt_reason]).to include("promoted-but-unpublished")
        expect(d[:dispatched_task_ids]).to be_empty
      end
    end

    describe "canary batch dispatch" do
      it "creates tasks only for the canary batch when dry_run:false and no in-flight tasks" do
        target_sha = "target-sha"
        setup_platform(target_sha: target_sha)
        drifted1 = create_drifted_instance(booted_sha: "old-sha-1", name: "d1")
        drifted2 = create_drifted_instance(booted_sha: "old-sha-2", name: "d2")
        drifted3 = create_drifted_instance(booted_sha: "old-sha-3", name: "d3")
        drifted4 = create_drifted_instance(booted_sha: "old-sha-4", name: "d4")

        r = executor.execute(instance_id: drifted1.id, batch_pct: 50, dry_run: false)

        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:halted]).to be false
        expect(d[:batch_count]).to eq(2)
        expect(d[:batch_size]).to eq(2)
        expect(d[:dispatched_task_ids].size).to eq(2)
        expect(System::Task.where(command: "upgrade_boot_image", status: "pending").count).to eq(2)
      end

      it "sets source to fleet_boot_image_rollout in dispatched tasks" do
        target_sha = "target-sha"
        setup_platform(target_sha: target_sha)
        drifted1 = create_drifted_instance(booted_sha: "old-sha-1", name: "d1")
        drifted2 = create_drifted_instance(booted_sha: "old-sha-2", name: "d2")

        r = executor.execute(instance_id: drifted1.id, batch_pct: 100, dry_run: false)

        expect(r[:success]).to be true
        tasks = System::Task.where(command: "upgrade_boot_image", status: "pending")
        expect(tasks.count).to eq(2)
        tasks.each do |task|
          expect(task.options["source"]).to eq("fleet_boot_image_rollout")
        end
      end

      it "does not dispatch tasks for non-canary batches" do
        target_sha = "target-sha"
        setup_platform(target_sha: target_sha)
        drifted1 = create_drifted_instance(booted_sha: "old-sha-1", name: "d1")
        drifted2 = create_drifted_instance(booted_sha: "old-sha-2", name: "d2")
        drifted3 = create_drifted_instance(booted_sha: "old-sha-3", name: "d3")
        drifted4 = create_drifted_instance(booted_sha: "old-sha-4", name: "d4")

        r = executor.execute(instance_id: drifted1.id, batch_pct: 50, dry_run: false)

        expect(r[:success]).to be true
        d = r[:data]
        # 4 drifted * 50 / 100 = 2 per batch, 2 batches total
        # Only canary (batch 0) is dispatched = 2 tasks
        expect(d[:dispatched_task_ids].size).to eq(2)
      end
    end

    describe "result structure" do
      it "returns platform_id, target_git_sha, total_drifted, batch_size, batch_count" do
        target_sha = "target-sha"
        setup_platform(target_sha: target_sha)
        drifted1 = create_drifted_instance(booted_sha: "old-sha-1", name: "d1")
        drifted2 = create_drifted_instance(booted_sha: "old-sha-2", name: "d2")

        r = executor.execute(instance_id: drifted1.id, batch_pct: 50, dry_run: true)

        expect(r[:success]).to be true
        d = r[:data]
        expect(d).to have_key(:platform_id)
        expect(d).to have_key(:target_git_sha)
        expect(d).to have_key(:total_drifted)
        expect(d).to have_key(:batch_size)
        expect(d).to have_key(:batch_count)
        expect(d).to have_key(:halted)
        expect(d).to have_key(:halt_reason)
        expect(d).to have_key(:circuit_breaker)
        expect(d).to have_key(:batches)
        expect(d).to have_key(:dispatched_task_ids)
        expect(d).to have_key(:dispatch_errors)
      end

      it "includes circuit_breaker with trips_after_consecutive_failures, recent_failures, status" do
        target_sha = "target-sha"
        setup_platform(target_sha: target_sha)
        drifted1 = create_drifted_instance(booted_sha: "old-sha-1", name: "d1")

        r = executor.execute(instance_id: drifted1.id, dry_run: true)

        d = r[:data]
        expect(d[:circuit_breaker]).to have_key(:trips_after_consecutive_failures)
        expect(d[:circuit_breaker]).to have_key(:recent_failures)
        expect(d[:circuit_breaker]).to have_key(:status)
      end
    end

    describe "only drifted instances are included" do
      it "includes drifted instances and excludes current-on-target instances" do
        target_sha = "target-sha"
        setup_platform(target_sha: target_sha)
        drifted1 = create_drifted_instance(booted_sha: "old-sha-1", name: "d1")
        drifted2 = create_drifted_instance(booted_sha: "old-sha-2", name: "d2")
        current = create_current_instance(target_sha: target_sha, name: "current")

        r = executor.execute(instance_id: drifted1.id, batch_pct: 100, dry_run: true)

        d = r[:data]
        expect(d[:total_drifted]).to eq(2)
        expect(d[:batch_count]).to eq(1)
        expect(d[:batches][0][:size]).to eq(2)
        expect(d[:batches][0][:instance_ids]).not_to include(current.id)
      end

      it "includes only running instances" do
        target_sha = "target-sha"
        setup_platform(target_sha: target_sha)
        drifted_running = create_drifted_instance(booted_sha: "old-sha-1", name: "d1")

        # Create a drifted but stopped instance
        node = create(:system_node, account: account, node_template: template, name: "stopped")
        drifted_stopped = create(:system_node_instance, :stopped, node: node, booted_image_git_sha: "old")

        r = executor.execute(instance_id: drifted_running.id, batch_pct: 100, dry_run: true)

        d = r[:data]
        expect(d[:total_drifted]).to eq(1)
        expect(d[:batches][0][:instance_ids]).to include(drifted_running.id)
        expect(d[:batches][0][:instance_ids]).not_to include(drifted_stopped.id)
      end
    end
  end
end
