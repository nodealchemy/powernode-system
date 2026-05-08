# frozen_string_literal: true

require "rails_helper"

# Self-Serve Hardening Plan M2 — slice A (cloud cred wiring).
#
# CredentialValidationService is the orchestrator the BYOC onboarding flow
# calls (POST /api/v1/system/provider_credentials/test) before persisting
# credentials. Each branch below stubs the underlying provider client at
# the HTTP boundary (WebMock for Faraday/Net::HTTP, instance doubles for
# SDK clients) so no real network calls are made.
RSpec.describe System::CredentialValidationService do
  describe ".test" do
    context "when the provider type has no adapter" do
      let(:provider) { instance_double("System::Provider", provider_type: "unicorn_cloud") }

      it "returns [false, message] without raising" do
        ok, message = described_class.test(provider: provider, credentials: {})
        expect(ok).to be false
        expect(message).to match(/no adapter/i)
        expect(message).to include("unicorn_cloud")
      end
    end

    # ------------------------------------------------------------------
    # AWS
    # ------------------------------------------------------------------
    context "with the AWS adapter" do
      let(:provider) { instance_double("System::Provider", provider_type: "aws") }
      let(:sts_client) { instance_double("Aws::STS::Client") }

      let(:valid_credentials) do
        {
          "access_key_id" => "AKIATESTKEY",
          "secret_access_key" => "SECRET-XYZ",
          "region" => "us-east-1"
        }
      end

      before do
        allow(::Aws::STS::Client).to receive(:new).and_return(sts_client)
      end

      it "returns [true, ...] when STS#get_caller_identity succeeds" do
        allow(sts_client).to receive(:get_caller_identity).and_return(double(arn: "arn:aws:iam::1:user/test"))

        ok, message = described_class.test(provider: provider, credentials: valid_credentials)

        expect(ok).to be true
        expect(message).to match(/valid/i)
      end

      it "returns [false, error] when STS rejects credentials" do
        allow(sts_client).to receive(:get_caller_identity).and_raise(StandardError.new("InvalidClientTokenId"))

        ok, message = described_class.test(provider: provider, credentials: valid_credentials)

        expect(ok).to be false
        expect(message).to include("InvalidClientTokenId")
      end

      it "returns [false, ...] when access_key_id is missing" do
        ok, message = described_class.test(
          provider: provider,
          credentials: { "secret_access_key" => "SECRET" }
        )

        expect(ok).to be false
        expect(message).to match(/access_key_id/)
      end

      it "returns [false, ...] when secret_access_key is missing" do
        ok, message = described_class.test(
          provider: provider,
          credentials: { "access_key_id" => "AKIA" }
        )

        expect(ok).to be false
        expect(message).to match(/secret_access_key/)
      end
    end

    # ------------------------------------------------------------------
    # Azure
    # ------------------------------------------------------------------
    context "with the Azure adapter" do
      let(:provider) { instance_double("System::Provider", provider_type: "azure") }
      let(:tenant)   { "test-tenant-uuid" }
      let(:token_url) { "https://login.microsoftonline.com/#{tenant}/oauth2/v2.0/token" }

      let(:valid_credentials) do
        {
          "tenant_id"     => tenant,
          "client_id"     => "client-id-uuid",
          "client_secret" => "client-secret-value"
        }
      end

      it "returns [true, ...] when Azure AD returns an access_token" do
        stub_request(:post, token_url)
          .to_return(
            status: 200,
            body: { access_token: "fake-bearer-token", expires_in: 3599 }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        ok, message = described_class.test(provider: provider, credentials: valid_credentials)

        expect(ok).to be true
        expect(message).to match(/valid/i)
      end

      it "returns [false, error] when Azure AD rejects the credentials" do
        stub_request(:post, token_url)
          .to_return(
            status: 401,
            body: { error: "invalid_client", error_description: "AADSTS7000215: Invalid client secret" }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        ok, message = described_class.test(provider: provider, credentials: valid_credentials)

        expect(ok).to be false
        expect(message).to include("AADSTS7000215")
      end

      it "returns [false, ...] when tenant_id is missing" do
        ok, message = described_class.test(
          provider: provider,
          credentials: { "client_id" => "id", "client_secret" => "secret" }
        )

        expect(ok).to be false
        expect(message).to match(/tenant_id/)
      end
    end

    # ------------------------------------------------------------------
    # GCP
    # ------------------------------------------------------------------
    context "with the GCP adapter" do
      let(:provider) { instance_double("System::Provider", provider_type: "gcp") }

      let(:rsa_key) { OpenSSL::PKey::RSA.new(2048) }
      let(:service_account_payload) do
        {
          "type" => "service_account",
          "project_id" => "test-project",
          "private_key_id" => "key-id",
          "private_key" => rsa_key.to_pem,
          "client_email" => "svc@test-project.iam.gserviceaccount.com",
          "client_id" => "12345",
          "token_uri" => "https://oauth2.googleapis.com/token"
        }
      end
      let(:service_account_json) { service_account_payload.to_json }

      it "returns [true, ...] when GCP returns an access_token" do
        stub_request(:post, "https://oauth2.googleapis.com/token")
          .to_return(
            status: 200,
            body: { access_token: "ya29.fake-token", expires_in: 3599, token_type: "Bearer" }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        ok, message = described_class.test(
          provider: provider,
          credentials: { "service_account_json" => service_account_json }
        )

        expect(ok).to be true
        expect(message).to match(/valid/i)
      end

      it "returns [false, error] when token endpoint returns 400 invalid_grant" do
        stub_request(:post, "https://oauth2.googleapis.com/token")
          .to_return(
            status: 400,
            body: { error: "invalid_grant", error_description: "Invalid JWT signature" }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        ok, message = described_class.test(
          provider: provider,
          credentials: { "service_account_json" => service_account_json }
        )

        expect(ok).to be false
        expect(message).to include("Invalid JWT signature")
      end

      it "returns [false, ...] when service_account_json is malformed" do
        ok, message = described_class.test(
          provider: provider,
          credentials: { "service_account_json" => "{not-json" }
        )

        expect(ok).to be false
        expect(message).to match(/service_account_json/i)
      end

      it "returns [false, ...] when service_account_json is missing required fields" do
        bad = service_account_payload.except("client_email", "private_key").to_json

        ok, message = described_class.test(
          provider: provider,
          credentials: { "service_account_json" => bad }
        )

        expect(ok).to be false
        expect(message).to match(/client_email/)
        expect(message).to match(/private_key/)
      end

      it "returns [false, ...] when service_account_json is empty" do
        ok, message = described_class.test(
          provider: provider,
          credentials: {}
        )

        expect(ok).to be false
        expect(message).to match(/service_account_json/)
      end
    end

    # ------------------------------------------------------------------
    # OpenStack
    # ------------------------------------------------------------------
    context "with the OpenStack adapter" do
      let(:provider) { instance_double("System::Provider", provider_type: "openstack") }
      let(:auth_url) { "https://os.example.com:5000/v3" }
      let(:token_endpoint) { "#{auth_url}/auth/tokens" }

      let(:valid_credentials) do
        {
          "auth_url"     => auth_url,
          "username"     => "admin",
          "password"     => "openstack-pw",
          "project_name" => "admin",
          "domain_name"  => "Default"
        }
      end

      it "returns [true, ...] when Keystone returns 201 Created" do
        stub_request(:post, token_endpoint)
          .to_return(status: 201, body: "{}", headers: { "X-Subject-Token" => "fake-keystone-token" })

        ok, message = described_class.test(provider: provider, credentials: valid_credentials)

        expect(ok).to be true
        expect(message).to match(/valid/i)
      end

      it "returns [false, error] on 401 Unauthorized from Keystone" do
        stub_request(:post, token_endpoint)
          .to_return(
            status: 401,
            body: { error: { code: 401, message: "The request you have made requires authentication." } }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        ok, message = described_class.test(
          provider: provider,
          credentials: valid_credentials.merge("password" => "wrong")
        )

        expect(ok).to be false
        expect(message).to match(/authentication/i)
      end

      it "tolerates trailing slash in auth_url" do
        stub_request(:post, token_endpoint)
          .to_return(status: 201, body: "{}")

        ok, _ = described_class.test(
          provider: provider,
          credentials: valid_credentials.merge("auth_url" => "#{auth_url}/")
        )

        expect(ok).to be true
      end

      it "returns [false, ...] when auth_url is missing" do
        ok, message = described_class.test(
          provider: provider,
          credentials: { "username" => "admin", "password" => "pw" }
        )

        expect(ok).to be false
        expect(message).to match(/auth_url/)
      end
    end

    # ------------------------------------------------------------------
    # LocalQemu
    # ------------------------------------------------------------------
    context "with the LocalQemu adapter" do
      let(:provider) { instance_double("System::Provider", provider_type: "local_qemu") }
      let(:runner)   { System::Providers::LocalQemu::RecorderRunner.new }

      before do
        System::Providers::LocalQemuProvider.runner = runner
      end

      after do
        System::Providers::LocalQemuProvider.reset_runner!
      end

      it "returns [true, ...] when libvirt is reachable" do
        runner.stub(:uri_check!, { ok: true, uri: "qemu:///system" })

        ok, message = described_class.test(
          provider: provider,
          credentials: { "libvirt_uri" => "qemu:///system" }
        )

        expect(ok).to be true
        expect(message).to match(/valid/i)
      end

      it "returns [false, error] when libvirt is unreachable" do
        runner.stub(:uri_check!, { ok: false, error: "Cannot connect to libvirt" })

        ok, message = described_class.test(
          provider: provider,
          credentials: { "libvirt_uri" => "qemu:///remote" }
        )

        expect(ok).to be false
        expect(message).to match(/cannot connect/i)
      end

      it "treats empty credentials as valid when libvirt is reachable (no creds required)" do
        runner.stub(:uri_check!, { ok: true, uri: "qemu:///system" })

        ok, _ = described_class.test(provider: provider, credentials: {})

        expect(ok).to be true
      end
    end
  end

  # ------------------------------------------------------------------
  # Adapter-level contracts (not via the service)
  # ------------------------------------------------------------------
  describe "adapter contract" do
    it "every BYOC-targeted adapter responds to .with_credentials and #authenticate?" do
      [
        System::Providers::AwsProvider,
        System::Providers::AzureProvider,
        System::Providers::GcpProvider,
        System::Providers::OpenStackProvider,
        System::Providers::LocalQemuProvider
      ].each do |klass|
        expect(klass).to respond_to(:with_credentials)
        instance = klass.with_credentials({})
        expect(instance).to respond_to(:authenticate?)
        expect(instance).to respond_to(:last_authentication_error)
      end
    end

    it "Registry.adapter_for resolves each registered provider type" do
      %w[aws azure gcp openstack local_qemu pro_cloud mock].each do |type|
        provider = instance_double("System::Provider", provider_type: type)
        expect(System::Providers::Registry.adapter_for(provider)).to be_a(Class)
      end
    end

    it "Registry.adapter_for returns nil for unknown provider types" do
      provider = instance_double("System::Provider", provider_type: "fake_provider_x")
      expect(System::Providers::Registry.adapter_for(provider)).to be_nil
    end

    it "Registry.adapter_for accepts a string identifier" do
      expect(System::Providers::Registry.adapter_for("aws")).to eq(System::Providers::AwsProvider)
    end
  end
end
