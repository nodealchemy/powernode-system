# frozen_string_literal: true

require "rails_helper"

# IMP-384a74c79f86 (APO-7) — the registry advertised aws / gcp / openstack
# unconditionally while none of aws-sdk-ec2, google-cloud-compute or
# fog-openstack is in the core bundle. `system_create_provider(type: "aws")`
# therefore SUCCEEDED and the first real call raised a bare NameError, which
# reaches an MCP caller as -32603 rather than as a refusal it can act on.
#
# The oracle is the AVAILABILITY PREDICATE, not the exception class: each
# example drives the SDK constant in BOTH directions (hidden -> adapter
# withdrawn and refused, present -> advertised and constructed) so removing
# the guard turns the "hidden" half red instead of leaving a spec that passes
# because nothing happened.
#
# The absent direction uses hide_const rather than relying on the ambient
# bundle. That is load-bearing: `scripts/test-provider-gems.sh` (the
# `provider-specs` CI job) layers aws-sdk-ec2 + fog-openstack onto the core
# bundle, so a spec that ASSUMED the constants were undefined would be an
# environment assertion that flips red in that lane. hide_const/stub_const
# make every example hold in both lanes.
RSpec.describe "Provider SDK availability guard (IMP-384a74c79f86)" do
  let(:registry) { ::System::Providers::Registry }

  # provider_type => [adapter class, SDK constant path, gem name].
  # A local, NOT a constant: a spec-level constant leaks onto Object and
  # collides with the next file that names it.
  sdk_backed = {
    "aws"       => ["System::Providers::AwsProvider", "Aws::EC2::Client", "aws-sdk-ec2"],
    "gcp"       => ["System::Providers::GcpProvider",
                    "Google::Cloud::Compute::V1::Instances::Rest::Client", "google-cloud-compute"],
    "openstack" => ["System::Providers::OpenStackProvider", "Fog::OpenStack::Compute", "fog-openstack"]
  }.freeze

  # Withdraw every optional SDK constant. A no-op where the gem is already
  # absent (the default bundle), and the point of the spec where it is not.
  # `sdk_backed` is a block-local, invisible inside a `def` body, so it is
  # passed in rather than closed over.
  def hide_all_provider_sdks(sdk_backed)
    sdk_backed.each_value { |(_klass, const_path, _gem)| hide_const(const_path) }
  end

  describe "adapter class predicates" do
    sdk_backed.each do |type, (class_name, const_path, gem_name)|
      it "#{type}: names the missing gem and reports the SDK unavailable" do
        hide_const(const_path)
        klass = class_name.constantize
        expect(klass.required_sdk_gem).to eq(gem_name)
        expect(klass.sdk_available?).to be(false)
      end

      it "#{type}: reports the SDK available once #{const_path} is defined" do
        stub_const(const_path, Class.new { def initialize(*, **); end })
        expect(class_name.constantize.sdk_available?).to be(true)
      end
    end

    it "treats an adapter that needs no SDK gem as always available" do
      expect(::System::Providers::MockProvider.required_sdk_gem).to be_nil
      expect(::System::Providers::MockProvider.sdk_available?).to be(true)
      expect(::System::Providers::ProxmoxProvider.sdk_available?).to be(true)
      expect(::System::Providers::AzureProvider.sdk_available?).to be(true)
    end
  end

  describe ".available_providers" do
    it "hides every adapter whose SDK constant is undefined" do
      hide_all_provider_sdks(sdk_backed)
      expect(registry.available_providers).not_to include("aws", "gcp", "openstack")
    end

    it "still advertises the adapters that run on the core bundle" do
      hide_all_provider_sdks(sdk_backed)
      expect(registry.available_providers).to include("mock", "proxmox", "local_qemu", "azure")
    end

    it "shows an adapter again once its SDK constant is defined" do
      stub_const("Aws::EC2::Client", Class.new { def initialize(*, **); end })
      expect(registry.available_providers).to include("aws")
    end

    it "keeps every registered type visible through .registered_providers" do
      hide_all_provider_sdks(sdk_backed)
      expect(registry.registered_providers).to include("aws", "gcp", "openstack")
    end
  end

  describe ".for" do
    let(:account)  { create(:account) }
    let(:provider) { create(:system_provider, account: account, provider_type: "aws") }
    let(:region)   { create(:system_provider_region, account: account, provider: provider) }
    let(:connection) do
      create(:system_provider_connection,
        account: account, provider: provider, status: "connected",
        access_key: "test-key", secret_key: "test-secret")
    end

    before { hide_const("Aws::EC2::Client") }

    it "refuses with an error naming the missing gem" do
      expect {
        registry.for(connection, region: region)
      }.to raise_error(::System::Providers::Registry::ProviderSdkMissingError, /aws-sdk-ec2/)
    end

    it "refuses with an UnknownProviderError subclass so with_adapter converts it to a result" do
      result = registry.with_adapter(connection: connection, region: region) { :never_reached }

      expect(result).to be_a(::System::Runtime::Result)
      expect(result.success?).to be(false)
      expect(result.error.to_s).to include("aws-sdk-ec2")
    end

    it "builds the adapter once the SDK constant is defined" do
      stub_const("Aws::EC2::Client", Class.new { def initialize(*, **); end })
      expect(registry.for(connection, region: region)).to be_a(::System::Providers::AwsProvider)
    end
  end

  describe "system_create_provider" do
    let(:account) { create(:account) }
    let(:user)    { create(:user, account: account, permissions: %w[system.providers.create]) }
    let(:tool)    { ::Ai::Tools::SystemFleetTool.new(account: account, user: user) }

    # Force account/user/tool construction OUTSIDE the `change` blocks below:
    # the account factory itself seeds System::Provider rows, so a lazily
    # built `tool` would move the count and mask what create_provider did.
    before do
      hide_all_provider_sdks(sdk_backed)
      tool
    end

    def create_provider(provider_type)
      tool.execute(params: {
        action: "system_create_provider",
        name: "guard-#{provider_type}-#{SecureRandom.hex(4)}",
        provider_type: provider_type
      })
    end

    # The row is the oracle: this repo has shipped refusals that rendered a
    # message while the write still landed.
    it "refuses aws with a result naming the gem and writes no Provider row" do
      result = nil
      expect { result = create_provider("aws") }.not_to change(::System::Provider, :count)

      expect(result[:success]).to be(false)
      expect(result[:error]).to include("aws-sdk-ec2")
      expect(result[:error]).to match(/not operable/i)
    end

    it "refuses openstack with a result naming the gem" do
      result = create_provider("openstack")
      expect(result[:success]).to be(false)
      expect(result[:error]).to include("fog-openstack")
    end

    it "still creates a provider whose adapter needs no SDK gem" do
      result = nil
      expect { result = create_provider("proxmox") }.to change(::System::Provider, :count).by(1)
      expect(result[:success]).to be(true)
    end

    it "creates the aws provider once the SDK constant is defined" do
      stub_const("Aws::EC2::Client", Class.new { def initialize(*, **); end })
      result = nil
      expect { result = create_provider("aws") }.to change(::System::Provider, :count).by(1)
      expect(result[:success]).to be(true)
    end
  end

  # The REST front door was guarded first; this is its MCP twin. An agent
  # holding system.connections.create reaches create_provider_connection
  # directly, so a refusal that lives only in the controller is bypassable by
  # exactly the caller class the guard exists for. Oracle is the ROW again.
  describe "system_create_provider_connection" do
    let(:account) { create(:account) }
    let(:user)    { create(:user, account: account, permissions: %w[system.connections.create]) }
    let(:tool)    { ::Ai::Tools::SystemFleetTool.new(account: account, user: user) }

    let(:aws_provider)     { create(:system_provider, account: account, provider_type: "aws") }
    let(:proxmox_provider) { create(:system_provider, account: account, provider_type: "proxmox") }

    before do
      hide_all_provider_sdks(sdk_backed)
      tool
    end

    def create_connection(provider)
      tool.execute(params: {
        action: "system_create_provider_connection",
        provider_id: provider.id,
        name: "guard-conn-#{SecureRandom.hex(4)}"
      })
    end

    it "refuses an aws connection with a result naming the gem and writes no row" do
      provider = aws_provider
      result = nil
      expect { result = create_connection(provider) }.not_to change(::System::ProviderConnection, :count)

      expect(result[:success]).to be(false)
      expect(result[:error]).to include("aws-sdk-ec2")
    end

    it "still creates a connection for a provider whose adapter needs no SDK gem" do
      provider = proxmox_provider
      result = nil
      expect { result = create_connection(provider) }.to change(::System::ProviderConnection, :count).by(1)
      expect(result[:success]).to be(true)
    end

    it "creates the aws connection once the SDK constant is defined" do
      provider = aws_provider
      stub_const("Aws::EC2::Client", Class.new { def initialize(*, **); end })

      result = nil
      expect { result = create_connection(provider) }.to change(::System::ProviderConnection, :count).by(1)
      expect(result[:success]).to be(true)
    end
  end

  describe "the system_create_provider tool description" do
    it "states which provider types are operable in this build" do
      hide_all_provider_sdks(sdk_backed)
      description = ::Ai::Tools::SystemFleetTool.action_definitions
                      .dig("system_create_provider", :description).to_s

      expect(description).to include("proxmox")
      expect(description).not_to match(/\baws\b/)
    end
  end
end
