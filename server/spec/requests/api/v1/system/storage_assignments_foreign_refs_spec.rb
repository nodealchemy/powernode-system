# frozen_string_literal: true

require "rails_helper"

# review2 S-1 (HIGH): the operator storage-assignment door resolves every id it
# is handed — node_instance_id, file_storage_id, sdwan_network_id,
# sdwan_virtual_ip_id — inside the caller's account.
#
# Before: #update permitted all four with no account scope, so account A could
# re-point its own assignment at account B's node and storage (200); B's node
# agent then listed the assignment and the reconciler ran against B's storage.
#
# After, per id, on update, create and bulk_create:
#   * a foreign id is a 404 and the row is untouched;
#   * that 404 is byte-identical to the one a made-up id gets, so the door is
#     not an oracle for "does this id exist in some other account";
#   * the account's own id still works (update re-points; create is not
#     refused as not-found — it separately answers the pre-existing
#     "Service user can't be blank" 422, an open offer this spec does not
#     depend on).
RSpec.describe "Storage assignment refs resolve inside the caller's account", type: :request do
  let(:account)       { create(:account) }
  let(:other_account) { create(:account) }
  let(:user) do
    user_with_permissions("system.storage.assignments.read", "system.storage.assignments.update",
                          "system.storage.assignments.create", account: account)
  end
  let(:headers) { auth_headers_for(user).merge("Content-Type" => "application/json") }

  let(:my_instance) { create(:system_node_instance, account: account) }
  let(:my_storage)  { create(:file_storage, :node_mountable, account: account) }
  let!(:own) do
    create(:system_storage_assignment, account: account, node_instance: my_instance, file_storage_id: my_storage.id)
  end

  ref_fields = %w[node_instance_id file_storage_id sdwan_network_id sdwan_virtual_ip_id].freeze

  # One valid id per field in the given account.
  def ids_in(owner)
    network = create(:sdwan_network, account: owner)
    {
      "node_instance_id" => create(:system_node_instance, account: owner).id,
      "file_storage_id" => create(:file_storage, :node_mountable, account: owner).id,
      "sdwan_network_id" => network.id,
      "sdwan_virtual_ip_id" => create(:sdwan_virtual_ip, network: network).id
    }
  end

  def patch_own(attrs)
    patch "/api/v1/system/storage_assignments/#{own.id}", params: { assignment: attrs }.to_json, headers: headers
  end

  def post_one(attrs)
    post "/api/v1/system/storage_assignments", params: { assignment: attrs }.to_json, headers: headers
  end

  def post_bulk(rows)
    post "/api/v1/system/storage_assignments", params: { assignments: rows }.to_json, headers: headers
  end

  def body = JSON.parse(response.body)

  ref_fields.each do |field|
    describe field do
      let(:foreign_id) { ids_in(other_account).fetch(field) }
      let(:own_id)     { ids_in(account).fetch(field) }
      let(:base_attrs) { { "file_storage_id" => my_storage.id, "node_instance_id" => my_instance.id, "mount_path" => "/mnt/s1" } }

      it "update: another account's id is a 404 and the row is untouched" do
        before = own.reload.attributes.slice(*ref_fields)

        patch_own(field => foreign_id)

        expect(response).to have_http_status(:not_found)
        expect(own.reload.attributes.slice(*ref_fields)).to eq(before)
      end

      it "update: the 404 is identical to the one a nonexistent id gets" do
        patch_own(field => foreign_id)
        foreign_body = body

        patch_own(field => SecureRandom.uuid)
        expect(response).to have_http_status(:not_found)
        expect(body).to eq(foreign_body)
      end

      it "update: the account's own id still re-points the row (the other arm)" do
        patch_own(field => own_id)

        expect(response).to have_http_status(:ok)
        expect(own.reload.public_send(field)).to eq(own_id)
      end

      it "create: another account's id is a 404 and no row is written" do
        expect { post_one(base_attrs.merge(field => foreign_id)) }
          .not_to change(System::StorageAssignment, :count)
        expect(response).to have_http_status(:not_found)
      end

      it "create: the account's own id is not refused as not found (the other arm)" do
        post_one(base_attrs.merge(field => own_id))
        expect(response).not_to have_http_status(:not_found)
      end

      it "bulk_create: another account's id is reported as not found and nothing is written for it" do
        expect { post_bulk([ base_attrs.merge(field => foreign_id) ]) }
          .not_to change(System::StorageAssignment, :count)

        errors = body.dig("data", "errors")
        expect(body.dig("data", "created")).to eq([])
        expect(errors.size).to eq(1)
        expect(errors.first).to include("index" => 0, "status" => 404)

        foreign_entry = errors.first
        post_bulk([ base_attrs.merge(field => SecureRandom.uuid) ])
        expect(body.dig("data", "errors").first).to eq(foreign_entry)
      end
    end
  end
end
