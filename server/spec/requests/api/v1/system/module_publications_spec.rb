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
    # the controller should create the row on the publisher account
    # instead of 404-ing.

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

    before do
      # Force the publisher-account resolver to pick the account fixture
      # by aliasing PLATFORM_PUBLISHER_ACCOUNT_NAME to its name.
      ENV["PLATFORM_PUBLISHER_ACCOUNT_NAME"] = publisher_account.name
    end

    after { ENV.delete("PLATFORM_PUBLISHER_ACCOUNT_NAME") }

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

    it "prefers the canonical 'Powernode Platform' category + 'ubuntu-24.04-lts' platform when present" do
      # Verify the resolver's preference for seed-managed canonical names
      # ("Powernode Platform" category, "ubuntu-24.04-lts" platform).
      # Without these preferences, multi-category / multi-platform accounts
      # would land newly-created modules in non-deterministic homes.
      # Use find_or_create_by: the Account bootstrap step may have already
      # seeded one (or both) of these on `publisher_account` — collisions
      # are noise, but the IDs we want to assert against need to exist.
      canonical_category = System::NodeModuleCategory.find_or_create_by!(
        account: publisher_account, name: "Powernode Platform", variety: "subscription"
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
      expect(created.category_id).to eq(canonical_category.id), "expected canonical 'Powernode Platform' category, got category named #{created.category&.name.inspect}"
      expect(created.node_platform_id).to eq(canonical_platform.id), "expected canonical 'ubuntu-24.04-lts' platform, got platform named #{created.node_platform&.name.inspect}"
    end

    it "returns 422 with a clear message when no publisher account is resolvable" do
      # Stub the resolver to simulate a scenario where no account fits the
      # publisher heuristic. Mucking with the DB directly (destroy_all on
      # NodeModule / Account) is brittle: (a) the controller's final
      # fallback would pick the only remaining account anyway, and
      # (b) Account.destroy_all cascades through associations that have
      # unrelated schema drift (system_node_architectures.account_id is
      # not in the live schema even though the model declares it).
      allow_any_instance_of(::System::ModulePublishTargetResolver)
        .to receive(:resolve_publisher_account).and_return(nil)

      body = base_body.merge(module_name: "ghost-module")
      post "/api/v1/system/module_publications", params: body.to_json, headers: bearer

      expect(response).to have_http_status(:unprocessable_content)
      error_msg = JSON.parse(response.body).fetch("error")
      expect(error_msg).to match(/could not resolve or create NodeModule/i)
    end

    it "preserves the existing-row lookup path when name matches" do
      # Pre-create a NodeModule under a DIFFERENT account so name match
      # resolves it instead of auto-creating a duplicate.
      other_account = create(:account, name: "Other Tenant")
      other_platform = create(:system_node_platform, account: other_account)
      other_category = create(:system_node_module_category, account: other_account)
      existing = create(:system_node_module, account: other_account, node_platform: other_platform,
                                              category: other_category, variety: "subscription",
                                              name: "shared-name-mod")

      body = base_body.merge(
        module_name: "shared-name-mod",
        manifest_yaml_b64: Base64.strict_encode64(fresh_module_yaml.gsub("never-seen-before", "shared-name-mod"))
      )

      expect {
        post "/api/v1/system/module_publications", params: body.to_json, headers: bearer
      }.not_to change { System::NodeModule.where(name: "shared-name-mod").count }

      expect(response).to have_http_status(:ok)
      # Confirm it was the existing module that received the version, not a new one
      expect(existing.versions.count).to eq(1)
    end
  end
end
