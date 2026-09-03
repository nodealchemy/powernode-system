# frozen_string_literal: true

require "rails_helper"

# IMP-4c825848bb79 — the APO-7 refusal predicate
#
#   registry.supported?(type) && !registry.sdk_available?(type)
#     -> registry.sdk_missing_message(type)
#
# was hand-rolled at six writer doors after IMP-0ddfd8a60032. Each copy could
# drift on its own (one `.to_s`, one blank check, one missing clause) and the
# census spec's GUARD_TOKENS had to recognise every spelling. This is the ONE
# spelling: Registry.sdk_refusal(type) answers the refusal text, or nil when
# the door may write. The doors keep only the door-shaped part (422 vs
# error_result vs [false, msg]).
#
# The absent direction uses hide_const rather than relying on the ambient
# bundle — `scripts/test-provider-gems.sh` layers aws-sdk-ec2 onto the core
# bundle in the provider-specs lane, so an assumption that the constant is
# undefined flips red there.
RSpec.describe System::Providers::Registry, ".sdk_refusal (IMP-4c825848bb79)" do
  describe "a registered type whose SDK gem is absent" do
    before { hide_const("Aws::EC2::Client") }

    it "answers the same operator-actionable text as .sdk_missing_message" do
      refusal = described_class.sdk_refusal("aws")

      expect(refusal).to eq(described_class.sdk_missing_message("aws"))
      expect(refusal).to include("aws-sdk-ec2")
      expect(refusal).to match(/not operable/i)
    end

    it "normalises a symbol the way every door normalises with .to_s" do
      expect(described_class.sdk_refusal(:aws)).to include("aws-sdk-ec2")
    end
  end

  describe "a registered type whose SDK gem is present" do
    before { stub_const("Aws::EC2::Client", Class.new { def initialize(*, **); end }) }

    it "answers nil so the door writes" do
      expect(described_class.sdk_refusal("aws")).to be_nil
    end
  end

  it "answers nil for an adapter that needs no SDK gem" do
    expect(described_class.sdk_refusal("proxmox")).to be_nil
    expect(described_class.sdk_refusal("mock")).to be_nil
  end

  # `supported?` gates the predicate at every door: types with no registry
  # adapter at all (digitalocean/linode/vultr/custom) are outside it by design.
  it "answers nil for a type the registry does not map" do
    expect(described_class.sdk_refusal("vultr")).to be_nil
    expect(described_class.sdk_refusal("unicorn_cloud")).to be_nil
  end

  # ProviderConnectionsController passes `provider&.provider_type`, which is
  # nil when the request names no provider; the door must not refuse on nil.
  it "answers nil for nil and blank" do
    expect(described_class.sdk_refusal(nil)).to be_nil
    expect(described_class.sdk_refusal("")).to be_nil
  end
end
