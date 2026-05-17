# frozen_string_literal: true

require "rails_helper"

# Locks the on-node modules endpoint against the dependant-children
# regression: dependants have parent_module_id + node_id but no
# NodeModuleAssignment row, so the legacy query (assignments only)
# silently dropped them from the agent's view.
RSpec.describe "Api::V1::System::NodeApi::Modules#index", type: :request do
  let(:account)       { create(:account) }
  let(:platform)      { create(:system_node_platform, account: account) }
  let(:category)      { create(:system_node_module_category, account: account, name: "Base") }
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
      payload = JSON.parse(response.body).dig("data", "module")
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

    it "show emits all five spec fields + lock_spec + info text" do
      get "/api/v1/system/node_api/modules/#{base_module.id}", headers: headers
      payload = JSON.parse(response.body).dig("data", "module")
      expect(payload).to include(
        "mask", "file_spec", "package_spec", "dependency_spec", "protected_spec",
        "lock_spec", "info"
      )
      expect(payload["lock_spec"]).to be true
      decoded_protected = payload["protected_spec"].map { |b| Base64.decode64(b) }
      expect(decoded_protected).to include("/etc/nginx/protected.conf")
      decoded_dependency = payload["dependency_spec"].map { |b| Base64.decode64(b) }
      expect(decoded_dependency).to include("/etc/nginx/inherited/**")
      expect(payload["info"]).to include("name=nginx-base", "reboot=true")
    end

    it "show emits copy_path block when copy_path is set" do
      copy_path = create(:system_node_module_copy_path, account: account,
                         name: "data-disk", source_path: "/src", destination_path: "/mnt/data",
                         recursive: true, preserve_permissions: false)
      base_module.update!(copy_path: copy_path)

      get "/api/v1/system/node_api/modules/#{base_module.id}", headers: headers
      payload = JSON.parse(response.body).dig("data", "module")
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
      payload = JSON.parse(response.body).dig("data", "module")
      expect(payload["copy_path"]).to be_nil
    end

    # P8.1 — Per-service lifecycle. The on-node agent (internal/lifecycle)
    # consumes this array to write one systemd unit per service.
    it "show emits services array with full module_service shape" do
      svc = ::System::ModuleService.create!(
        account: account,
        node_module: base_module,
        name: "nginx",
        start_command: "/usr/sbin/nginx -g 'daemon off;'",
        stop_command: "/usr/sbin/nginx -s quit",
        restart_policy: "always",
        user: "www-data",
        working_directory: "/var/www",
        env: { "NGINX_HOST" => "dev.example.com" },
        exposed_ports: [ { "container" => 80, "host" => 80 } ],
        health_endpoint: "/healthz",
        health_method: "http_get",
        health_interval_seconds: 10,
        health_timeout_seconds: 5,
        health_initial_delay_seconds: 0
      )

      get "/api/v1/system/node_api/modules/#{base_module.id}", headers: headers
      payload = JSON.parse(response.body).dig("data", "module")
      services = payload["services"]
      expect(services).to be_an(Array)
      expect(services.size).to eq(1)
      entry = services.first
      expect(entry).to include(
        "name" => "nginx",
        "start_command" => "/usr/sbin/nginx -g 'daemon off;'",
        "stop_command" => "/usr/sbin/nginx -s quit",
        "restart_policy" => "always",
        "user" => "www-data",
        "working_directory" => "/var/www",
        "health_endpoint" => "/healthz",
        "health_method" => "http_get"
      )
      expect(entry["env"]).to eq("NGINX_HOST" => "dev.example.com")
      expect(entry["exposed_ports"]).to eq([ { "container" => 80, "host" => 80 } ])
      expect(entry["dependencies"]).to eq([])
      svc.reload
    end

    it "show services array preserves dependency edges by name" do
      pg  = ::System::ModuleService.create!(account: account, node_module: base_module,
                                             name: "postgres", start_command: "/usr/bin/postgres")
      web = ::System::ModuleService.create!(account: account, node_module: base_module,
                                             name: "web", start_command: "/usr/sbin/nginx")
      ::System::ModuleServiceDependency.create!(account: account,
                                                module_service: web,
                                                depends_on_service: pg,
                                                kind: "start_before")

      get "/api/v1/system/node_api/modules/#{base_module.id}", headers: headers
      services = JSON.parse(response.body).dig("data", "module", "services")
      web_entry = services.find { |s| s["name"] == "web" }
      pg_entry  = services.find { |s| s["name"] == "postgres" }
      expect(web_entry["dependencies"]).to include("postgres")
      expect(pg_entry["dependencies"]).to eq([])
    end

    it "show emits empty services array when no module_service rows seeded" do
      get "/api/v1/system/node_api/modules/#{base_module.id}", headers: headers
      services = JSON.parse(response.body).dig("data", "module", "services")
      expect(services).to eq([])
    end
  end
end
