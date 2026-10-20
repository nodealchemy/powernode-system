# frozen_string_literal: true

require "rails_helper"

# IMP-5c6a03c3b335 (D4) - operator-issued, single-use enrolment keys bound to
# one NodeInstance. The plaintext is returned ONCE, in the create response, and
# is recoverable afterwards only through the gated MCP reveal verb.
RSpec.describe "Api::V1::System::NodeInstanceBootstrapTokens", type: :request do
  let(:account)  { create(:account) }
  let(:template) { create(:system_node_template, account: account) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, node: node, account: account, status: "pending") }

  let(:manager) { user_with_permissions("system.instances.control", account: account) }
  let(:reader)  { user_with_permissions("system.node_instances.read", account: account) }

  let(:base_path) { "/api/v1/system/nodes/#{node.id}/node_instances/#{instance.id}/bootstrap_tokens" }

  def post_create(body = {}, user: manager, path: base_path)
    post path, params: body.to_json, headers: auth_headers_for(user)
  end

  def data = JSON.parse(response.body)["data"]

  describe "POST (create)" do
    it "mints an operator_key bound to the instance and returns the plaintext once" do
      expect { post_create }.to change { System::BootstrapToken.count }.by(1)

      expect(response).to have_http_status(:created)
      plaintext = data["token"]
      expect(plaintext).to be_present

      row = System::BootstrapToken.find(data["bootstrap_token"]["id"])
      expect(row.purpose).to eq("operator_key")
      expect(row.node_instance_id).to eq(instance.id)
      expect(row.node_id).to eq(node.id)
      expect(row.intended_subject).to eq(instance.id)
      expect(row.created_by_id).to eq(manager.id)
      expect(row.token_hash).to eq(Digest::SHA256.hexdigest(plaintext))
      expect(row.expires_at).to be_within(1.minute).of(24.hours.from_now)
      expect(System::BootstrapToken.find_active_by_plaintext(plaintext)).to eq(row)
    end

    it "never puts the plaintext or digest in the serialized token" do
      post_create
      row = System::BootstrapToken.last
      serialized = data["bootstrap_token"]

      expect(serialized.keys).to match_array(
        %w[id purpose node_instance_id expires_at consumed_at consumed_from_ip revoked_at created_by created_at]
      )
      expect(serialized.to_json).not_to include(data["token"])
      expect(serialized.to_json).not_to include(row.token_hash)
      expect(serialized["created_by"]).to include("id" => manager.id)
    end

    it "accepts a ttl_seconds inside 1h..7d" do
      post_create({ ttl_seconds: 2.hours.to_i })
      expect(response).to have_http_status(:created)
      expect(System::BootstrapToken.last.expires_at).to be_within(1.minute).of(2.hours.from_now)

      post_create({ ttl_seconds: 7.days.to_i })
      expect(response).to have_http_status(:created)
    end

    it "rejects a ttl below 1h or above 7d without minting" do
      [ 59.minutes.to_i, 7.days.to_i + 1, 0, -5, "soon" ].each do |bad|
        expect { post_create({ ttl_seconds: bad }) }.not_to change { System::BootstrapToken.count }
        expect(response).to have_http_status(:unprocessable_content)
      end
    end

    it "writes an issued audit row that names the actor and holds no secret" do
      post_create
      row = AuditLog.where(action: "system.bootstrap_token.issued").order(:created_at).last
      expect(row.user_id).to eq(manager.id)
      expect(row.metadata.to_json).not_to include(data["token"])
    end

    it "does not log the plaintext" do
      io = StringIO.new
      logger = ActiveSupport::Logger.new(io)
      original = Rails.logger
      Rails.logger = logger
      begin
        post_create
      ensure
        Rails.logger = original
      end
      expect(io.string).not_to include(data["token"])
    end

    it "refuses with 409 when the instance has been claimed" do
      instance.update_columns(claimed_at: Time.current, claim_code: "ABCD-1234")
      expect { post_create }.not_to change { System::BootstrapToken.count }
      expect(response).to have_http_status(:conflict)
      expect(response.body).not_to include("token\":\"")
    end

    it "refuses with 409 when the instance is running" do
      instance.update_columns(status: "running")
      expect { post_create }.not_to change { System::BootstrapToken.count }
      expect(response).to have_http_status(:conflict)
    end

    it "denies a caller without system.instances.control" do
      expect { post_create({}, user: reader) }.not_to change { System::BootstrapToken.count }
      expect(response).to have_http_status(:forbidden)
    end

    it "denies on permission, not on role" do
      admin_role_only = create(:user, account: account, permissions: [])
      post_create({}, user: admin_role_only)
      expect(response).to have_http_status(:forbidden)
    end

    it "404s for another account's node and instance" do
      other_account = create(:account)
      other_template = create(:system_node_template, account: other_account)
      other_node = create(:system_node, account: other_account, node_template: other_template)
      other_instance = create(:system_node_instance, node: other_node, account: other_account, status: "pending")
      path = "/api/v1/system/nodes/#{other_node.id}/node_instances/#{other_instance.id}/bootstrap_tokens"

      expect { post_create({}, path: path) }.not_to change { System::BootstrapToken.count }
      expect(response).to have_http_status(:not_found)

      # own node, foreign instance id
      post_create({}, path: "/api/v1/system/nodes/#{node.id}/node_instances/#{other_instance.id}/bootstrap_tokens")
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET (index)" do
    let!(:minted) { System::BootstrapToken.issue!(node: node, node_instance: instance, intended_subject: instance.id,
                                                  purpose: "operator_key", created_by: manager) }

    it "lists the instance's tokens without any secret" do
      plaintext = minted.last
      get base_path, headers: auth_headers_for(manager)

      expect(response).to have_http_status(:ok)
      listed = JSON.parse(response.body)["data"]["bootstrap_tokens"]
      expect(listed.map { |t| t["id"] }).to eq([ minted.first.id ])
      expect(response.body).not_to include(plaintext)
      expect(response.body).not_to include(minted.first.token_hash)
      expect(response.body).not_to include("sealed")
    end

    it "does not list another instance's tokens" do
      other = create(:system_node_instance, node: node, account: account, status: "pending")
      System::BootstrapToken.issue!(node: node, node_instance: other, intended_subject: other.id,
                                    purpose: "operator_key", created_by: manager)
      get base_path, headers: auth_headers_for(manager)
      expect(JSON.parse(response.body)["data"]["bootstrap_tokens"].size).to eq(1)
    end

    it "denies without system.instances.control" do
      get base_path, headers: auth_headers_for(reader)
      expect(response).to have_http_status(:forbidden)
    end

    it "404s cross-account" do
      other_account = create(:account)
      outsider = user_with_permissions("system.instances.control", account: other_account)
      get base_path, headers: auth_headers_for(outsider)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE (revoke)" do
    let!(:minted) { System::BootstrapToken.issue!(node: node, node_instance: instance, intended_subject: instance.id,
                                                  purpose: "operator_key", created_by: manager) }
    let(:token) { minted.first }

    it "revokes with the current user, purges the sealed copy and audits" do
      delete "#{base_path}/#{token.id}", headers: auth_headers_for(manager)

      expect(response).to have_http_status(:ok)
      expect(token.reload.revoked_at).to be_present
      expect(token.revoked_by_id).to eq(manager.id)
      expect(token.sealed_plaintext).to be_nil
      expect(data["bootstrap_token"]["revoked_at"]).to be_present
      expect(AuditLog.where(action: "system.bootstrap_token.revoked", resource_id: token.id).count).to eq(1)
    end

    it "409s for an already-consumed token" do
      token.consume!
      delete "#{base_path}/#{token.id}", headers: auth_headers_for(manager)
      expect(response).to have_http_status(:conflict)
    end

    it "404s for a token on another instance" do
      other = create(:system_node_instance, node: node, account: account, status: "pending")
      foreign, _ = System::BootstrapToken.issue!(node: node, node_instance: other, intended_subject: other.id,
                                                 purpose: "operator_key", created_by: manager)
      delete "#{base_path}/#{foreign.id}", headers: auth_headers_for(manager)
      expect(response).to have_http_status(:not_found)
      expect(foreign.reload.revoked_at).to be_nil
    end

    it "denies without system.instances.control" do
      delete "#{base_path}/#{token.id}", headers: auth_headers_for(reader)
      expect(response).to have_http_status(:forbidden)
      expect(token.reload.revoked_at).to be_nil
    end

    it "404s cross-account" do
      other_account = create(:account)
      outsider = user_with_permissions("system.instances.control", account: other_account)
      delete "#{base_path}/#{token.id}", headers: auth_headers_for(outsider)
      expect(response).to have_http_status(:not_found)
    end
  end
end
