# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Gitops::DiffEngine do
  let(:account) { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }

  before do
    # Account.after_create_commit :run_account_bootstrap seeds 7 templates
    # + 6 modules per the M1 self-serve onboarding flow. These specs
    # exercise GitOps diff semantics on a controlled fixture set — clear
    # the bootstrap state so live counts + uniqueness checks reflect the
    # test setup, not production onboarding defaults. NodeModule.current_
    # version_id <-> NodeModuleVersion.node_module_id is a self-referential
    # FK pair, so we NULL the current_version_id first to let destroy_all
    # cascade cleanly.
    ::System::NodeModuleAssignment
      .joins(:node)
      .where(system_nodes: { account_id: account.id })
      .destroy_all
    ::System::NodeTemplate.where(account: account).destroy_all
    ::System::NodeModule.where(account: account).update_all(current_version_id: nil)
    ::System::NodeModule.where(account: account).destroy_all
  end

  describe ".diff!" do
    context "templates" do
      let!(:existing_template) do
        create(:system_node_template, account: account, name: "web-server",
                                       description: "old description")
      end

      it "detects an update to an existing template" do
        desired_state = build_desired_state(
          templates: { "web-server" => { "name" => "web-server",
                                         "description" => "new description",
                                         "node_platform_id" => existing_template.node_platform_id } }
        )

        result = described_class.diff!(account: account, desired_state: desired_state)

        expect(result.ok?).to be true
        update_diff = result.diffs.find { |d| d.change == :update && d.kind == "template" }
        expect(update_diff).to be_present
        expect(update_diff.name).to eq("web-server")
        expect(update_diff.current["description"]).to eq("old description")
      end

      it "detects a new template" do
        desired_state = build_desired_state(
          templates: {
            "web-server"  => { "name" => "web-server", "description" => existing_template.description, "node_platform_id" => existing_template.node_platform_id },
            "db-server"   => { "name" => "db-server", "description" => "DB nodes", "node_platform_id" => platform.id }
          }
        )

        result = described_class.diff!(account: account, desired_state: desired_state)

        create_diff = result.diffs.find { |d| d.change == :create && d.name == "db-server" }
        expect(create_diff).to be_present
      end

      it "detects a destroy when live state has a template absent from desired" do
        desired_state = build_desired_state(templates: {})

        result = described_class.diff!(account: account, desired_state: desired_state)

        destroy_diff = result.diffs.find { |d| d.change == :destroy && d.kind == "template" }
        expect(destroy_diff).to be_present
        expect(destroy_diff.name).to eq("web-server")
      end

      it "produces no diff when current matches desired" do
        desired_state = build_desired_state(
          templates: { "web-server" => { "name" => "web-server",
                                         "description" => existing_template.description,
                                         "node_platform_id" => existing_template.node_platform_id } }
        )

        result = described_class.diff!(account: account, desired_state: desired_state)
        template_diffs = result.diffs.select { |d| d.kind == "template" }
        expect(template_diffs).to be_empty
      end
    end

    context "modules" do
      let!(:existing_module) do
        create(:system_node_module, account: account, name: "nginx", priority: 50, variety: "config")
      end

      it "detects priority changes" do
        desired_state = build_desired_state(
          modules: { "nginx" => { "name" => "nginx", "priority" => 75, "variety" => "config" } }
        )

        result = described_class.diff!(account: account, desired_state: desired_state)
        module_diff = result.diffs.find { |d| d.kind == "module" }
        expect(module_diff.change).to eq(:update)
        expect(module_diff.current["priority"]).to eq(50)
      end
    end

    context "assignments (keyed node:module)" do
      let(:node) { create(:system_node, account: account, name: "host-1") }
      let(:mod)  { create(:system_node_module, account: account, name: "nginx") }
      let!(:assignment) { create(:system_node_module_assignment, node: node, node_module: mod, enabled: true, priority: 50) }

      it "detects enabled-flag changes" do
        desired_state = build_desired_state(
          assignments: { "host-1:nginx" => { "enabled" => false, "priority" => 50, "config" => {} } }
        )

        result = described_class.diff!(account: account, desired_state: desired_state)
        diff = result.diffs.find { |d| d.kind == "assignment" }

        expect(diff.change).to eq(:update)
        expect(diff.current["enabled"]).to be true
        expect(diff.desired["enabled"]).to be false
      end

      it "flags live assignments missing from desired as destroy candidates" do
        desired_state = build_desired_state(assignments: {})

        result = described_class.diff!(account: account, desired_state: desired_state)
        diff = result.diffs.find { |d| d.kind == "assignment" && d.change == :destroy }

        expect(diff).to be_present
        expect(diff.name).to eq("host-1:nginx")
      end
    end

    context "provider_configs (informational only)" do
      it "produces :informational diffs that are never destroy/update/create" do
        desired_state = build_desired_state(provider_configs: { "aws-prod" => { "credentials" => "vault://..." } })

        result = described_class.diff!(account: account, desired_state: desired_state)
        info = result.diffs.find { |d| d.kind == "provider_config" }

        expect(info.change).to eq(:informational)
        expect(info.desired[:note]).to include("managed via UI")
      end
    end

    context "pools (declarative instance topology → InstancePool)" do
      let(:template) { create(:system_node_template, account: account, name: "web-server", node_platform: platform) }
      let!(:existing_pool) do
        ::System::InstancePool.create!(account: account, name: "web-warm", node_template: template,
                                       target_size: 3, min_size: 1, max_size: 5)
      end

      it "detects a target_size change as an update" do
        desired_state = build_desired_state(
          pools: { "web-warm" => { "name" => "web-warm", "target_size" => 5, "min_size" => 1,
                                   "max_size" => 5, "lifecycle_class" => "ephemeral", "status" => "active" } }
        )

        result = described_class.diff!(account: account, desired_state: desired_state)
        diff = result.diffs.find { |d| d.kind == "pool" }
        expect(diff.change).to eq(:update)
        expect(diff.current["target_size"]).to eq(3)
        expect(diff.desired["target_size"]).to eq(5)
      end

      it "detects a new pool" do
        desired_state = build_desired_state(
          pools: {
            "web-warm" => { "name" => "web-warm", "target_size" => 3, "min_size" => 1, "max_size" => 5,
                            "lifecycle_class" => "ephemeral", "status" => "active" },
            "api-warm" => { "name" => "api-warm", "node_template" => "web-server", "target_size" => 2,
                            "min_size" => 0, "max_size" => 4, "lifecycle_class" => "ephemeral", "status" => "active" }
          }
        )

        result = described_class.diff!(account: account, desired_state: desired_state)
        create_diff = result.diffs.find { |d| d.kind == "pool" && d.change == :create }
        expect(create_diff).to be_present
        expect(create_diff.name).to eq("api-warm")
      end

      it "flags a live pool absent from desired as a destroy candidate" do
        desired_state = build_desired_state(pools: {})

        result = described_class.diff!(account: account, desired_state: desired_state)
        destroy_diff = result.diffs.find { |d| d.kind == "pool" && d.change == :destroy }
        expect(destroy_diff).to be_present
        expect(destroy_diff.name).to eq("web-warm")
      end

      it "produces no diff when current matches desired" do
        desired_state = build_desired_state(
          pools: { "web-warm" => { "name" => "web-warm", "target_size" => 3, "min_size" => 1,
                                   "max_size" => 5, "lifecycle_class" => "ephemeral", "status" => "active" } }
        )

        result = described_class.diff!(account: account, desired_state: desired_state)
        expect(result.diffs.select { |d| d.kind == "pool" }).to be_empty
      end
    end

    context "platforms (PlatformDeployment.target_replicas bridge)" do
      let!(:existing_deployment) do
        create(:system_platform_deployment, account: account, name: "hub-api",
                                             service_role: "api", target_replicas: 1)
      end

      it "detects a target_replicas change as an update" do
        desired_state = build_desired_state(
          platforms: { "hub-api" => { "name" => "hub-api", "service_role" => "api", "target_replicas" => 3 } }
        )

        result = described_class.diff!(account: account, desired_state: desired_state)
        diff = result.diffs.find { |d| d.kind == "platform" }
        expect(diff.change).to eq(:update)
        expect(diff.current["target_replicas"]).to eq(1)
        expect(diff.desired["target_replicas"]).to eq(3)
      end

      it "detects a new platform deployment" do
        desired_state = build_desired_state(
          platforms: {
            "hub-api"    => { "name" => "hub-api", "service_role" => "api", "target_replicas" => 1 },
            "hub-worker" => { "name" => "hub-worker", "service_role" => "worker", "target_replicas" => 2 }
          }
        )

        result = described_class.diff!(account: account, desired_state: desired_state)
        create_diff = result.diffs.find { |d| d.kind == "platform" && d.change == :create }
        expect(create_diff).to be_present
        expect(create_diff.name).to eq("hub-worker")
      end

      it "flags a live deployment absent from desired as a destroy candidate" do
        desired_state = build_desired_state(platforms: {})

        result = described_class.diff!(account: account, desired_state: desired_state)
        destroy_diff = result.diffs.find { |d| d.kind == "platform" && d.change == :destroy }
        expect(destroy_diff).to be_present
        expect(destroy_diff.name).to eq("hub-api")
      end
    end

    context "graceful failure" do
      it "returns ok:false with a captured error message" do
        # Force an internal error by passing nil account
        result = described_class.diff!(account: nil,
                                       desired_state: build_desired_state)
        expect(result.ok?).to be false
        expect(result.error).to be_present
      end
    end

    context "per-account isolation" do
      let(:other_account) { create(:account) }
      let!(:foreign_template) { create(:system_node_template, account: other_account, name: "foreign-web") }

      it "does not surface other accounts' rows in destroy candidates" do
        desired_state = build_desired_state(templates: {})

        result = described_class.diff!(account: account, desired_state: desired_state)

        # Only the test's own account-scoped template should appear; the
        # foreign-account template must not surface in our diffs.
        template_diffs = result.diffs.select { |d| d.kind == "template" }
        expect(template_diffs.map(&:name)).not_to include("foreign-web")
      end
    end
  end

  def build_desired_state(templates: {}, modules: {}, assignments: {}, provider_configs: {}, pools: {}, platforms: {})
    System::Gitops::DesiredStateParser::DesiredState.new(
      templates: templates, modules: modules, assignments: assignments,
      provider_configs: provider_configs, pools: pools, platforms: platforms
    )
  end
end
