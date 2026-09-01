# frozen_string_literal: true

require "rails_helper"

# IMP-64854437ca43 — `vault_credential_path` was permitted and persisted on the
# package-repository endpoints but read by NOTHING. Package repo sync has no
# authentication story at all by construction: every index fetch goes through
# `System::PackageAdapters::Base#http_get`, which builds a bare Faraday
# connection and calls `conn.get(url)` — no auth header, no credential
# parameter, no seam to pass one. The table carries no other auth field
# (`signing_key_armor` is a PUBLIC key for GPG verification, not auth).
#
# Removing the permit alone does NOT fix the operator-visible harm.
# `action_on_unpermitted_parameters` is unset across both config trees, so the
# framework default applies (actionpack railtie: `Rails.env.local? ? :log :
# false`) — in production an unpermitted param is discarded SILENTLY. The
# operator's experience would be identical before and after: send the field,
# get a 200, nothing happens, and keep believing authentication is configured.
# So the endpoints now REJECT the field explicitly rather than teach a lie by
# silence.
#
# The rejection is deliberately narrow: it fires on a NON-BLANK value (an
# operator supplying a path, i.e. the actual misconfiguration) and not on a
# blank/nil one (which expresses "no auth" and is a harmless no-op).
RSpec.describe "/api/v1/system/package_repositories credential surface", type: :request do
  let(:account_a) { create(:account) }
  let(:user_a) do
    user_with_permissions(
      "system.package_repositories.view",
      "system.package_repositories.create",
      "system.package_repositories.update",
      account: account_a
    )
  end

  let(:base_attrs) do
    {
      name: "auth-apt",
      kind: "apt",
      base_url: "https://archive.example.com/ubuntu",
      architectures: [ "amd64" ],
      apt_config: { suite: "noble", components: [ "main" ] }
    }
  end

  describe "POST (create)" do
    it "rejects a non-blank vault_credential_path with 422 and creates NO row" do
      params = { package_repository: base_attrs.merge(vault_credential_path: "secret/data/pkgrepo/auth") }

      expect {
        post "/api/v1/system/package_repositories", params: params.to_json,
                                                    headers: auth_headers_for(user_a)
      }.not_to change(System::PackageRepository, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(json_response["success"]).to be(false)
      expect(json_response["error"])
        .to eq(Api::V1::System::PackageRepositoriesController::UNSUPPORTED_CREDENTIAL_PATH_MESSAGE)
      # The row assertion above is the load-bearing one: a guard that renders
      # from an action body without halting still emits a clean 422 while the
      # write LANDS.
      expect(System::PackageRepository.where(name: "auth-apt")).to be_empty
    end

    # Reviewer-found gap: without this, a mutant hoisting the credential guard
    # above the `require_permission` gate turns an unauthorized caller's 403
    # into a 422 and every other example here still passes. Authorization must
    # settle before we disclose anything about field-level API semantics.
    it "answers 403, not 422, when the caller lacks permission" do
      viewer = user_with_permissions("system.package_repositories.view", account: account_a)
      params = { package_repository: base_attrs.merge(vault_credential_path: "secret/data/pkgrepo/auth") }

      expect {
        post "/api/v1/system/package_repositories", params: params.to_json,
                                                    headers: auth_headers_for(viewer)
      }.not_to change(System::PackageRepository, :count)

      expect(response).to have_http_status(:forbidden)
    end

    it "still creates normally when the field is absent" do
      post "/api/v1/system/package_repositories", params: { package_repository: base_attrs }.to_json,
                                                  headers: auth_headers_for(user_a)

      expect(response).to have_http_status(:created)
      repo = System::PackageRepository.find(json_response_data["package_repository"]["id"])
      expect(repo.name).to eq("auth-apt")
    end

    # Load-bearing for the PERMIT REMOVAL specifically (distinct from the 422
    # guard): a blank value passes the guard, so if `:vault_credential_path`
    # were still in the `permit(...)` list the empty string would be persisted
    # and this expectation would see "" instead of nil.
    it "accepts a blank vault_credential_path but never persists it" do
      params = { package_repository: base_attrs.merge(vault_credential_path: "") }

      post "/api/v1/system/package_repositories", params: params.to_json,
                                                  headers: auth_headers_for(user_a)

      expect(response).to have_http_status(:created)
      repo = System::PackageRepository.find(json_response_data["package_repository"]["id"])
      expect(repo.vault_credential_path).to be_nil
    end
  end

  describe "GET (show)" do
    let!(:repo) { create(:system_package_repository, account: account_a) }

    # Without this, re-adding vault_credential_path to #serialize would hand a
    # client a field it can no longer send back: the round trip would 422.
    it "never serializes vault_credential_path" do
      get "/api/v1/system/package_repositories/#{repo.id}", headers: auth_headers_for(user_a)

      expect(response).to have_http_status(:ok)
      expect(json_response_data["package_repository"]).not_to have_key("vault_credential_path")
    end
  end

  describe "PATCH (update)" do
    let!(:repo) do
      create(:system_package_repository, account: account_a, name: "existing", description: "before")
    end

    it "rejects a non-blank vault_credential_path with 422 and applies NO part of the payload" do
      params = { package_repository: { description: "after", vault_credential_path: "secret/data/pkgrepo/auth" } }

      patch "/api/v1/system/package_repositories/#{repo.id}", params: params.to_json,
                                                              headers: auth_headers_for(user_a)

      expect(response).to have_http_status(:unprocessable_content)
      # Row-level assertions — these fail if the guard renders without halting.
      expect(repo.reload.description).to eq("before")
      expect(repo.vault_credential_path).to be_nil
    end

    it "still updates normally when the field is absent" do
      patch "/api/v1/system/package_repositories/#{repo.id}",
            params: { package_repository: { description: "after" } }.to_json,
            headers: auth_headers_for(user_a)

      expect(response).to have_http_status(:ok)
      expect(repo.reload.description).to eq("after")
    end
  end
end
