# frozen_string_literal: true

require "rails_helper"

# IMP-efc4b9c2d96b (APO-7 follow-up) — after APO-7 (4c04e50f) four doors
# refuse a provider type whose adapter SDK gem is not bundled here
# (system_create_provider, provider_connections#create/#update,
# system_create_provider_connection). ProviderCredentialsController's
# auto-create-on-first-cred path did not: it minted a System::Provider row
# for ANY type in System::Provider::PROVIDER_TYPES, so a credential POST was
# a second way to obtain exactly the inoperable row those four refuse. It was
# not the last one: REST ProvidersController#create/#update permits
# :provider_type with no registry guard and is still open (out of scope here,
# tracked separately).
#
# The oracle is the ROW, not the status: this repo has shipped a guard that
# rendered a refusal from an action body while the write still landed. The
# mirror examples (SDK constant stubbed present, and a gem-free adapter)
# prove the guard is discriminating rather than a blanket 422.
RSpec.describe "Api::V1::System::ProviderCredentials SDK guard", type: :request do
  let(:account) { create(:account) }
  let(:create_user) { user_with_permissions("system.providers.create", account: account) }
  let(:test_user)   { user_with_permissions("system.providers.test",   account: account) }

  let(:valid_creds) { { "api_key" => "byoc-test-#{SecureRandom.hex(6)}" } }

  # Slice A's validator may or may not be present in this branch; route
  # through a known stub so we verify the controller's guard, not the
  # (potentially missing) downstream service.
  def with_credential_validator(result)
    service = Class.new do
      def self.test(provider:, credentials:); end
    end
    stub_const("System::CredentialValidationService", service)
    allow(service).to receive(:test).and_return(result)
    service
  end

  def post_credential(slug, user: create_user)
    post "/api/v1/system/provider_credentials",
         params: { provider_id: slug, credentials: valid_creds }.to_json,
         headers: auth_headers_for(user).merge("Content-Type" => "application/json")
  end

  # hide_const, not the ambient bundle: scripts/test-provider-gems.sh layers
  # aws-sdk-ec2 on for the `provider-specs` CI lane, where an assumption that
  # the constant is undefined would flip this red.
  describe "POST /api/v1/system/provider_credentials" do
    it "mints no System::Provider row for a type whose SDK gem is not bundled" do
      hide_const("Aws::EC2::Client")
      with_credential_validator([ true, nil ])

      expect { post_credential("aws") }
        .not_to change { ::System::Provider.where(account: account, provider_type: "aws").count }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to include("aws-sdk-ec2")
    end

    it "writes no credential either when the provider type is refused" do
      hide_const("Aws::EC2::Client")
      with_credential_validator([ true, nil ])

      expect { post_credential("aws") }
        .not_to change { ::System::ProviderCredential.where(account: account).count }
    end

    it "mints the row for a type whose adapter needs no SDK gem" do
      with_credential_validator([ true, nil ])

      expect { post_credential("proxmox") }
        .to change { ::System::Provider.where(account: account, provider_type: "proxmox").count }.by(1)

      expect(response).to have_http_status(:created)
    end

    it "mints the aws row once the SDK constant is defined" do
      stub_const("Aws::EC2::Client", Class.new { def initialize(*, **); end })
      with_credential_validator([ true, nil ])

      expect { post_credential("aws") }
        .to change { ::System::Provider.where(account: account, provider_type: "aws").count }.by(1)

      expect(response).to have_http_status(:created)
    end

    # The refusal renders from a before_action, so it must not run ahead of
    # authorization: a caller without system.providers.create would otherwise
    # learn which adapter gems this build ships.
    it "answers 403, not the gem-naming refusal, when the caller lacks the permission" do
      hide_const("Aws::EC2::Client")
      no_perms = user_with_permissions(account: account)

      post_credential("aws", user: no_perms)

      expect(response).to have_http_status(:forbidden)
      expect(response.body).not_to include("aws-sdk-ec2")
    end

    # Boundary: the guard is on the MINT. A provider row that already exists
    # is the other four doors' problem (they refuse connections to it); a
    # credential attached to it allocates nothing on its own.
    it "still attaches a credential to an already-existing provider of that type" do
      hide_const("Aws::EC2::Client")
      with_credential_validator([ true, nil ])
      existing = create(:system_provider, account: account, provider_type: "aws", name: "AWS Prod")

      expect { post_credential("aws") }
        .to change { ::System::ProviderCredential.where(account: account).count }.by(1)

      expect(response).to have_http_status(:created)
      cred = ::System::ProviderCredential.find(response.parsed_body["data"]["provider_credential"]["id"])
      expect(cred.provider_id).to eq(existing.id)
    end
  end

  # #test resolves a provider through the same before_action, so it mints
  # rows too. Its documented contract is "always 200, the boolean carries
  # the verdict" — the refusal keeps that shape rather than 422-ing the
  # wizard's test button.
  describe "POST /api/v1/system/provider_credentials/test" do
    it "mints no System::Provider row for a type whose SDK gem is not bundled" do
      hide_const("Aws::EC2::Client")
      with_credential_validator([ true, nil ])

      expect {
        post "/api/v1/system/provider_credentials/test",
             params: { provider_id: "aws", credentials: valid_creds }.to_json,
             headers: auth_headers_for(test_user).merge("Content-Type" => "application/json")
      }.not_to change { ::System::Provider.where(account: account, provider_type: "aws").count }

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["valid"]).to eq(false)
      expect(data["error"]).to include("aws-sdk-ec2")
    end
  end
end
