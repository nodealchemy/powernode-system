# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Operator API — Package Repositories stale links", type: :request do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:user) do
    user_with_permissions("system.package_repositories.view",
                          "system.package_repositories.delete",
                          account: account)
  end
  let(:headers) { auth_headers_for(user).merge("Content-Type" => "application/json") }

  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:repo)     { create(:system_package_repository, account: account) }

  def make_module(name_suffix:)
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription",
           name: "stale-spec-#{name_suffix}-#{SecureRandom.hex(3)}")
  end

  def make_link(node_module:, auto_generated: true)
    create(:system_package_module_link,
           node_module: node_module, package_repository: repo,
           package_name: "pkg-#{node_module.name}",
           package_version: "1.0.0", architecture: "amd64",
           auto_generated: auto_generated)
  end

  describe "GET /api/v1/system/package_repositories/:id/stale_links" do
    it "lists only auto_generated links whose module has no template or assignment refs" do
      truly_stale = make_module(name_suffix: "stale-a")
      truly_stale_link = make_link(node_module: truly_stale, auto_generated: true)

      operator_chosen = make_module(name_suffix: "chosen-b")
      make_link(node_module: operator_chosen, auto_generated: false)  # excluded: not auto_generated

      get "/api/v1/system/package_repositories/#{repo.id}/stale_links", headers: headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body.dig("data", "stale_count")).to eq(1)
      expect(body.dig("data", "stale_links").first["id"]).to eq(truly_stale_link.id)
    end

    it "excludes links whose module is referenced by a template" do
      mod = make_module(name_suffix: "in-tmpl")
      make_link(node_module: mod, auto_generated: true)
      tmpl = create(:system_node_template, account: account, node_platform: platform,
                    name: "stale-tmpl-#{SecureRandom.hex(3)}")
      ::System::TemplateModule.create!(node_template: tmpl, node_module: mod, priority: 10)

      get "/api/v1/system/package_repositories/#{repo.id}/stale_links", headers: headers

      expect(JSON.parse(response.body).dig("data", "stale_count")).to eq(0)
    end

    it "excludes links whose module is referenced by a NodeModuleAssignment" do
      mod = make_module(name_suffix: "in-asn")
      make_link(node_module: mod, auto_generated: true)
      tmpl = create(:system_node_template, account: account, node_platform: platform,
                    name: "asn-tmpl-#{SecureRandom.hex(3)}")
      node = create(:system_node, account: account, node_template: tmpl,
                    name: "asn-node-#{SecureRandom.hex(3)}")
      ::System::NodeModuleAssignment.create!(node: node, node_module: mod, enabled: true)

      get "/api/v1/system/package_repositories/#{repo.id}/stale_links", headers: headers

      expect(JSON.parse(response.body).dig("data", "stale_count")).to eq(0)
    end
  end

  describe "POST /api/v1/system/package_repositories/:id/clean_stale_links" do
    let!(:stale_mod)  { make_module(name_suffix: "to-purge") }
    let!(:stale_link) { make_link(node_module: stale_mod, auto_generated: true) }

    it "treats absent force flag as dry_run (destroys nothing)" do
      post "/api/v1/system/package_repositories/#{repo.id}/clean_stale_links", headers: headers

      body = JSON.parse(response.body)
      expect(body.dig("data", "destroyed")).to eq(0)
      expect(body.dig("data", "kept")).to eq(1)
      expect(body.dig("data", "dry_run")).to be true
      expect(::System::NodeModule.where(id: stale_mod.id).exists?).to be true
    end

    it "destroys stale link + its NodeModule when force=true" do
      post "/api/v1/system/package_repositories/#{repo.id}/clean_stale_links",
           params: { force: true }.to_json, headers: headers

      body = JSON.parse(response.body)
      expect(body.dig("data", "destroyed")).to eq(1)
      expect(::System::NodeModule.where(id: stale_mod.id).exists?).to be false
      expect(::System::PackageModuleLink.where(id: stale_link.id).exists?).to be false
    end

    it "explicit dry_run=true skips destruction" do
      post "/api/v1/system/package_repositories/#{repo.id}/clean_stale_links",
           params: { dry_run: true }.to_json, headers: headers

      body = JSON.parse(response.body)
      expect(body.dig("data", "dry_run")).to be true
      expect(::System::NodeModule.where(id: stale_mod.id).exists?).to be true
    end
  end

  context "cross-account isolation" do
    it "404s when the repo belongs to another account" do
      foreign_repo = create(:system_package_repository, account: other_account)

      get "/api/v1/system/package_repositories/#{foreign_repo.id}/stale_links", headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end

  context "permissions" do
    it "403s clean_stale_links when user lacks delete permission" do
      viewer = user_with_permissions("system.package_repositories.view", account: account)
      viewer_headers = auth_headers_for(viewer).merge("Content-Type" => "application/json")

      post "/api/v1/system/package_repositories/#{repo.id}/clean_stale_links",
           params: { force: true }.to_json, headers: viewer_headers

      expect(response).to have_http_status(:forbidden)
    end
  end
end
