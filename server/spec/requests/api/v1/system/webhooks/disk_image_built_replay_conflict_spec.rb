# frozen_string_literal: true

require "rails_helper"

# IMP-f0aad29b3344 sibling / webhook-replay thread.
#
# THE DEFECT: #handle called upsert_publication! (which ends in save!) BEFORE
# the already-published check. So a second delivery for a git_sha that is
# already published overwrote sha256, oci_ref, uki_oci_ref, uki_sha256 and
# uki_cosign_bundle on a live row, then returned "idempotent_hit / already
# published with this git_sha" and returned BEFORE dispatch_or_run — so the
# replacement artifact was never verified by anything. published_at,
# verified_at and file_object_id were left describing the PREVIOUS build, so
# every downstream reader (boot_image_controller's git_sha branch,
# UpgradeDispatcher.preflight) reported the row as published and verified.
#
# Proven end to end before the fix: a node fetching its platform's boot image
# was handed uki_sha256/uki_oci_ref that no verification step ever approved,
# and the operator-approved digest stopped resolving because the column it
# matched on had been overwritten.
#
# The realistic trigger needs no compromise: an ordinary CI re-run of the same
# git_sha producing different bytes — a rebuild, a re-tag, a retried job, a
# non-reproducible build. Builds are frequently not bit-reproducible.
RSpec.describe "Disk image built webhook — replayed delivery conflict", type: :request do
  let(:account) { create(:account) }
  let(:platform) { account.system_node_platforms.find_by!(name: "ubuntu-24.04-rpi4") }
  let!(:webhook_pair) { ::System::DiskImageWebhook.create_with_secret!(account: account, label: "ci") }
  let(:webhook) { webhook_pair[0] }
  let(:secret)  { webhook_pair[1] }

  let(:approved_digest) { "a" * 64 }
  let(:replay_digest)   { "b" * 64 }

  def hmac_sig(body, sec) = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', sec, body)}"

  def deliver!(uki_digest:, uki_ref:, img_sha: "c" * 64, git_sha: "abc123")
    body = { platform_name: platform.name, sha256: img_sha, size_bytes: 1024,
             git_sha: git_sha, oci_ref: "reg/img:#{git_sha}", arch: "arm64",
             uki_oci_ref: uki_ref, uki_sha256: uki_digest,
             uki_cosign_bundle: "bundle-#{uki_digest[0, 4]}" }.to_json
    post "/api/v1/system/webhooks/disk_image/built/#{webhook.id}",
         params: body,
         headers: { "Content-Type" => "application/json", "X-Powernode-Signature" => hmac_sig(body, secret) }
    JSON.parse(response.body)
  end

  # Land a first build and promote it to the published+verified state a live
  # platform actually serves.
  def publish_first_build!
    deliver!(uki_digest: approved_digest, uki_ref: "reg/uki:approved")
    pub = ::System::DiskImagePublication.find_by!(node_platform: platform, git_sha: "abc123")
    fo = create(:file_object, account: account, filename: "img",
                content_type: "application/octet-stream")
    pub.update_columns(file_object_id: fo.id, status: "published",
                       published_at: 1.week.ago, verified_at: 1.week.ago)
    platform.update_columns(disk_image_git_sha: "abc123", disk_image_file_object_id: fo.id)
    [ pub.reload, fo ]
  end

  before do
    ENV["POWERNODE_WEBHOOK_INGEST_MODE"] = "inline"
    allow(::System::DiskImagePublicationProcessor).to receive(:process!) do |publication:|
      ::System::DiskImagePublicationProcessor::Result.new(ok?: true, publication: publication)
    end
  end
  after { ENV.delete("POWERNODE_WEBHOOK_INGEST_MODE") }

  describe "a CONFLICTING delivery for an already-published git_sha" do
    # (a) the published row's pointers must be untouched.
    it "leaves every artifact pointer on the published row unchanged" do
      pub, fo = publish_first_build!

      deliver!(uki_digest: replay_digest, uki_ref: "reg/uki:replayed", img_sha: "d" * 64)

      pub.reload
      expect(pub.uki_sha256).to eq(approved_digest)
      expect(pub.uki_oci_ref).to eq("reg/uki:approved")
      expect(pub.uki_cosign_bundle).to eq("bundle-#{approved_digest[0, 4]}")
      expect(pub.sha256).to eq("c" * 64)
      expect(pub.oci_ref).to eq("reg/img:abc123")
      # ...and the provenance that describes the verified build.
      expect(pub.status).to eq("published")
      expect(pub.file_object_id).to eq(fo.id)
    end

    # (b) it must NOT be reported as an ordinary idempotent hit. Silently
    # discarding a genuinely different build is its own hazard, and the old
    # response actively misled anyone reading it.
    it "reports a distinct conflict status, not idempotent_hit" do
      publish_first_build!

      json = deliver!(uki_digest: replay_digest, uki_ref: "reg/uki:replayed", img_sha: "d" * 64)

      expect(json["status"]).to eq("conflict")
      expect(json["status"]).not_to eq("idempotent_hit")
      expect(json["reason"]).to eq("published_artifact_mismatch")
    end

    # (c) the operator needs both digests to diagnose it.
    it "logs the conflict with both the published and the delivered digest" do
      publish_first_build!
      logged = []
      allow(Rails.logger).to receive(:warn) { |m| logged << m.to_s }

      deliver!(uki_digest: replay_digest, uki_ref: "reg/uki:replayed", img_sha: "d" * 64)

      conflict = logged.find { |m| m.include?("conflict") }
      expect(conflict).to be_present
      expect(conflict).to include(approved_digest)
      expect(conflict).to include(replay_digest)
    end

    it "does not run the processor for the discarded delivery" do
      publish_first_build!
      expect(::System::DiskImagePublicationProcessor).not_to receive(:process!)

      deliver!(uki_digest: replay_digest, uki_ref: "reg/uki:replayed", img_sha: "d" * 64)
    end
  end

  # (e) an genuinely identical redelivery is a real idempotent hit and must
  # keep behaving exactly as before — this is the common case (CI retries,
  # at-least-once webhook delivery) and must not start reporting conflicts.
  describe "an IDENTICAL redelivery" do
    it "still reports idempotent_hit" do
      publish_first_build!

      json = deliver!(uki_digest: approved_digest, uki_ref: "reg/uki:approved")

      expect(json["status"]).to eq("idempotent_hit")
      expect(json["note"]).to match(/already published/i)
    end
  end

  # (d) the not-yet-published path is unchanged: a row still in flight must
  # keep being updated by subsequent deliveries exactly as it is today.
  describe "a row that is NOT yet published" do
    it "still updates from a later delivery" do
      deliver!(uki_digest: approved_digest, uki_ref: "reg/uki:first")
      pub = ::System::DiskImagePublication.find_by!(node_platform: platform, git_sha: "abc123")
      expect(pub.status).not_to eq("published")

      json = deliver!(uki_digest: replay_digest, uki_ref: "reg/uki:second", img_sha: "e" * 64)

      pub.reload
      expect(json["status"]).to eq("queued")
      expect(pub.uki_sha256).to eq(replay_digest)
      expect(pub.uki_oci_ref).to eq("reg/uki:second")
      expect(pub.sha256).to eq("e" * 64)
    end

    it "still creates a brand-new publication for an unseen git_sha" do
      expect {
        deliver!(uki_digest: approved_digest, uki_ref: "reg/uki:new", git_sha: "fresh99")
      }.to change(::System::DiskImagePublication, :count).by(1)
    end
  end
end
