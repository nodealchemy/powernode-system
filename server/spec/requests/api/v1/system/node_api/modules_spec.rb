# frozen_string_literal: true

require "rails_helper"

# Locks the on-node modules endpoint against the dependant-children
# regression: dependants have parent_module_id + node_id but no
# NodeModuleAssignment row, so the legacy query (assignments only)
# silently dropped them from the agent's view.
RSpec.describe "Api::V1::System::NodeApi::Modules#index", type: :request do
  let(:account)       { create(:account) }
  let(:platform)      { create(:system_node_platform, account: account) }
  # Account.after_create_commit auto-bootstraps canonical categories
  # ("base", "security", "time", "web", "firmware") via AccountBootstrapService.
  # Uniqueness is case-insensitive, so `name: "Base"` collides with "base".
  # Drop the name override so the factory's sequence default applies.
  let(:category)      { create(:system_node_module_category, account: account) }
  let(:node_template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)          { create(:system_node, account: account, node_template: node_template) }
  let(:instance)      { create(:system_node_instance, node: node, status: "running") }
  let(:auth_token) do
    ::Security::JwtService.encode({
      sub:     instance.id,
      type:    "instance",
      version: ::Security::JwtService::CURRENT_TOKEN_VERSION
    })
  end
  let(:headers) { { "X-Instance-Token" => auth_token } }

  let(:base_module) do
    create(:system_node_module,
           account: account, node_platform: platform, category: category,
           variety: "subscription", name: "nginx-base", priority: 5)
  end
  let!(:assignment) do
    System::NodeModuleAssignment.create!(node: node, node_module: base_module, enabled: true, priority: 0)
  end

  describe "agent view" do
    it "returns base modules attached via NodeModuleAssignment" do
      get "/api/v1/system/node_api/modules", headers: headers
      expect(response).to have_http_status(:ok)
      names = JSON.parse(response.body).dig("data", "modules").map { |m| m["name"] }
      expect(names).to include("nginx-base")
    end

    it "ALSO returns dependant children scoped via parent_module + node FK" do
      child = assignment.create_dependant!
      expect(child.parent_module).to eq(base_module)
      expect(child.node).to eq(node)
      expect(System::NodeModuleAssignment.where(node_module: child)).to be_empty

      get "/api/v1/system/node_api/modules", headers: headers
      expect(response).to have_http_status(:ok)
      ids = JSON.parse(response.body).dig("data", "modules").map { |m| m["id"] }
      expect(ids).to include(base_module.id, child.id)
    end

    it "returns the inherited file_spec on a dependant child via show" do
      base_module.update!(dependency_spec: "/etc/inherited/**")
      child = assignment.create_dependant!

      get "/api/v1/system/node_api/modules/#{child.id}", headers: headers
      expect(response).to have_http_status(:ok)
      payload = JSON.parse(response.body)["data"]
      decoded = payload["file_spec"].map { |b| Base64.decode64(b) }
      expect(decoded).to include("/etc/inherited/**")
    end

    it "respects the dependant child's enabled flag" do
      child = assignment.create_dependant!
      child.update!(enabled: false)

      get "/api/v1/system/node_api/modules", headers: headers
      ids = JSON.parse(response.body).dig("data", "modules").map { |m| m["id"] }
      expect(ids).not_to include(child.id)
    end

    it "does NOT return dependant children of OTHER nodes" do
      other_node = create(:system_node, account: account, node_template: node_template)
      other_assignment = System::NodeModuleAssignment.create!(
        node: other_node, node_module: base_module, enabled: true, priority: 0
      )
      other_child = other_assignment.create_dependant!

      get "/api/v1/system/node_api/modules", headers: headers
      ids = JSON.parse(response.body).dig("data", "modules").map { |m| m["id"] }
      expect(ids).not_to include(other_child.id)
    end
  end

  describe "agent-needed fields in the response" do
    before do
      base_module.update!(
        init_start:      "systemctl start nginx",
        init_stop:       "systemctl stop nginx",
        init_restart:    "systemctl reload nginx",
        reboot_required: true,
        protected_spec:  "/etc/nginx/protected.conf",
        dependency_spec: "/etc/nginx/inherited/**",
        lock_spec:       true
      )
    end

    it "index emits reboot_required on every module (lifecycle hooks moved to services array per P8.1)" do
      get "/api/v1/system/node_api/modules", headers: headers
      mod = JSON.parse(response.body).dig("data", "modules").find { |m| m["name"] == "nginx-base" }
      expect(mod["reboot_required"]).to be true
      # Legacy init_* fields are no longer emitted to the agent.
      expect(mod).not_to have_key("init_start")
      expect(mod).not_to have_key("init_stop")
      expect(mod).not_to have_key("init_restart")
    end

    it "index emits effective_priority + parent_module_id" do
      child = assignment.create_dependant!
      get "/api/v1/system/node_api/modules", headers: headers
      modules = JSON.parse(response.body).dig("data", "modules")
      child_payload = modules.find { |m| m["id"] == child.id }
      expect(child_payload["parent_module_id"]).to eq(base_module.id)
      expect(child_payload["effective_priority"]).to eq(child.effective_priority)
    end

    it "show emits all five spec fields + lock_spec" do
      # The legacy `info` text blob (NodeModule#info) is no longer
      # emitted by the agent-facing serializer — the agent reads
      # structured fields (name, reboot_required, priority, services[])
      # directly instead of parsing the synthetic key=value text. Assert
      # only the live surface here.
      get "/api/v1/system/node_api/modules/#{base_module.id}", headers: headers
      payload = JSON.parse(response.body)["data"]
      expect(payload).to include(
        "mask", "file_spec", "package_spec", "dependency_spec", "protected_spec",
        "lock_spec"
      )
      expect(payload["lock_spec"]).to be true
      decoded_protected = payload["protected_spec"].map { |b| Base64.decode64(b) }
      expect(decoded_protected).to include("/etc/nginx/protected.conf")
      decoded_dependency = payload["dependency_spec"].map { |b| Base64.decode64(b) }
      expect(decoded_dependency).to include("/etc/nginx/inherited/**")
    end

    it "show emits copy_path block when copy_path is set" do
      copy_path = create(:system_node_module_copy_path, account: account,
                         name: "data-disk", source_path: "/src", destination_path: "/mnt/data",
                         recursive: true, preserve_permissions: false)
      base_module.update!(copy_path: copy_path)

      get "/api/v1/system/node_api/modules/#{base_module.id}", headers: headers
      payload = JSON.parse(response.body)["data"]
      expect(payload["copy_path"]).to include(
        "name" => "data-disk",
        "source_path" => "/src",
        "destination_path" => "/mnt/data",
        "recursive" => true,
        "preserve_permissions" => false
      )
      expect(payload["copy_path_destination"]).to eq("/mnt/data")
    end

    it "show emits copy_path: nil when not set" do
      get "/api/v1/system/node_api/modules/#{base_module.id}", headers: headers
      payload = JSON.parse(response.body)["data"]
      expect(payload["copy_path"]).to be_nil
    end

    # P8.1 — Per-service lifecycle. The on-node agent (internal/lifecycle)
    # consumes this array to write one systemd unit per service.
    it "show emits services array with full module_service shape" do
      # ModuleService dropped its `user` column in the
      # 2026-05-14 schema (20260514120001_create_system_module_services) —
      # identity now comes from either a `service_user_id` FK to a
      # platform-managed ServiceUser row or a `system_user` string drawn
      # from WELL_KNOWN_SYSTEM_USERS (root/nobody/daemon/...). The
      # serializer normalizes both via `effective_user` and emits the
      # winning string as `user`. Pick "nobody" — it's in the well-known
      # set and the test isn't asserting on any specific user semantics.
      svc = ::System::ModuleService.create!(
        account: account,
        node_module: base_module,
        name: "nginx",
        start_command: "/usr/sbin/nginx -g 'daemon off;'",
        stop_command: "/usr/sbin/nginx -s quit",
        restart_policy: "always",
        system_user: "nobody",
        working_directory: "/var/www",
        env: { "NGINX_HOST" => "dev.example.com" },
        exposed_ports: [ { "container" => 80, "host" => 80 } ],
        health_endpoint: "/healthz",
        # HEALTH_METHODS = %w[GET POST PUT] — uppercase HTTP verbs, no `http_*` prefix.
        health_method: "GET",
        health_interval_seconds: 10,
        health_timeout_seconds: 5,
        health_initial_delay_seconds: 0
      )

      get "/api/v1/system/node_api/modules/#{base_module.id}", headers: headers
      payload = JSON.parse(response.body)["data"]
      services = payload["services"]
      expect(services).to be_an(Array)
      expect(services.size).to eq(1)
      entry = services.first
      expect(entry).to include(
        "name" => "nginx",
        "start_command" => "/usr/sbin/nginx -g 'daemon off;'",
        "stop_command" => "/usr/sbin/nginx -s quit",
        "restart_policy" => "always",
        "user" => "nobody",
        "working_directory" => "/var/www",
        "health_endpoint" => "/healthz",
        "health_method" => "GET"
      )
      expect(entry["env"]).to eq("NGINX_HOST" => "dev.example.com")
      expect(entry["exposed_ports"]).to eq([ { "container" => 80, "host" => 80 } ])
      expect(entry["dependencies"]).to eq([])
      svc.reload
    end

    it "show services array preserves dependency edges by name" do
      # `system_user: "nobody"` satisfies ModuleService's
      # `exactly_one_user_source` validation without forcing a
      # ServiceUser row — same rationale as the previous test.
      pg  = ::System::ModuleService.create!(account: account, node_module: base_module,
                                             name: "postgres", start_command: "/usr/bin/postgres",
                                             system_user: "nobody")
      web = ::System::ModuleService.create!(account: account, node_module: base_module,
                                             name: "web", start_command: "/usr/sbin/nginx",
                                             system_user: "nobody")
      # ModuleServiceDependency delegates account to its module_service —
      # no `account_id` column on the table, so don't pass account here.
      ::System::ModuleServiceDependency.create!(module_service: web,
                                                depends_on_module_service: pg,
                                                kind: "start_before")

      get "/api/v1/system/node_api/modules/#{base_module.id}", headers: headers
      services = JSON.parse(response.body).dig("data", "services")
      web_entry = services.find { |s| s["name"] == "web" }
      pg_entry  = services.find { |s| s["name"] == "postgres" }
      expect(web_entry["dependencies"]).to include("postgres")
      expect(pg_entry["dependencies"]).to eq([])
    end

    it "show emits empty services array when no module_service rows seeded" do
      get "/api/v1/system/node_api/modules/#{base_module.id}", headers: headers
      services = JSON.parse(response.body).dig("data", "services")
      expect(services).to eq([])
    end
  end
end
