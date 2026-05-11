# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Operator API — Nodes apply_template", type: :request do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:user) do
    user_with_permissions("system.nodes.read", "system.modules.update", account: account)
  end
  let(:headers) { auth_headers_for(user).merge("Content-Type" => "application/json") }

  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }

  # Use unique module names so we don't collide with account-bootstrap seeds.
  let(:mod_a) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription",
           name: "apply-spec-a-#{SecureRandom.hex(3)}")
  end
  let(:mod_b) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription",
           name: "apply-spec-b-#{SecureRandom.hex(3)}")
  end
  let(:template) do
    create(:system_node_template, account: account, node_platform: platform,
           name: "apply-template-#{SecureRandom.hex(3)}")
  end
  let(:node) do
    create(:system_node, account: account, node_template: template,
           name: "node-#{SecureRandom.hex(3)}")
  end

  before do
    ::System::TemplateModule.create!(node_template: template, node_module: mod_a, priority: 10)
    ::System::TemplateModule.create!(node_template: template, node_module: mod_b, priority: 20)
  end

  describe "POST /api/v1/system/nodes/:id/apply_template" do
    it "materializes NodeModuleAssignment rows from the template's closure" do
      post "/api/v1/system/nodes/#{node.id}/apply_template", headers: headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body.dig("data", "created_count")).to eq(2)
      expect(node.node_module_assignments.count).to eq(2)
    end

    it "sets source_template_module_id on created assignments" do
      post "/api/v1/system/nodes/#{node.id}/apply_template", headers: headers

      template_module_for_a = template.template_modules.find_by(node_module: mod_a)
      assignment_a = node.node_module_assignments.find_by(node_module: mod_a)
      expect(assignment_a.source_template_module_id).to eq(template_module_for_a.id)
    end

    it "is idempotent — re-running produces 0 new assignments" do
      post "/api/v1/system/nodes/#{node.id}/apply_template", headers: headers
      post "/api/v1/system/nodes/#{node.id}/apply_template", headers: headers

      body = JSON.parse(response.body)
      expect(body.dig("data", "created_count")).to eq(0)
      expect(body.dig("data", "skipped_count")).to eq(2)
      expect(node.node_module_assignments.count).to eq(2)
    end

    context "dry_run" do
      it "previews without persisting" do
        post "/api/v1/system/nodes/#{node.id}/apply_template",
             params: { dry_run: true }.to_json, headers: headers

        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body.dig("data", "dry_run")).to be true
        expect(body.dig("data", "created_count")).to eq(2)
        expect(node.node_module_assignments.count).to eq(0)  # nothing persisted
      end
    end

    context "purge_stale" do
      it "removes template-derived assignments when the source TemplateModule is disabled" do
        # First apply: creates assignments for both modules.
        post "/api/v1/system/nodes/#{node.id}/apply_template", headers: headers
        expect(node.node_module_assignments.count).to eq(2)

        # Disable mod_b's TemplateModule (keeps the row alive so the FK
        # nullify doesn't blow away source_template_module_id — purge
        # relies on the back-reference to identify template-derived rows).
        template.template_modules.find_by(node_module: mod_b).update!(enabled: false)

        post "/api/v1/system/nodes/#{node.id}/apply_template",
             params: { purge_stale: true }.to_json, headers: headers

        body = JSON.parse(response.body)
        expect(body.dig("data", "purged_count")).to eq(1)
        expect(node.node_module_assignments.pluck(:node_module_id)).to contain_exactly(mod_a.id)
      end

      it "leaves hand-authored assignments (NULL source_template_module_id) untouched" do
        manual_mod = create(:system_node_module, account: account, node_platform: platform,
                            category: category, variety: "subscription",
                            name: "apply-spec-manual-#{SecureRandom.hex(3)}")
        hand_authored = node.node_module_assignments.create!(node_module: manual_mod, enabled: true)
        expect(hand_authored.source_template_module_id).to be_nil

        post "/api/v1/system/nodes/#{node.id}/apply_template",
             params: { purge_stale: true }.to_json, headers: headers

        expect(node.node_module_assignments.exists?(id: hand_authored.id)).to be true
      end
    end

    # Note: the defensive `return failure("node has no node_template")` guard
    # in TemplateApplyService cannot be exercised via the controller — Node
    # enforces node_template_id NOT NULL at both the model (belongs_to without
    # optional) and DB level. The guard stays as defense in depth for future
    # schema changes.

    context "cross-account isolation" do
      it "404s for a node in another account" do
        foreign_template = create(:system_node_template, account: other_account,
                                  node_platform: create(:system_node_platform, account: other_account),
                                  name: "foreign-template")
        foreign_node = create(:system_node, account: other_account, node_template: foreign_template,
                              name: "foreign-node")

        post "/api/v1/system/nodes/#{foreign_node.id}/apply_template", headers: headers

        expect(response).to have_http_status(:not_found)
      end
    end

    context "permissions" do
      it "403s when the user lacks system.modules.update" do
        viewer = user_with_permissions("system.nodes.read", account: account)
        viewer_headers = auth_headers_for(viewer).merge("Content-Type" => "application/json")

        post "/api/v1/system/nodes/#{node.id}/apply_template", headers: viewer_headers

        expect(response).to have_http_status(:forbidden)
      end
    end
  end
end
