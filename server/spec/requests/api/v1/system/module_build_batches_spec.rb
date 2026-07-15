# frozen_string_literal: true

require "rails_helper"

# Campaign 019f6084 inc2-A — read API over System::ModuleBuildBatch (the
# agent-pollable build-completion barrier). Mirrors
# node_module_versions_promote_spec.rb's structure. Constructs batches
# directly via .create! (no factory — see spec/models/system/
# module_build_batch_spec.rb for the same direct-construction precedent).
RSpec.describe "Operator API — Module Build Batches", type: :request do
  let(:account)       { create(:account) }
  let(:other_account) { create(:account) }
  let(:user)          { user_with_permissions("system.module_builds.read", account: account) }
  let(:headers)        { auth_headers_for(user) }

  def build_batch(account:, status: "planning", trigger: "push", **attrs)
    System::ModuleBuildBatch.create!(
      account: account, status: status, trigger: trigger,
      base_sha: "a" * 40, head_sha: "b" * 40, **attrs
    )
  end

  describe "GET /api/v1/system/module_build_batches" do
    context "permissions" do
      it "403s without system.module_builds.read" do
        viewer = user_without_permissions(account: account)
        get "/api/v1/system/module_build_batches", headers: auth_headers_for(viewer)

        expect(response).to have_http_status(:forbidden)
      end
    end

    context "happy path" do
      it "lists batches for the current account only, summary-shaped" do
        batch = build_batch(account: account, module_slugs: %w[mod-a], planned_count: 1)
        build_batch(account: other_account) # cross-account — must not leak into the list

        get "/api/v1/system/module_build_batches", headers: headers

        expect(response).to have_http_status(:ok)
        rows = JSON.parse(response.body).dig("data", "module_build_batches")
        expect(rows.map { |r| r["id"] }).to contain_exactly(batch.id)

        row = rows.first
        expect(row["trigger"]).to eq("push")
        expect(row["module_slugs"]).to eq([ "mod-a" ])
        expect(row).not_to have_key("modules") # per-module join is show-only
      end
    end

    context "filters" do
      it "filters by_status" do
        build_batch(account: account, status: "planning")
        failed = build_batch(account: account, status: "failed")

        get "/api/v1/system/module_build_batches", params: { status: "failed" }, headers: headers

        rows = JSON.parse(response.body).dig("data", "module_build_batches")
        expect(rows.map { |r| r["id"] }).to contain_exactly(failed.id)
      end

      it "filters by_trigger 'package' (the PackageClosureBuildBridge path) without leaking repo credentials" do
        secret_armor = "-----BEGIN PGP PUBLIC KEY BLOCK-----\nSUPER-SECRET-KEY-MATERIAL\n-----END PGP PUBLIC KEY BLOCK-----"
        package_batch = build_batch(account: account, trigger: "package",
                                     module_slugs: %w[libfoo], planned_count: 1)
        package_batch.update!(metadata: package_batch.metadata.merge(
          "package_context" => {
            "repository_id" => "repo-1", "package_repo_kind" => "apt", "architecture" => "amd64",
            "apt_snapshot" => "20260714T000000Z", "tag" => "abc1234",
            "gpg_key_armor" => secret_armor,
            "package_repo_url" => "https://svc:s3cr3t-token@repo.example.com/apt"
          }
        ))
        build_batch(account: account, trigger: "push")

        get "/api/v1/system/module_build_batches", params: { trigger: "package" }, headers: headers

        expect(response).to have_http_status(:ok)
        rows = JSON.parse(response.body).dig("data", "module_build_batches")
        expect(rows.map { |r| r["id"] }).to contain_exactly(package_batch.id)
        expect(rows.first.dig("package_context", "snapshot")).to eq("20260714T000000Z")
        expect(rows.first.dig("package_context", "tag")).to eq("abc1234")

        # CRITICAL — never dump gpg_key_armor / raw repo credentials.
        expect(response.body).not_to include("SUPER-SECRET-KEY-MATERIAL")
        expect(response.body).not_to include("s3cr3t-token")
        expect(response.body).not_to include("gpg_key_armor")
        expect(response.body).not_to include("package_repo_url")
      end
    end
  end

  describe "GET /api/v1/system/module_build_batches/:id" do
    it "403s without system.module_builds.read" do
      batch = build_batch(account: account)
      viewer = user_without_permissions(account: account)

      get "/api/v1/system/module_build_batches/#{batch.id}", headers: auth_headers_for(viewer)

      expect(response).to have_http_status(:forbidden)
    end

    it "404s for a batch in another account" do
      foreign = build_batch(account: other_account)

      get "/api/v1/system/module_build_batches/#{foreign.id}", headers: headers

      expect(response).to have_http_status(:not_found)
    end

    it "returns the full per-module breakdown: AASM ladder + task + lease + artifact" do
      platform     = create(:system_node_platform, account: account)
      category     = create(:system_node_module_category, account: account)
      node_module  = create(:system_node_module, account: account, node_platform: platform,
                             category: category, name: "mod-a")
      instance     = create(:system_node_instance, :running, account: account)

      batch = build_batch(account: account, trigger: "push", status: "dispatched",
                           module_slugs: %w[mod-a], planned_count: 1)
      batch.update!(dispatched_at: Time.current)

      task = create(:system_task, account: account, operable: instance, command: "ci.module_build",
                    status: "complete",
                    options: { "module" => "mod-a", "batch_id" => batch.id, "oci_ref" => "abc1234" })
      lease = ::System::CiRunnerLease.create!(
        account: account, node_instance: instance, status: "released", purpose: "module_build",
        runner_scope: "repo", build_task_id: task.id, runner_name: "builder-1"
      )
      version = create(:system_node_module_version, node_module: node_module, version_number: 1,
                       config: { "git_tag" => "abc1234" }, promotion_state: "blessed")
      artifact = ::System::ModuleArtifact.create!(
        node_module_version: version, oci_ref: "registry.example/powernode/mod-a:abc1234",
        oci_digest: "sha256:#{'a' * 64}", media_type: ::System::ModuleArtifact::DEFAULT_MEDIA_TYPE,
        architecture: "amd64", size_bytes: 12_345, built_at: Time.current, cosign_bundle: "signed-bundle-bytes"
      )

      batch.update!(metadata: batch.metadata.merge(
        "modules" => {
          "mod-a" => { "tag" => "abc1234", "state" => "succeeded", "attempts" => 1,
                       "lease_id" => lease.id, "task_id" => task.id, "error" => nil }
        }
      ))

      get "/api/v1/system/module_build_batches/#{batch.id}", headers: headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body).dig("data", "module_build_batch")
      expect(body["status"]).to eq("dispatched")
      expect(body["dispatched_at"]).not_to be_nil

      row = body["modules"].find { |m| m["module"] == "mod-a" }
      expect(row["state"]).to eq("succeeded")
      expect(row.dig("task", "id")).to eq(task.id)
      expect(row.dig("task", "status")).to eq("complete")
      expect(row.dig("lease", "id")).to eq(lease.id)
      expect(row.dig("lease", "runner_name")).to eq("builder-1")
      expect(row.dig("artifact", "oci_digest")).to eq(artifact.oci_digest)
      expect(row.dig("artifact", "size_bytes")).to eq(12_345)
      expect(row.dig("artifact", "signed")).to eq(true)
      expect(row.dig("artifact", "version_number")).to eq(1)
      expect(row.dig("artifact", "promotion_state")).to eq("blessed")

      # CRITICAL — the cosign bundle bytes themselves never leak.
      expect(response.body).not_to include("signed-bundle-bytes")
    end
  end
end
