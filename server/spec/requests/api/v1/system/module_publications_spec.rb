# frozen_string_literal: true

require "rails_helper"

# CI-direct webhook receiver. The build-platform-modules workflow
# POSTs here after each `oras push + cosign sign` with the module
# slug + tag + artifact descriptor + the raw manifest YAML so the
# controller can re-sync NodeModule + ModuleService rows in lockstep
# with the erofs blob it just published.
RSpec.describe "POST /api/v1/system/module_publications", type: :request do
  let(:account)      { create(:account) }
  let(:platform)     { create(:system_node_platform, account: account) }
  let(:category)     { create(:system_node_module_category, account: account) }
  # The publish endpoint authenticates exclusively against the Worker
  # table (Worker.authenticate hashes provided → token_digest comparison).
  # A let! Worker fixture is the canonical setup; the ENV legacy path
  # was removed alongside Stage 3 of the auth-surface mTLS conversion.
  let(:ci_token) { "ci-tok-#{SecureRandom.hex(8)}" }
  let!(:ci_worker) do
    ::Worker.create_worker!(
      name:    "test-ci-worker-#{SecureRandom.hex(4)}",
      account: account,
      token:   ci_token
    )
  end
  let(:bearer) { { "Authorization" => "Bearer #{ci_token}", "Content-Type" => "application/json" } }

  let!(:node_module) do
    create(:system_node_module, account: account, node_platform: platform,
                                category: category, variety: "subscription",
                                name: "powernode-hub-backend",
                                gitea_repo_full_name: "powernode/powernode-hub-backend",
                                file_spec: [ Base64.strict_encode64("/opt/powernode-rails") ])
  end

  let(:manifest_yaml) do
    <<~YAML
      schema_version: 1
      name: powernode-hub-backend
      display_name: Powernode Hub Backend
      file_spec:
        - /opt/powernode/server/**
      mask:
        - /opt/powernode/server/tmp/***
      services:
        - name: rails
          start_command: "/usr/local/bin/rails-start.sh"
          restart_policy: always
          user: root
          working_directory: /opt/powernode/server
          env:
            RAILS_ENV: production
      reboot_required: false
    YAML
  end

  let(:artifacts) do
    {
      erofs: {
        oci_ref:       "git.powernode.org/powernode/powernode-hub-backend:abc1234",
        fsverity_root: "sha256:" + ("0" * 64),
        size:          12_345_678,
        media_type:    "application/vnd.powernode.erofs"
      }
    }
  end

  let(:base_body) do
    {
      module_name:       "powernode-hub-backend",
      tag:               "abc1234",
      manifest_yaml_b64: Base64.strict_encode64(manifest_yaml),
      artifacts:         artifacts
    }
  end

  before do
    # Layer-digest fetch hits the registry; skip the network hop in unit
    # tests. The behavior under success is covered by the agent's pull
    # path; here we only care that the controller calls it and merges
    # the response cleanly. nil = "couldn't fetch" path. The fetch logic
    # now lives in System::OciLayerDigestFetcher (extracted from the
    # controller), so the stub targets the service.
    allow_any_instance_of(::System::OciLayerDigestFetcher)
      .to receive(:fetch_oci_layer_digest).and_return(nil)
  end

  it "rejects requests without the CI bearer" do
    post "/api/v1/system/module_publications", params: base_body.to_json,
         headers: { "Content-Type" => "application/json" }
    expect(response).to have_http_status(:unauthorized)
  end

  it "rejects a bearer that isn't a known Worker token" do
    post "/api/v1/system/module_publications",
         params: base_body.to_json,
         headers: { "Authorization" => "Bearer not-a-real-worker-token",
                    "Content-Type"  => "application/json" }
    expect(response).to have_http_status(:unauthorized)
  end

  it "accepts a Worker-table-issued token and touches last_seen_at" do
    expect(ci_worker.last_seen_at).to be_nil

    post "/api/v1/system/module_publications",
         params: base_body.to_json,
         headers: bearer

    expect(response).to have_http_status(:ok)
    expect(ci_worker.reload.last_seen_at).to be_present
  end

  it "creates a NodeModuleVersion and applies the manifest to the parent NodeModule" do
    expect {
      post "/api/v1/system/module_publications", params: base_body.to_json, headers: bearer
    }.to change { node_module.versions.count }.by(1)

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body).fetch("data")
    expect(body["manifest_import_error"]).to be_nil, "import error: #{body['manifest_import_error']}"
    expect(body["manifest_applied"]).to be(true)

    node_module.reload
    decoded = Array(node_module.file_spec).map { |s| Base64.strict_decode64(s) }
    expect(decoded).to eq([ "/opt/powernode/server/**" ])

    svc = node_module.module_services.find_by(name: "rails")
    expect(svc).to be_present
    expect(svc.start_command).to eq("/usr/local/bin/rails-start.sh")
    expect(svc.working_directory).to eq("/opt/powernode/server")
  end

  it "still creates a version row when manifest_yaml_b64 is absent (backwards compat)" do
    body = base_body.except(:manifest_yaml_b64)
    expect {
      post "/api/v1/system/module_publications", params: body.to_json, headers: bearer
    }.to change { node_module.versions.count }.by(1)

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).dig("data", "manifest_applied")).to be(true) # nil-encoded as success: nothing to apply
    # NodeModule.file_spec unchanged
    decoded = Array(node_module.reload.file_spec).map { |s| Base64.strict_decode64(s) }
    expect(decoded).to eq([ "/opt/powernode-rails" ])
  end

  it "fails the publish with 422 when manifest_yaml_b64 is malformed" do
    # Before the 2026-05-25 qga dogfood incident, this endpoint silently
    # returned 200 with `manifest_applied: false` buried in the body. CI
    # didn't check that field, so platform-side schema drift produced
    # half-published modules (OCI artifact OK, services/file_spec empty)
    # that the agent silently no-op'd on. Now the publish fails loudly so
    # CI's notify step fails visibly and the operator gets the message at
    # publish time, not weeks later when assignments don't start.
    body = base_body.merge(manifest_yaml_b64: "@@@not-base64@@@")
    post "/api/v1/system/module_publications", params: body.to_json, headers: bearer

    expect(response).to have_http_status(:unprocessable_content)
    expect(JSON.parse(response.body).fetch("error")).to include("manifest apply failed")
      .and include("not valid base64")
  end

  describe "auto-create when NodeModule absent (publisher-side first publication)" do
    # These tests cover the deploy-decoupling path: when CI publishes a
    # module the platform's deployed code/seeds haven't created a
    # NodeModule for yet (e.g., a fresh rename or a newly-added module),
    # the controller should create the row on the CI worker's own account
    # instead of 404-ing.

    # The auto-created module always lands on the CI worker's account
    # (`account`), which the worker authenticated as.
    let(:publisher_account) { account } # account fixture from outer scope

    let(:fresh_module_yaml) do
      <<~YAML
        schema_version: 1
        name: never-seen-before
        display_name: "Brand New Module"
        description: "Newly introduced; the platform hasn't seeded this yet."
        license: "MIT"
        file_spec:
          - /opt/powernode/never-seen-before/**
        services:
          - name: nsb
            start_command: "/usr/bin/nsb"
            restart_policy: always
            user: root
            working_directory: /opt/powernode/never-seen-before
        dependencies:
          requires: []
          provides:
            - greenfield.test
        reboot_required: false
      YAML
    end

    it "creates a fresh NodeModule when no name nor gitea_repo match exists" do
      body = base_body.merge(
        module_name: "never-seen-before",
        manifest_yaml_b64: Base64.strict_encode64(fresh_module_yaml)
      )

      expect {
        post "/api/v1/system/module_publications", params: body.to_json, headers: bearer
      }.to change { System::NodeModule.where(name: "never-seen-before").count }.from(0).to(1)

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body).fetch("data")
      expect(data["manifest_applied"]).to be(true), "import error: #{data['manifest_import_error']}"

      new_mod = System::NodeModule.find_by(name: "never-seen-before")
      expect(new_mod.account_id).to eq(publisher_account.id)
      expect(new_mod.variety).to eq("subscription")
      expect(new_mod.enabled).to be(true)
      expect(new_mod.public).to be(false)
      expect(new_mod.priority).to eq(50)
      expect(new_mod.versions.count).to eq(1)
    end

    it "prefers the canonical 'Workloads' taxonomy category + 'ubuntu-24.04-lts' platform when present" do
      # Verify the resolver's preference for seed-managed canonical names
      # ("Workloads" category — campaign 019f6084 retired "Powernode
      # Platform" in favor of System::NodeModuleCategory::PLATFORM_TAXONOMY
      # — + "ubuntu-24.04-lts" platform). Without these preferences,
      # multi-category / multi-platform accounts would land newly-created
      # modules in non-deterministic homes.
      # for_platform_slug!: self-healing, matches the resolver's own
      # lookup — the Account bootstrap step doesn't seed this bucket, but
      # calling it twice (here + inside the resolver) is idempotent.
      canonical_category = System::NodeModuleCategory.for_platform_slug!(
        account: publisher_account, slug: "workloads"
      )
      canonical_platform = System::NodePlatform.find_or_create_by!(
        account: publisher_account, name: "ubuntu-24.04-lts"
      )
      body = base_body.merge(
        module_name: "newer-still",
        manifest_yaml_b64: Base64.strict_encode64(fresh_module_yaml.sub("never-seen-before", "newer-still"))
      )

      post "/api/v1/system/module_publications", params: body.to_json, headers: bearer

      expect(response).to have_http_status(:ok)
      created = System::NodeModule.find_by(name: "newer-still")
      expect(created).to be_present
      expect(created.category_id).to eq(canonical_category.id), "expected canonical 'Workloads' category, got category named #{created.category&.name.inspect}"
      expect(created.node_platform_id).to eq(canonical_platform.id), "expected canonical 'ubuntu-24.04-lts' platform, got platform named #{created.node_platform&.name.inspect}"
    end

    it "returns 422 with a clear message when the target can't be auto-created" do
      # Stub the resolver to simulate a worker account that can't supply a
      # usable category/platform for the stub row (resolve returns nil).
      # Mucking with the DB directly is brittle, and the lookup is now
      # account-scoped, so a targeted stub on the category resolution is
      # the cleanest way to drive the controller's 422 render path.
      allow_any_instance_of(::System::ModulePublishTargetResolver)
        .to receive(:resolve_publisher_category).and_return(nil)

      body = base_body.merge(module_name: "ghost-module")
      post "/api/v1/system/module_publications", params: body.to_json, headers: bearer

      expect(response).to have_http_status(:unprocessable_content)
      error_msg = JSON.parse(response.body).fetch("error")
      expect(error_msg).to match(/could not resolve or create NodeModule/i)
    end

    it "preserves the existing-row lookup path when name matches within the CI worker's account" do
      # Legitimate same-account lookup: a module already exists under the
      # CI worker's OWN account (`account`) whose name matches the publish
      # but whose gitea_repo_full_name does not. The name-match path must
      # resolve it (no duplicate row) and the publish lands on it.
      existing = create(:system_node_module, account: account, node_platform: platform,
                                             category: category, variety: "subscription",
                                             name: "same-account-mod",
                                             gitea_repo_full_name: "powernode/some-other-repo")

      body = base_body.merge(
        module_name: "same-account-mod",
        manifest_yaml_b64: Base64.strict_encode64(fresh_module_yaml.gsub("never-seen-before", "same-account-mod"))
      )

      expect {
        post "/api/v1/system/module_publications", params: body.to_json, headers: bearer
      }.not_to change { System::NodeModule.where(name: "same-account-mod").count }

      expect(response).to have_http_status(:ok)
      # Confirm it was the existing same-account module that received the version
      expect(existing.versions.count).to eq(1)
    end
  end

  describe "cross-tenant isolation — the module registry is account-scoped (IDOR fix)" do
    # The CI worker authenticates as `account` (tenant A). A publish MUST
    # resolve or create the target NodeModule strictly within the worker's
    # own account: it must never reach across tenants to a same-named (or
    # same-gitea_repo) module owned by another account, and auto-creation
    # must land in the worker's account — never a platform-wide publisher
    # heuristic that could attach the module to the wrong tenant.
    let(:fresh_module_yaml) do
      <<~YAML
        schema_version: 1
        name: placeholder
        display_name: "Placeholder"
        file_spec:
          - /opt/powernode/placeholder/**
        reboot_required: false
      YAML
    end

    it "does NOT resolve a same-named NodeModule owned by another account" do
      # Tenant B owns "shared-mod". Worker A publishes "shared-mod".
      other_account  = create(:account, name: "Other Tenant")
      other_platform = create(:system_node_platform, account: other_account)
      other_category = create(:system_node_module_category, account: other_account)
      victim = create(:system_node_module, account: other_account, node_platform: other_platform,
                                           category: other_category, variety: "subscription",
                                           name: "shared-mod")

      body = base_body.merge(
        module_name: "shared-mod",
        manifest_yaml_b64: Base64.strict_encode64(fresh_module_yaml.gsub("placeholder", "shared-mod"))
      )

      post "/api/v1/system/module_publications", params: body.to_json, headers: bearer

      expect(response).to have_http_status(:ok)
      # Tenant B's module must NEVER become the publish target.
      expect(victim.reload.versions.count).to eq(0)
      # The publish resolves/creates strictly within the CI worker's account (A).
      a_module = account.system_node_modules.find_by(name: "shared-mod")
      expect(a_module).to be_present
      expect(a_module.versions.count).to eq(1)
    end

    it "auto-creates a brand-new module under the CI worker's account, not the publisher heuristic" do
      # Stand up the account the legacy publisher heuristic ("Powernode
      # Admin" by default) would have selected, complete with a category +
      # platform so the unfixed resolver successfully creates the module
      # there. The fix must ignore the heuristic and create under tenant A.
      ENV.delete("PLATFORM_PUBLISHER_ACCOUNT_NAME")
      heuristic_account = create(:account, name: "Powernode Admin")
      create(:system_node_module_category, account: heuristic_account, variety: "subscription")
      create(:system_node_platform, account: heuristic_account)

      body = base_body.merge(
        module_name: "greenfield-mod",
        manifest_yaml_b64: Base64.strict_encode64(fresh_module_yaml.gsub("placeholder", "greenfield-mod"))
      )

      expect {
        post "/api/v1/system/module_publications", params: body.to_json, headers: bearer
      }.to change { System::NodeModule.where(name: "greenfield-mod").count }.from(0).to(1)

      expect(response).to have_http_status(:ok)
      created = System::NodeModule.find_by(name: "greenfield-mod")
      expect(created.account_id).to eq(account.id),
             "auto-created module landed in #{created.account&.name.inspect} (#{created.account_id}); " \
             "expected the CI worker's account #{account.name.inspect} (#{account.id})"
    end
  end
  # IMP-e2c2da99b4b5 — the platform-CI publish path is THIS controller (the
  # build-platform-modules workflow POSTs here); it never reaches
  # ModulePublicationProcessor / ModuleOciIngestService, which were the only
  # writers of NodeModuleVersion#fsverity_root_hash. So the workflow computed
  # the fs-verity root, shipped it as artifacts.erofs.fsverity_root, and the
  # column stayed nil for every platform module — making the agent's fs-verity
  # mount gate (fail-closed on an empty root) unusable fleet-wide.
  describe "fs-verity root denormalization onto the version column" do
    let(:real_root) { "sha256:#{'ab' * 32}" }

    it "writes the notify payload's fsverity root to NodeModuleVersion#fsverity_root_hash" do
      body = base_body.merge(
        artifacts: artifacts.deep_merge(erofs: { fsverity_root: real_root })
      )

      post "/api/v1/system/module_publications", params: body.to_json, headers: bearer

      expect(response).to have_http_status(:ok)
      version = node_module.versions.order(:created_at).last
      expect(version.fsverity_root_hash).to eq(real_root),
             "the publish recorded #{version.fsverity_root_hash.inspect}; the agent's mount gate reads this " \
             "column (via ModuleVersionService/compliance) and refuses to mount on a nil root"
      # The agent-facing JSONB key keeps carrying it too — the column is a
      # denormalization, not a move.
      expect(version.artifacts.dig("erofs", "fsverity_root")).to eq(real_root)
    end

    it "leaves the column nil rather than persisting a malformed root" do
      body = base_body.merge(
        artifacts: artifacts.deep_merge(erofs: { fsverity_root: "fsverity: command not found" })
      )

      post "/api/v1/system/module_publications", params: body.to_json, headers: bearer

      expect(response).to have_http_status(:ok)
      version = node_module.versions.order(:created_at).last
      expect(version.fsverity_root_hash).to be_nil
      # The publish still succeeds: fs-verity is opt-in fleet-wide, so a
      # missing root must not block shipping the module.
      expect(version.artifacts.dig("erofs", "oci_ref")).to be_present
    end

    it "never overwrites an already-published root with nil when the root goes missing" do
      post "/api/v1/system/module_publications", params: base_body.to_json, headers: bearer
      expect(response).to have_http_status(:ok)
      version = node_module.versions.order(:created_at).last
      expect(version.fsverity_root_hash).to be_present

      # Same module@tag re-notified (a CI retry) without the root.
      republish = base_body.merge(
        artifacts: { erofs: artifacts[:erofs].except(:fsverity_root) }
      )
      post "/api/v1/system/module_publications", params: republish.to_json, headers: bearer

      expect(response).to have_http_status(:ok)
      expect(version.reload.fsverity_root_hash).to be_present,
             "a rootless re-notify nulled a root the previous publish had established"
    end
  end
end
