# frozen_string_literal: true

require "rails_helper"

# IMP-0ddfd8a60032 (APO-7 follow-up) —
# System::CredentialValidationService resolved the adapter class through
# Registry.adapter_for (which is deliberately SDK-blind: it answers "is this
# type mapped", not "can it run") and then called .with_credentials on it with
# no availability predicate at all. It survived only because the registry now
# hides inoperable types UPSTREAM of every caller that reaches this service —
# an argument from a neighbour's guard, not from its own, and one that expires
# the moment a caller arrives with a provider_type of its own (which is exactly
# what the REST credential POST does).
#
# What the missing predicate costs, measured rather than assumed: the probe
# does NOT crash. AwsProvider#authenticate? reaches for Aws::STS::Client
# (aws-sdk-core, which IS bundled) and never touches Aws::EC2::Client, so with
# aws-sdk-ec2 absent and real keys supplied the service answers
# [true, "credentials valid"] — a green verdict, and a persisted credential,
# for a provider type every adapter call in this build then refuses. The
# failure is a FALSE PASS at onboarding time, not an exception; that is why
# the guard belongs here and not in a rescue.
#
# The oracle is that the ADAPTER IS NEVER CONSTRUCTED, not merely that the
# tuple is false: a refusal that still instantiates has not moved the failure
# earlier, it has only relabelled it.
RSpec.describe System::CredentialValidationService, "SDK availability guard" do
  # provider_type => [adapter class, SDK constant path, gem name]. A local,
  # not a constant: a spec-level constant leaks onto Object.
  sdk_backed = {
    "aws"       => ["System::Providers::AwsProvider", "Aws::EC2::Client", "aws-sdk-ec2"],
    "gcp"       => ["System::Providers::GcpProvider",
                    "Google::Cloud::Compute::V1::Instances::Rest::Client", "google-cloud-compute"],
    "openstack" => ["System::Providers::OpenStackProvider", "Fog::OpenStack::Compute", "fog-openstack"]
  }.freeze

  sdk_backed.each do |type, (class_name, const_path, gem_name)|
    context "with the #{type} adapter and #{const_path} absent" do
      let(:provider) { instance_double("System::Provider", provider_type: type) }

      before { hide_const(const_path) }

      it "refuses with a message naming #{gem_name}" do
        ok, message = described_class.test(provider: provider, credentials: { "any" => "value" })

        expect(ok).to be false
        expect(message).to include(gem_name)
        expect(message).to match(/not operable/i)
      end

      it "never constructs the adapter" do
        expect(class_name.constantize).not_to receive(:with_credentials)

        described_class.test(provider: provider, credentials: { "any" => "value" })
      end
    end
  end

  # The mirror direction. Without it, deleting the guard's second clause
  # (`sdk_available?`) would leave every example above green for the wrong
  # reason — a service that refuses everything.
  context "with the aws adapter and its SDK constant defined" do
    let(:provider) { instance_double("System::Provider", provider_type: "aws") }

    before { stub_const("Aws::EC2::Client", Class.new { def initialize(*, **); end }) }

    it "reaches the adapter's credential probe" do
      adapter = instance_double("System::Providers::AwsProvider",
                                authenticate?: true, last_authentication_error: nil)
      expect(::System::Providers::AwsProvider)
        .to receive(:with_credentials).and_return(adapter)

      ok, = described_class.test(provider: provider, credentials: { "access_key_id" => "AKIA" })
      expect(ok).to be true
    end
  end

  # A registered type whose adapter declares no gem must not be caught by the
  # predicate — the guard has to discriminate, not blanket-refuse.
  context "with an adapter that needs no SDK gem" do
    let(:provider) { instance_double("System::Provider", provider_type: "azure") }

    it "reaches the adapter's credential probe" do
      adapter = instance_double("System::Providers::AzureProvider",
                                authenticate?: false, last_authentication_error: "bad tenant")
      expect(::System::Providers::AzureProvider)
        .to receive(:with_credentials).and_return(adapter)

      ok, message = described_class.test(provider: provider, credentials: {})
      expect(ok).to be false
      expect(message).to eq("bad tenant")
    end
  end

  # Unmapped types keep their existing verdict: the guard sits after the
  # adapter_for lookup and must not swallow the "no adapter" branch.
  context "with a provider type that has no adapter at all" do
    let(:provider) { instance_double("System::Provider", provider_type: "unicorn_cloud") }

    it "still answers 'no adapter'" do
      ok, message = described_class.test(provider: provider, credentials: {})
      expect(ok).to be false
      expect(message).to match(/no adapter/i)
    end
  end
end
