# frozen_string_literal: true

require "rails_helper"

# IMP-384a74c79f86 (APO-7) — POST /provider_connections happily created a
# connection to an aws/gcp/openstack provider whose SDK gem is not bundled.
# The row looked healthy; POST .../test and every provisioning call then
# raised a bare NameError from inside the adapter.
#
# The oracle is the ROW, not the status: this repo has shipped a guard that
# rendered a refusal from an action body while the write still landed, so the
# refusal example asserts the connection count did not move. The mirror
# example (SDK constant stubbed present) proves the guard is discriminating
# rather than a blanket 422.
RSpec.describe "Api::V1::System::ProviderConnections SDK guard", type: :request do
  let(:account) { create(:account) }
  let(:user) do
    user_with_permissions("system.connections.create", "system.connections.read", account: account)
  end

  let(:aws_provider)     { create(:system_provider, account: account, provider_type: "aws") }
  let(:proxmox_provider) { create(:system_provider, account: account, provider_type: "proxmox") }

  def post_create(provider)
    post "/api/v1/system/provider_connections",
         params: { provider_connection: { name: "conn-#{SecureRandom.hex(4)}", provider_id: provider.id } }.to_json,
         headers: auth_headers_for(user).merge("Content-Type" => "application/json")
  end

  # hide_const, not the ambient bundle: scripts/test-provider-gems.sh layers
  # aws-sdk-ec2 on for the `provider-specs` CI lane, where an assumption that
  # the constant is undefined would flip this red.
  it "refuses a connection to a provider whose SDK gem is not bundled, and writes no row" do
    hide_const("Aws::EC2::Client")

    expect { post_create(aws_provider) }.not_to change(::System::ProviderConnection, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]).to include("aws-sdk-ec2")
  end

  it "creates the connection for a provider whose adapter needs no SDK gem" do
    expect { post_create(proxmox_provider) }.to change(::System::ProviderConnection, :count).by(1)
    expect(response).to have_http_status(:created)
  end

  it "creates the aws connection once the SDK constant is defined" do
    stub_const("Aws::EC2::Client", Class.new { def initialize(*, **); end })

    expect { post_create(aws_provider) }.to change(::System::ProviderConnection, :count).by(1)
    expect(response).to have_http_status(:created)
  end

  # #update permits :provider_id, so a guard that lives only in #create is
  # undone by one PATCH — the invariant is a property of the CONNECTION
  # ("its provider's adapter can run here"), not of the create action.
  # Oracle is the persisted provider_id, not the status.
  describe "PATCH re-pointing an existing connection" do
    let(:updater) do
      user_with_permissions(
        "system.connections.create", "system.connections.read", "system.connections.update",
        account: account
      )
    end

    let(:connection) do
      create(:system_provider_connection, account: account, provider: proxmox_provider)
    end

    def patch_provider(target_provider)
      patch "/api/v1/system/provider_connections/#{connection.id}",
            params: { provider_connection: { provider_id: target_provider.id } }.to_json,
            headers: auth_headers_for(updater).merge("Content-Type" => "application/json")
    end

    it "refuses to re-point a connection at a provider whose SDK gem is missing" do
      hide_const("Aws::EC2::Client")
      original_provider_id = connection.provider_id

      patch_provider(aws_provider)

      expect(connection.reload.provider_id).to eq(original_provider_id)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to include("aws-sdk-ec2")
    end

    it "allows re-pointing at a provider whose adapter needs no SDK gem" do
      other = create(:system_provider, account: account, provider_type: "proxmox")

      patch_provider(other)

      expect(connection.reload.provider_id).to eq(other.id)
      expect(response).to have_http_status(:ok)
    end
  end
end
