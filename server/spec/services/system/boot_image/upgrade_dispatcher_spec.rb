# frozen_string_literal: true

require "rails_helper"

# Campaign 019f505f increment 4 — UpgradeDispatcher guards all dispatch paths
# (operator MCP tool + fleet drift rollout executor) via fail-closed security
# chain (guards: platform / promoted image / standalone UKI / cosign pubkey /
# UKI cosign bundle). Returns a Result struct (upgraded/task/reason/already_current/
# deduplicated/target_git_sha, with #ok? == reason.nil?).
RSpec.describe System::BootImage::UpgradeDispatcher do
  let(:account) { create(:account) }
  let(:platform_record) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform_record) }
  let(:node) { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }
  let(:user) { create(:user, account: account) }
  let(:cosign_public_key_pem) do
    "-----BEGIN PUBLIC KEY-----\n" \
    "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEzKyqKWW5nHvyLMYqwP5xPeOXDw" \
    "tz+sKlxGqKcvK9I5CDLQQRi8S6X8L6kqJMPj7pZ9nFNqnCwHGh/JFVRqZDjA==\n" \
    "-----END PUBLIC KEY-----"
  end

  # The platform carries only the boot POINTER (which git_sha is promoted). It
  # has no UKI fields to set — those live solely on the publication row
  # (IMP-dbd848ce393c).
  def setup_platform(target_sha: "target-sha", oki_ref: "oki-ref")
    platform_record.update!(
      disk_image_git_sha: target_sha,
      disk_image_oci_ref: oki_ref
    )
  end

  # The dispatcher sources the UKI pins from the PUBLICATION ROW, reached via
  # the platform's promoted git_sha (df4a2000). The publication is therefore the
  # only place uki_oci_ref/uki_sha256 can be set for these examples.
  def setup_publication(target_sha: "target-sha", oki_ref: "oki-ref", bundle: "base64_bundle",
                        uki_ref: "uki-ref", uki_sha256: "c" * 64)
    System::DiskImagePublication.create!(
      account: account,
      node_platform: platform_record,
      git_sha: target_sha,
      arch: "amd64",
      oci_ref: oki_ref,
      sha256: "#{'a' * 64}",
      size_bytes: 1024,
      uki_oci_ref: uki_ref,
      uki_sha256: uki_sha256,
      uki_cosign_bundle: bundle
    )
  end

  describe ".dispatch!" do
    describe "fail-closed guards" do
      it "returns err when instance has no resolvable platform" do
        # Create a mock instance with node returning nil for node_platform
        mock_instance = instance_double("System::NodeInstance", node: nil, booted_image_git_sha: nil)
        mock_instance.extend(Module.new { define_method(:id) { "test-id" } })

        result = described_class.dispatch!(instance: mock_instance, source: "test")

        expect(result.ok?).to be false
        expect(result.reason).to match(/no resolvable node platform/)
        expect(result.upgraded).to be false
        expect(result.task).to be_nil
      end

      it "returns err when platform has no promoted disk_image_git_sha" do
        platform_record.update!(disk_image_git_sha: nil, disk_image_oci_ref: "ref")

        result = described_class.dispatch!(instance: instance, source: "test")

        expect(result.ok?).to be false
        expect(result.reason).to match(/no promoted disk image/)
        expect(result.upgraded).to be false
      end

      it "returns err when platform has no promoted disk_image_oci_ref" do
        platform_record.update!(disk_image_git_sha: "sha-abc", disk_image_oci_ref: nil)

        result = described_class.dispatch!(instance: instance, source: "test")

        expect(result.ok?).to be false
        expect(result.reason).to match(/no promoted disk image/)
      end

      it "returns err when the promoted PUBLICATION has no standalone UKI artifact" do
        # Blank on the publication — the only place the pins live — so the guard
        # must fire. The invariant df4a2000 added: the dispatcher reads the
        # publication row, never a copy on the platform.
        setup_platform
        setup_publication(uki_ref: nil, uki_sha256: nil)

        result = described_class.dispatch!(instance: instance, source: "test")

        expect(result.ok?).to be false
        expect(result.reason).to match(/no standalone UKI artifact/)
        expect(result.reason).to match(/republish/)
      end

      it "raises on an unhandled preflight failure rather than returning an ok? result with no task" do
        # A 7th guard symbol wired into .preflight but not into
        # dispatch_failure_message would otherwise produce err(nil) — and
        # Result#ok? is `reason.nil?`, so that reads as SUCCESS to every caller
        # (system_fleet_tool then calls .id on a nil task). Fail loud instead.
        allow(described_class).to receive(:preflight).and_return([ nil, :some_future_guard ])

        expect { described_class.dispatch!(instance: instance, source: "test") }
          .to raise_error(ArgumentError, /unhandled preflight failure/)
      end

      it "returns err when the promoted publication has a UKI ref but no uki_sha256" do
        # BOTH halves of the pin are required: the node content-addresses the
        # blob by digest, so a ref without a digest is not dispatchable. No
        # other fixture builds this shape, which left the sha half of the guard
        # unpinned (IMP-4452cb88e195).
        setup_platform
        setup_publication(uki_sha256: nil)

        result = described_class.dispatch!(instance: instance, source: "test")

        expect(result.ok?).to be false
        expect(result.reason).to match(/no standalone UKI artifact/)
        expect(result.task).to be_nil
      end

      it "returns err when the platform pointer names a git_sha with no published record" do
        # Pointer-consistency guard: disk_image_git_sha advanced but no matching
        # publication row exists, so the (uki, bundle) pair cannot be resolved
        # self-consistently. Dispatching anyway would smear mismatched pins into
        # the task and fail cosign verification on-node.
        setup_platform(target_sha: "promoted-but-unpublished")

        result = described_class.dispatch!(instance: instance, source: "test")

        expect(result.ok?).to be false
        expect(result.reason).to match(/pointer inconsistent/i)
        expect(result.reason).to include("promoted-but-unpublished")
        expect(result.task).to be_nil
      end

      it "returns err when ENV POWERNODE_COSIGN_PUBLIC_KEY is unset" do
        setup_platform
        setup_publication

        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(nil)
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

        result = described_class.dispatch!(instance: instance, source: "test")

        expect(result.ok?).to be false
        expect(result.reason).to match(/cosign public key/)
        expect(result.reason).to match(/not configured/)
      end

      it "returns err when promoted publication has no uki_cosign_bundle" do
        target_sha = "target-sha"
        setup_platform(target_sha: target_sha)
        # UKI pins present so the artifact guard passes and we reach the bundle
        # guard — the point of this example.
        System::DiskImagePublication.create!(
          account: account,
          node_platform: platform_record,
          git_sha: target_sha,
          arch: "amd64",
          oci_ref: "test-oci-ref",
          sha256: "#{'b' * 64}",
          size_bytes: 1024,
          uki_oci_ref: "uki-ref",
          uki_sha256: "d" * 64,
          uki_cosign_bundle: nil
        )

        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

        result = described_class.dispatch!(instance: instance, source: "test")

        expect(result.ok?).to be false
        expect(result.reason).to match(/no UKI cosign signature bundle/)
      end
    end

    describe "already_current guard" do
      it "returns already_current:true when booted sha equals target sha and !force" do
        matching_sha = "shared-sha-abc123"
        setup_platform(target_sha: matching_sha)
        setup_publication(target_sha: matching_sha)
        instance.update!(booted_image_git_sha: matching_sha)

        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

        result = described_class.dispatch!(instance: instance, source: "test", force: false)

        expect(result.ok?).to be true
        expect(result.upgraded).to be false
        expect(result.already_current).to be true
        expect(result.reason).to be_nil
        expect(result.task).to be_nil
        expect(result.target_git_sha).to eq(matching_sha)
        expect(System::Task.where(operable: instance, command: "upgrade_boot_image").count).to eq(0)
      end

      it "creates a task when already_current but force:true" do
        matching_sha = "shared-sha-abc123"
        setup_platform(target_sha: matching_sha)
        setup_publication(target_sha: matching_sha)
        instance.update!(booted_image_git_sha: matching_sha)

        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

        result = described_class.dispatch!(instance: instance, source: "test", force: true)

        expect(result.ok?).to be true
        expect(result.upgraded).to be true
        expect(result.task).to be_present
        expect(result.target_git_sha).to eq(matching_sha)
        expect(System::Task.where(operable: instance, command: "upgrade_boot_image").count).to eq(1)
      end
    end

    describe "deduplication guard" do
      it "returns deduplicated:true when an in-flight pending task exists and !force" do
        target_sha = "target-sha"
        setup_platform(target_sha: target_sha)
        setup_publication(target_sha: target_sha)

        existing_task = System::Task.create!(
          account: account,
          operable: instance,
          command: "upgrade_boot_image",
          status: "pending",
          initiated_by: user
        )

        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

        result = described_class.dispatch!(instance: instance, source: "test", force: false)

        expect(result.ok?).to be true
        expect(result.upgraded).to be false
        expect(result.deduplicated).to be true
        expect(result.task).to eq(existing_task)
        expect(result.target_git_sha).to eq(target_sha)
        expect(System::Task.where(operable: instance, command: "upgrade_boot_image").count).to eq(1)
      end

      it "returns deduplicated:true when an in-flight scheduled task exists" do
        target_sha = "target-sha"
        setup_platform(target_sha: target_sha)
        setup_publication(target_sha: target_sha)

        existing_task = System::Task.create!(
          account: account,
          operable: instance,
          command: "upgrade_boot_image",
          status: "scheduled",
          initiated_by: user
        )

        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

        result = described_class.dispatch!(instance: instance, source: "test", force: false)

        expect(result.deduplicated).to be true
        expect(result.task).to eq(existing_task)
      end

      it "returns deduplicated:true when an in-flight running task exists" do
        target_sha = "target-sha"
        setup_platform(target_sha: target_sha)
        setup_publication(target_sha: target_sha)

        existing_task = System::Task.create!(
          account: account,
          operable: instance,
          command: "upgrade_boot_image",
          status: "running",
          initiated_by: user
        )

        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

        result = described_class.dispatch!(instance: instance, source: "test", force: false)

        expect(result.deduplicated).to be true
        expect(result.task).to eq(existing_task)
      end

      it "creates a new task when force:true, bypassing dedup" do
        target_sha = "target-sha"
        setup_platform(target_sha: target_sha)
        setup_publication(target_sha: target_sha)

        existing_task = System::Task.create!(
          account: account,
          operable: instance,
          command: "upgrade_boot_image",
          status: "pending",
          initiated_by: user
        )

        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

        result = described_class.dispatch!(instance: instance, source: "test", force: true)

        expect(result.upgraded).to be true
        expect(result.task).to be_present
        expect(result.task.id).not_to eq(existing_task.id)
        expect(System::Task.where(operable: instance, command: "upgrade_boot_image").count).to eq(2)
      end

      it "creates a new task when a completed task exists (dedup only in-flight)" do
        target_sha = "target-sha"
        setup_platform(target_sha: target_sha)
        setup_publication(target_sha: target_sha)

        completed_task = System::Task.create!(
          account: account,
          operable: instance,
          command: "upgrade_boot_image",
          status: "complete",
          initiated_by: user
        )

        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

        result = described_class.dispatch!(instance: instance, source: "test", force: false)

        expect(result.upgraded).to be true
        expect(result.task).to be_present
        expect(result.task.id).not_to eq(completed_task.id)
        expect(System::Task.where(operable: instance, command: "upgrade_boot_image").count).to eq(2)
      end
    end

    describe "happy path" do
      it "creates a pending upgrade_boot_image task with all options populated" do
        target_sha = "target-sha-xyz"
        oki_ref = "ghcr.io/nodealchemy/system/boot:0.1.0"
        uki_ref = "ghcr.io/nodealchemy/system/boot-uki:0.1.0"
        uki_sha256 = "e" * 64
        cosign_bundle_b64 = "LS0tLS1CRUdJTiBQR1AgU0lHTkVEIE1FU1NBR0UtLS0tLQo="

        # The dispatch must carry the publication row's pins. uki_ref/uki_sha256
        # below are distinct from every other value in play, so a regression that
        # sourced them from anywhere else fails loudly instead of passing on
        # values that happen to agree.
        setup_platform(target_sha: target_sha, oki_ref: oki_ref)
        setup_publication(target_sha: target_sha, oki_ref: oki_ref, bundle: cosign_bundle_b64,
                          uki_ref: uki_ref, uki_sha256: uki_sha256)

        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

        result = described_class.dispatch!(instance: instance, source: "fleet_rollout", initiated_by: user)

        expect(result.ok?).to be true
        expect(result.upgraded).to be true
        expect(result.task).to be_present
        expect(result.target_git_sha).to eq(target_sha)

        task = result.task
        expect(task).to have_attributes(
          command: "upgrade_boot_image",
          status: "pending",
          operable_type: "System::NodeInstance",
          operable_id: instance.id,
          account_id: account.id,
          initiated_by_id: user.id
        )

        expect(task.options).to include(
          "target_git_sha"       => target_sha,
          "uki_oci_ref"          => uki_ref,
          "uki_sha256"           => uki_sha256,
          "cosign_public_key"    => cosign_public_key_pem,
          "cosign_bundle_b64"    => cosign_bundle_b64,
          "download_path"        => "/api/v1/system/node_api/boot_image/download?digest=#{uki_sha256}",
          "source"               => "fleet_rollout",
          "triggered_by_user_id" => user.id
        )
        expect(task.options["triggered_at"]).to be_present
      end

      # The node GETs download_path verbatim (agent bootupgrade.go download()),
      # so pinning the digest INTO that path is what makes the download endpoint
      # serve the artifact this task was pinned to. Without it a promote landing
      # between dispatch and download moves the platform's boot pointer under the
      # in-flight task and the node aborts on "UKI sha256 mismatch".
      it "pins the download_path to the publication's digest" do
        target_sha = "target-sha-pinned"
        publication_digest = "e" * 64

        setup_platform(target_sha: target_sha)
        setup_publication(target_sha: target_sha, uki_sha256: publication_digest)

        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

        result = described_class.dispatch!(instance: instance, source: "test")

        expect(result.ok?).to be true
        download_path = result.task.options["download_path"]
        expect(download_path).to start_with(described_class::DOWNLOAD_PATH)
        expect(download_path).to eq("#{described_class::DOWNLOAD_PATH}?digest=#{publication_digest}")
        expect(download_path).not_to include("f" * 64)
        # The pinned digest and the digest the node verifies bytes against are
        # the same value — they cannot drift apart.
        expect(download_path).to include(result.task.options["uki_sha256"])
      end

      it "initializes booted_image_git_sha absent from the instance" do
        target_sha = "target-sha"
        setup_platform(target_sha: target_sha)
        setup_publication(target_sha: target_sha)
        instance.update!(booted_image_git_sha: nil)

        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

        result = described_class.dispatch!(instance: instance, source: "test")

        expect(result.ok?).to be true
        expect(result.upgraded).to be true
        expect(result.task).to be_present
      end

      it "ships the cosign key it VALIDATED, not a second read of it" do
        # platform_cosign_public_key is effectful: it can read
        # POWERNODE_COSIGN_PUBLIC_KEY_FILE off disk and rescues StandardError to
        # nil. Validating one read and shipping a different read lets a file
        # rotated/unlinked between the two calls queue a task carrying a nil key
        # — the check and the use must be the same bytes, and one read per
        # dispatch (not two per batched instance).
        setup_platform
        setup_publication
        allow(described_class).to receive(:platform_cosign_public_key)
          .and_return(cosign_public_key_pem, nil)

        result = described_class.dispatch!(instance: instance, source: "test")

        expect(result.ok?).to be true
        expect(result.task.options["cosign_public_key"]).to eq(cosign_public_key_pem)
        expect(described_class).to have_received(:platform_cosign_public_key).once
      end
    end

    describe "#platform_cosign_public_key" do
      it "reads from ENV POWERNODE_COSIGN_PUBLIC_KEY when set" do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

        key = described_class.platform_cosign_public_key

        expect(key).to eq(cosign_public_key_pem)
      end

      it "returns nil when ENV unset and file path missing" do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(nil)
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

        key = described_class.platform_cosign_public_key

        expect(key).to be_nil
      end

      it "returns nil when file path does not exist" do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(nil)
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return("/nonexistent/path")

        key = described_class.platform_cosign_public_key

        expect(key).to be_nil
      end

      it "reads from ENV POWERNODE_COSIGN_PUBLIC_KEY_FILE path when ENV unset" do
        key_content = "file-based-key-content"
        tmpfile = Tempfile.new("cosign_key")
        tmpfile.write(key_content)
        tmpfile.flush

        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(nil)
        allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(tmpfile.path)

        key = described_class.platform_cosign_public_key

        expect(key).to eq(key_content)

        tmpfile.close
        tmpfile.unlink
      end
    end
  end

  describe "Result struct" do
    it "#ok? returns true when reason is nil" do
      result = described_class::Result.new(upgraded: true, task: nil, reason: nil)
      expect(result.ok?).to be true
    end

    it "#ok? returns false when reason is present" do
      result = described_class::Result.new(upgraded: false, reason: "some error")
      expect(result.ok?).to be false
    end
  end

  describe ".platform_blocker" do
    it "returns nil when all preflight checks pass" do
      target_sha = "target-sha"
      setup_platform(target_sha: target_sha)
      setup_publication(target_sha: target_sha)

      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

      blocker = described_class.platform_blocker(platform_record)

      expect(blocker).to be_nil
    end

    it "returns reason when platform is nil" do
      blocker = described_class.platform_blocker(nil)

      expect(blocker).to match(/no resolvable node platform/)
    end

    it "returns reason when disk_image_git_sha is blank" do
      platform_record.update!(disk_image_git_sha: nil, disk_image_oci_ref: "ref")

      blocker = described_class.platform_blocker(platform_record)

      expect(blocker).to match(/no promoted disk image/)
    end

    it "returns reason when disk_image_oki_ref is blank" do
      platform_record.update!(disk_image_git_sha: "sha", disk_image_oci_ref: nil)

      blocker = described_class.platform_blocker(platform_record)

      expect(blocker).to match(/no promoted disk image/)
    end

    it "returns reason when the promoted publication has no standalone UKI artifact" do
      # Blank on the publication, populated on the platform: the blocker reads
      # the same publication row .dispatch! pins from, so leaving the columns set
      # proves it is not falling back to them (IMP-4452cb88e195).
      target_sha = "target-sha"
      setup_platform(target_sha: target_sha)
      setup_publication(target_sha: target_sha, uki_ref: nil, uki_sha256: nil)

      blocker = described_class.platform_blocker(platform_record)

      expect(blocker).to match(/no standalone UKI artifact/)
    end

    it "raises on an unhandled preflight failure rather than planning green" do
      # A 7th guard symbol wired into .preflight but not into this case would
      # otherwise fall through to nil — indistinguishable from "no blocker", so
      # the rollout would plan GREEN and dispatch nothing. That is the exact bug
      # class this whole task exists to close (IMP-4452cb88e195). Fail loud.
      allow(described_class).to receive(:preflight).and_return([ nil, :some_future_guard ])

      expect { described_class.platform_blocker(platform_record) }
        .to raise_error(ArgumentError, /unhandled preflight failure/)
    end

    it "returns reason when the promoted publication has a UKI ref but no uki_sha256" do
      setup_platform
      setup_publication(uki_sha256: nil)

      blocker = described_class.platform_blocker(platform_record)

      expect(blocker).to match(/no standalone UKI artifact/)
    end

    it "returns reason when the platform pointer names a git_sha with no published record" do
      # A plan must halt with the honest pointer-inconsistency reason here. It
      # previously reported a missing cosign bundle — the blocker resolved no
      # publication and blamed the last guard it happened to reach.
      setup_platform(target_sha: "promoted-but-unpublished")

      blocker = described_class.platform_blocker(platform_record)

      expect(blocker).to match(/pointer inconsistent/i)
      expect(blocker).to include("promoted-but-unpublished")
    end

    it "returns reason when cosign public key is unset" do
      setup_platform
      setup_publication

      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(nil)
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

      blocker = described_class.platform_blocker(platform_record)

      expect(blocker).to match(/cosign public key/)
    end

    it "returns reason when uki_cosign_bundle is missing" do
      target_sha = "target-sha"
      setup_platform(target_sha: target_sha)
      # UKI pins present so the artifact guard passes and we reach the bundle
      # guard — the point of this example.
      System::DiskImagePublication.create!(
        account: account,
        node_platform: platform_record,
        git_sha: target_sha,
        arch: "amd64",
        oci_ref: "oki-ref",
        sha256: "#{'c' * 64}",
        size_bytes: 1024,
        uki_oci_ref: "uki-ref",
        uki_sha256: "#{'d' * 64}",
        uki_cosign_bundle: nil
      )

      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)

      blocker = described_class.platform_blocker(platform_record)

      expect(blocker).to match(/cosign signature bundle/)
    end
  end

  # IMP-4452cb88e195 — .platform_blocker (plan time) and #dispatch! (act time)
  # are two views of ONE guard chain. Parallel per-condition examples on each
  # side cannot catch the two drifting apart: that is exactly how the 019f505f
  # pin-source move, which updated only #dispatch!, shipped a blocker that
  # planned GREEN while every dispatch refused. These rows assert the
  # BICONDITIONAL — a nil blocker if and only if the dispatch proceeds — so a
  # future divergence fails here regardless of how either side words its reason,
  # and regardless of whether anyone remembers to add a matching example on the
  # other side.
  describe "blocker/dispatch contract" do
    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)
      # Keep every row on the dispatch path: an already_current short-circuit
      # returns ok? with no task, which would muddy the task-count assertion.
      instance.update!(booted_image_git_sha: nil)
    end

    {
      no_promoted_image: {
        dispatchable: false,
        arrange: lambda {
          platform_record.update!(disk_image_git_sha: nil, disk_image_oci_ref: "ref")
        }
      },
      pointer_inconsistent: {
        dispatchable: false,
        arrange: lambda {
          setup_platform(target_sha: "promoted-but-unpublished")
        }
      },
      no_uki_ref: {
        dispatchable: false,
        arrange: lambda {
          setup_platform
          setup_publication(uki_ref: nil)
        }
      },
      # The half the original blocker chain never checked at all.
      no_uki_sha: {
        dispatchable: false,
        arrange: lambda {
          setup_platform
          setup_publication(uki_sha256: nil)
        }
      },
      no_cosign_key: {
        dispatchable: false,
        arrange: lambda {
          setup_platform
          setup_publication
          allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(nil)
        }
      },
      no_cosign_bundle: {
        dispatchable: false,
        arrange: lambda {
          setup_platform
          setup_publication(bundle: nil)
        }
      },
      healthy: {
        dispatchable: true,
        arrange: lambda {
          setup_platform
          setup_publication
        }
      }
    }.each do |state, row|
      it "agrees on #{state}: the blocker is nil if and only if the dispatch proceeds" do
        instance_exec(&row[:arrange])

        blocked = described_class.platform_blocker(platform_record)
        result  = described_class.dispatch!(instance: instance, source: "contract")

        # The row is arranged as intended...
        expect(result.ok?).to eq(row[:dispatchable])
        # ...and THE CONTRACT: the plan-time verdict equals the act-time verdict.
        expect(blocked.nil?).to eq(result.ok?),
                                -> { "blocker=#{blocked.inspect} dispatch_reason=#{result.reason.inspect}" }
        expect(System::Task.where(operable: instance, command: "upgrade_boot_image").count)
          .to eq(row[:dispatchable] ? 1 : 0)
      end
    end
  end

  # The task carries a (uki_oci_ref, uki_sha256, cosign_bundle) TRIPLE the node
  # treats as ONE unit: it pulls the ref, checks the downloaded bytes against
  # the digest, then cosign-verifies those bytes against the bundle. The three
  # are only meaningful together — a bundle from build A over build B's UKI
  # fails verification on every node it reaches, which is fail-closed but is
  # also a fleet-wide dead rollout. df4a2000 moved the pin source to the
  # promoted publication row to prevent exactly that smear.
  #
  # Every other example in this file arranges a SINGLE publication row, so
  # "the promoted row", "the newest row", "the first row" and "the only row"
  # are the same record and nothing distinguishes them: sourcing the cosign
  # bundle from the platform's newest publication instead of the promoted one
  # passes the whole file. These rows surround the promoted row with DECOYS on
  # every axis a wrong lookup could order by — newer, older, insertion/PK
  # order, and another platform — so the triple is pinned to one specific row
  # rather than to lookups that merely happen to agree when there is nothing
  # to disagree with.
  describe "publication-row pinning" do
    let(:promoted_sha)    { "promoted-sha" }
    let(:promoted_ref)    { "promoted-uki-ref" }
    let(:promoted_digest) { "a" * 64 }
    let(:promoted_bundle) { "PROMOTED-BUNDLE-B64" }

    # The SAME promoted git_sha on a DIFFERENT platform. Legal and routine, not
    # a corner case: the unique index is (node_platform_id, git_sha), and one
    # commit normally publishes to several platforms (amd64 + arm64) — asserted
    # directly in spec/models/system/disk_image_publication_spec.rb. So git_sha
    # alone does NOT identify a row, and dropping the platform scoping from the
    # lookup yields a triple that is internally self-consistent (ref, digest,
    # bundle and download_path all from that one wrong row) and therefore
    # passes cosign verify on-node. Unlike a mismatched-pair smear, nothing
    # downstream catches it — the node installs a wrong-platform UKI.
    let(:other_platform) { create(:system_node_platform, account: account) }

    def publish_cross_platform_decoy
      System::DiskImagePublication.create!(
        account: account, node_platform: other_platform,
        git_sha: promoted_sha, arch: "arm64", oci_ref: "other-platform-oci-ref",
        sha256: "9" * 64, size_bytes: 4096,
        uki_oci_ref: "OTHER-PLATFORM-UKI-REF-MUST-NOT-BE-USED", uki_sha256: "1" * 64,
        uki_cosign_bundle: "OTHER-PLATFORM-BUNDLE-MUST-NOT-BE-USED",
        status: "published", published_at: 3.hours.ago, created_at: 3.hours.ago
      )
    end

    # The build the promote SUPERSEDED — same platform, older than the promoted
    # row, so a recency-ordered lookup taking the oldest row lands here.
    def publish_older_decoy
      System::DiskImagePublication.create!(
        account: account, node_platform: platform_record,
        git_sha: "older-superseded-sha", arch: "amd64", oci_ref: "older-oci-ref",
        sha256: "8" * 64, size_bytes: 1024,
        uki_oci_ref: "OLDER-UKI-REF-MUST-NOT-BE-USED", uki_sha256: "2" * 64,
        uki_cosign_bundle: "OLDER-BUNDLE-MUST-NOT-BE-USED",
        status: "published", published_at: 4.hours.ago, created_at: 4.hours.ago
      )
    end

    # A LATER build for a DIFFERENT git_sha, already published — the reachable
    # shape any time CI publishes ahead of the operator's promote. Published
    # and newest, so a lookup ordered by recency lands here whether or not it
    # also filters on status.
    def publish_newer_decoy
      System::DiskImagePublication.create!(
        account: account, node_platform: platform_record,
        git_sha: "newer-unpromoted-sha", arch: "amd64", oci_ref: "newer-oci-ref",
        sha256: "b" * 64, size_bytes: 2048,
        uki_oci_ref: "NEWER-UKI-REF-MUST-NOT-BE-USED", uki_sha256: "e" * 64,
        uki_cosign_bundle: "NEWER-BUNDLE-MUST-NOT-BE-USED",
        status: "published", published_at: Time.current
      )
    end

    # The promoted row, backdated so it sits BETWEEN the older and newer decoys
    # and is inserted LAST — so it is neither the newest, the oldest, nor the
    # first by insertion/PK order (ids are UUIDv7, which tracks insert time).
    def publish_promoted(bundle: promoted_bundle, uki_ref: promoted_ref, uki_sha256: promoted_digest)
      setup_publication(target_sha: promoted_sha, uki_ref: uki_ref,
                        uki_sha256: uki_sha256, bundle: bundle)
        .tap { |pub| pub.update!(status: "published", published_at: 2.hours.ago, created_at: 2.hours.ago) }
    end

    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY").and_return(cosign_public_key_pem)
      allow(ENV).to receive(:[]).with("POWERNODE_COSIGN_PUBLIC_KEY_FILE").and_return(nil)
      setup_platform(target_sha: promoted_sha)
      # Keep the example on the dispatch path — an already_current short-circuit
      # returns ok? with no task to inspect.
      instance.update!(booted_image_git_sha: nil)

      # Inserted here, BEFORE each example creates the promoted row, so the
      # promoted row is last by insertion order and no lookup can reach it by
      # accident. Order among the decoys is deliberate: the cross-platform one
      # is first overall, so a lookup that drops the platform scoping AND takes
      # the first row finds it.
      @cross_platform_decoy = publish_cross_platform_decoy
      @older_decoy          = publish_older_decoy
      @newer_decoy          = publish_newer_decoy
    end

    it "pins all three UKI options to the promoted row, never to a decoy" do
      promoted = publish_promoted

      result = described_class.dispatch!(instance: instance, source: "test")

      expect(result.ok?).to be true
      opts = result.task.options
      expect(opts).to include(
        "target_git_sha"    => promoted_sha,
        "uki_oci_ref"       => promoted_ref,
        "uki_sha256"        => promoted_digest,
        "cosign_bundle_b64" => promoted_bundle
      )
      expect(opts["download_path"]).to eq("#{described_class::DOWNLOAD_PATH}?digest=#{promoted_digest}")

      [ @cross_platform_decoy, @older_decoy, @newer_decoy ].each do |decoy|
        expect(opts.values).not_to include(decoy.uki_oci_ref)
        expect(opts.values).not_to include(decoy.uki_sha256)
        expect(opts.values).not_to include(decoy.uki_cosign_bundle)
      end

      # Row IDENTITY, not value equality: whichever row the shipped digest
      # belongs to, the ref and the bundle must be THAT row's. Asserted this way
      # so a future re-split of the three lookups fails here no matter which of
      # them drifts, and no matter what the decoy's values happen to be.
      pinned = System::DiskImagePublication.find_by!(uki_sha256: opts["uki_sha256"])
      expect(pinned.id).to eq(promoted.id)
      expect(pinned).to have_attributes(
        git_sha:           opts["target_git_sha"],
        uki_oci_ref:       opts["uki_oci_ref"],
        uki_cosign_bundle: opts["cosign_bundle_b64"]
      )
      # git_sha does not identify a row on its own — the pinned row must also
      # belong to THIS instance's platform. Not redundant with the git_sha
      # assertion above: the cross-platform decoy matches on git_sha too.
      expect(pinned.node_platform_id).to eq(platform_record.id)
    end

    it "refuses when the PROMOTED row has no bundle even though a decoy does" do
      # The fail-closed bundle guard has to be evaluated against the row the
      # pins come from. A guard reading the newest row would pass here and let
      # the dispatch queue a task with a nil cosign_bundle_b64 — an
      # unverifiable boot image, which is the one thing this class exists to
      # make impossible.
      publish_promoted(bundle: nil)

      result = described_class.dispatch!(instance: instance, source: "test")

      expect(result.ok?).to be false
      expect(result.reason).to match(/no UKI cosign signature bundle/)
      expect(result.task).to be_nil
      expect(System::Task.where(operable: instance, command: "upgrade_boot_image").count).to eq(0)
      # Guard and pin read one row, so the plan-time blocker must refuse too.
      expect(described_class.platform_blocker(platform_record)).to match(/cosign signature bundle/)
    end

    it "refuses when the PROMOTED row has no UKI pins even though a decoy does" do
      # Same class as the bundle guard above, one guard earlier. Every other
      # example of :no_uki_artifact arranges a single row, so a guard evaluated
      # against the newest row passes them all — and then the dispatch queues a
      # task with a nil uki_oci_ref/uki_sha256 and a "?digest=" download_path,
      # violating the precondition download_path_for documents. Fail-closed
      # on-node, but it defeats the dispatch-time refusal this guard exists for.
      publish_promoted(uki_sha256: nil)

      result = described_class.dispatch!(instance: instance, source: "test")

      expect(result.ok?).to be false
      expect(result.reason).to match(/no standalone UKI artifact/)
      expect(result.task).to be_nil
      expect(System::Task.where(operable: instance, command: "upgrade_boot_image").count).to eq(0)
      expect(described_class.platform_blocker(platform_record)).to match(/no standalone UKI artifact/)
    end

    # WHY .preflight can resolve the promoted row with a bare
    # find_by(git_sha:), with no status or recency scoping: within ONE platform
    # at most one publication exists per git_sha, so "the row for the promoted
    # sha" is already unambiguous and an unordered find_by cannot return an
    # arbitrary one of several. That is a per-PLATFORM guarantee only, which is
    # exactly why the lookup must stay scoped to the platform association.
    # Asserted at the DATABASE level, not just the model validation — the
    # validation races between processes and is bypassed by the very
    # save!(validate: false) path used here, and it is the unique index that
    # actually makes the pinned triple well-defined. If that index is ever
    # dropped, this fails here rather than turning the boot-image pins into a
    # coin flip in production.
    it "permits one git_sha across platforms but not twice on one platform" do
      publish_promoted

      # The cross-platform row from the before hook shares the promoted git_sha
      # and is perfectly valid — the ambiguity the scoping resolves.
      expect(System::DiskImagePublication.where(git_sha: promoted_sha).count).to eq(2)

      duplicate = System::DiskImagePublication.new(
        account: account, node_platform: platform_record,
        git_sha: promoted_sha, arch: "amd64", oci_ref: "duplicate-oci-ref",
        sha256: "c" * 64, size_bytes: 512,
        uki_oci_ref: "duplicate-uki-ref", uki_sha256: "d" * 64, uki_cosign_bundle: "DUPLICATE-BUNDLE"
      )

      expect(duplicate).not_to be_valid
      # requires_new so the constraint violation rolls back to a SAVEPOINT and
      # leaves the surrounding test transaction usable.
      expect {
        System::DiskImagePublication.transaction(requires_new: true) { duplicate.save!(validate: false) }
      }.to raise_error(ActiveRecord::RecordNotUnique)

      expect(platform_record.disk_image_publications.where(git_sha: promoted_sha).count).to eq(1)
    end
  end
end
