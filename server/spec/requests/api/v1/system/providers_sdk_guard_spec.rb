# frozen_string_literal: true

require "rails_helper"

# IMP-0ddfd8a60032 (APO-7 follow-up) — after APO-7 (4c04e50f) and its
# credential-POST follow-up (35b7ab3e), the MCP and credential writers refused
# a provider type whose adapter SDK gem is not bundled in this build. The REST
# operator CRUD controller was not one of them: #create built a
# System::Provider straight from provider_params, and #update permitted
# :provider_type on an existing row, so an operator — or an agent over REST —
# could still mint (or convert a row into) an aws/gcp/openstack provider that
# every adapter call then refuses.
#
# TWO doors, not one. #create mints the inoperable row; #update REACHES the
# same state from a row that was operable when it was written. A guard on
# #create alone leaves the second spelling open, so both are driven here, and
# each is mutated separately.
#
# The oracle is the ROW (and, for #update, the persisted COLUMN), never the
# status code: this repo has shipped refusals that rendered a message from an
# action body while the write still landed
# (see MEMORY: render-in-action-body-does-not-halt).
#
# hide_const / stub_const rather than the ambient bundle: the `provider-specs`
# CI lane (scripts/test-provider-gems.sh) layers aws-sdk-ec2 and fog-openstack
# onto the core bundle, so an example that ASSUMED the constant is undefined
# would flip red there. Driving the predicate in BOTH directions is also what
# stops this being a spec that passes because nothing happened.
RSpec.describe "Api::V1::System::Providers SDK guard (IMP-0ddfd8a60032)", type: :request do
  let(:account)     { create(:account) }
  let(:create_user) { user_with_permissions("system.providers.create", account: account) }
  let(:update_user) { user_with_permissions("system.providers.update", account: account) }

  def post_provider(provider_type, user: create_user)
    post "/api/v1/system/providers",
         params: {
           provider: {
             name: "sdk-guard-#{provider_type}-#{SecureRandom.hex(4)}",
             provider_type: provider_type,
             enabled: true,
             config: {}
           }
         }.to_json,
         headers: auth_headers_for(user).merge("Content-Type" => "application/json")
  end

  def patch_provider(provider, provider_type, user: update_user)
    patch "/api/v1/system/providers/#{provider.id}",
          params: { provider: { provider_type: provider_type } }.to_json,
          headers: auth_headers_for(user).merge("Content-Type" => "application/json")
  end

  describe "POST /api/v1/system/providers" do
    it "writes no row for a registered type whose SDK gem is not bundled" do
      hide_const("Aws::EC2::Client")

      expect { post_provider("aws") }
        .not_to change { ::System::Provider.where(account: account, provider_type: "aws").count }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to include("aws-sdk-ec2")
      expect(response.parsed_body["error"]).to match(/not operable/i)
    end

    it "refuses openstack with a message naming its gem" do
      hide_const("Fog::OpenStack::Compute")

      expect { post_provider("openstack") }
        .not_to change { ::System::Provider.where(account: account, provider_type: "openstack").count }

      expect(response.parsed_body["error"]).to include("fog-openstack")
    end

    it "still creates a provider whose adapter needs no SDK gem" do
      expect { post_provider("proxmox") }
        .to change { ::System::Provider.where(account: account, provider_type: "proxmox").count }.by(1)

      expect(response.status).to be_between(200, 299)
    end

    # Discriminating, not a blanket 422: types with no registry adapter at all
    # are outside the predicate by design, exactly as at the five other doors.
    it "still creates a type that has no registry adapter at all" do
      expect { post_provider("digitalocean") }
        .to change { ::System::Provider.where(account: account, provider_type: "digitalocean").count }.by(1)
    end

    it "creates the aws provider once the SDK constant is defined" do
      stub_const("Aws::EC2::Client", Class.new { def initialize(*, **); end })

      expect { post_provider("aws") }
        .to change { ::System::Provider.where(account: account, provider_type: "aws").count }.by(1)
    end
  end

  describe "PATCH /api/v1/system/providers/:id" do
    let!(:provider) do
      create(:system_provider, account: account, provider_type: "proxmox",
                               name: "convertible-#{SecureRandom.hex(4)}")
    end

    it "does not convert an operable row into an inoperable one" do
      hide_const("Aws::EC2::Client")

      expect { patch_provider(provider, "aws") }
        .not_to change { provider.reload.provider_type }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to include("aws-sdk-ec2")
    end

    it "still applies an update that does not touch provider_type" do
      hide_const("Aws::EC2::Client")
      renamed = "Renamed-#{SecureRandom.hex(4)}"

      patch "/api/v1/system/providers/#{provider.id}",
            params: { provider: { name: renamed } }.to_json,
            headers: auth_headers_for(update_user).merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:ok)
      expect(provider.reload.name).to eq(renamed)
    end

    # Pins the #provider_type_changing? clause of the #update guard. Without
    # that clause the guard refuses ANY update to a row that is ALREADY of an
    # inoperable type, because the operator UI resends provider_type unchanged
    # on every edit (frontend ProviderFormModal builds submitData with
    # `provider_type: formData.provider_type` unconditionally and posts it on
    # the edit path). That would remove the one remediation the refusal is
    # meant to leave open — disabling or renaming the stranded row. The other
    # PATCH examples all survive dropping the clause; this one reds.
    it "still edits a row that is ALREADY of an inoperable type when the type does not move" do
      hide_const("Aws::EC2::Client")
      stranded = create(:system_provider, account: account, provider_type: "aws",
                                          enabled: true,
                                          name: "stranded-#{SecureRandom.hex(4)}")

      patch "/api/v1/system/providers/#{stranded.id}",
            params: { provider: { provider_type: "aws", enabled: false } }.to_json,
            headers: auth_headers_for(update_user).merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:ok)
      expect(stranded.reload.enabled).to be(false)
      expect(stranded.provider_type).to eq("aws")
    end

    it "converts the row once the SDK constant is defined" do
      stub_const("Aws::EC2::Client", Class.new { def initialize(*, **); end })

      expect { patch_provider(provider, "aws") }
        .to change { provider.reload.provider_type }.from("proxmox").to("aws")
    end
  end
end
