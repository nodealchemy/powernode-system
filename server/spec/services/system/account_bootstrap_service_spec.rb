# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::AccountBootstrapService do
  describe ".call(account)" do
    let!(:account) { create(:account) }

    it "returns nil when given nil" do
      expect(described_class.call(nil)).to be_nil
    end

    it "seeds a Pro Cloud provider for the account" do
      described_class.call(account)
      provider = ::System::Provider.find_by(account: account, name: "Pro Cloud")
      expect(provider).to be_present
      expect(provider.provider_type).to eq("pro_cloud")
      expect(provider.enabled).to be true
    end

    it "seeds the default regions (us-east, us-west)" do
      described_class.call(account)
      provider = ::System::Provider.find_by!(account: account, name: "Pro Cloud")

      region_codes = ::System::ProviderRegion.where(provider: provider).pluck(:region_code).sort
      expect(region_codes).to eq(%w[us-east-1 us-west-1])

      region_names = ::System::ProviderRegion.where(provider: provider).pluck(:name).sort
      expect(region_names).to eq(%w[us-east us-west])
    end

    it "seeds the default instance types (tiny, small, medium)" do
      described_class.call(account)
      provider = ::System::Provider.find_by!(account: account, name: "Pro Cloud")

      types = ::System::ProviderInstanceType.where(provider: provider).order(:vcpus, :memory_mb)
      expect(types.pluck(:name)).to eq(%w[tiny small medium])
      expect(types.pluck(:instance_type_code)).to eq(%w[vc2-1c-1gb vc2-1c-2gb vc2-2c-4gb])
      expect(types.first.hourly_price).to eq(0.007)
    end

    it "seeds the node-template catalog (architectures, platforms, modules, templates)" do
      described_class.call(account)

      expect(::System::NodeArchitecture.where(account: account).pluck(:name)).to match_array(%w[amd64 arm64])
      expect(::System::NodePlatform.where(account: account).pluck(:name)).to match_array(
        %w[ubuntu-24.04-lts ubuntu-24.04-rpi4 ubuntu-24.04-arm64-uefi]
      )
      expect(::System::NodeTemplate.where(account: account).pluck(:name)).to match_array(
        %w[base hardened web-apache web-nginx rpi4-base rpi4-hardened arm64-uefi-base]
      )
      expect(::System::NodeModule.where(account: account).pluck(:name)).to match_array(
        %w[system-base security-hardening chrony apache nginx rpi4-firmware]
      )
    end

    it "is idempotent — calling twice does not duplicate any rows" do
      described_class.call(account)

      counts = lambda do
        {
          provider:       ::System::Provider.where(account: account, name: "Pro Cloud").count,
          regions:        ::System::ProviderRegion.joins(:provider).where(system_providers: { account_id: account.id, name: "Pro Cloud" }).count,
          instance_types: ::System::ProviderInstanceType.joins(:provider).where(system_providers: { account_id: account.id, name: "Pro Cloud" }).count,
          architectures:  ::System::NodeArchitecture.where(account: account).count,
          platforms:      ::System::NodePlatform.where(account: account).count,
          modules:        ::System::NodeModule.where(account: account).count,
          templates:      ::System::NodeTemplate.where(account: account).count
        }
      end

      first = counts.call
      described_class.call(account)
      second = counts.call

      expect(second).to eq(first)
    end

    it "scopes catalog rows per-account (no cross-account bleed)" do
      other = create(:account)
      described_class.call(account)
      described_class.call(other)

      acct_template_ids = ::System::NodeTemplate.where(account: account).pluck(:id).sort
      other_template_ids = ::System::NodeTemplate.where(account: other).pluck(:id).sort
      expect(acct_template_ids & other_template_ids).to be_empty
    end
  end

  describe ".seed_templates_for(account, verbose:)" do
    let!(:account) { create(:account) }

    it "seeds templates without verbose output by default" do
      expect { described_class.seed_templates_for(account) }.not_to output.to_stdout
    end

    it "is idempotent across multiple invocations" do
      described_class.seed_templates_for(account)
      first_count = ::System::NodeTemplate.where(account: account).count
      described_class.seed_templates_for(account)
      expect(::System::NodeTemplate.where(account: account).count).to eq(first_count)
    end

    it "returns the modules hash keyed by name" do
      modules = described_class.seed_templates_for(account)
      expect(modules.keys).to match_array(
        %w[system-base security-hardening chrony apache nginx rpi4-firmware]
      )
      expect(modules["system-base"]).to be_a(::System::NodeModule)
    end
  end

  describe "Account.after_create_commit hook" do
    it "auto-bootstraps a new account synchronously" do
      account = create(:account)
      expect(::System::Provider.where(account: account, name: "Pro Cloud").count).to eq(1)
      expect(::System::ProviderRegion.joins(:provider).where(
        system_providers: { account_id: account.id, name: "Pro Cloud" }
      ).count).to eq(2)
      expect(::System::NodeTemplate.where(account: account).count).to eq(7)
    end

    it "does not roll back account creation when bootstrap fails" do
      allow(described_class).to receive(:call).and_raise(StandardError, "synthetic")
      expect { create(:account) }.not_to raise_error
      expect(::Account.count).to be > 0
    end
  end
end
