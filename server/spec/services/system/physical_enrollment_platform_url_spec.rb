# frozen_string_literal: true

require "rails_helper"

# The claim-by-ID boot config is FLASHED ONTO PHYSICAL MEDIA. That single fact
# drives every assertion here: a wrong value is not discovered in a test run or a
# code review, it is discovered at a site, on a device that has already been
# imaged and shipped.
#
# The service used to fabricate "https://platform.local" in production and
# "http://localhost:3000" otherwise. Measured on the live planes 2026-07-26:
# ops-hub (production) would have emitted SERVER=https://platform.local into every
# identity.cfg — a host that does not exist — and dev would have emitted localhost.
RSpec.describe System::PhysicalEnrollmentService do
  before { allow(::SiteSetting).to receive(:get).and_return(nil) }

  describe ".platform_url" do
    it "reads the same SiteSetting the VM enrollment path uses" do
      allow(::SiteSetting).to receive(:get).with(described_class::PLATFORM_URL_SETTING)
                                           .and_return("https://ops-hub.ipnode.us")
      expect(described_class.platform_url).to eq("https://ops-hub.ipnode.us")
    end

    # Two sources of truth for "where do devices enroll" is how a fleet ends up
    # split across planes, so this must be the SAME key EnrollmentSeed reads.
    it "uses the key name EnrollmentSeed reads, not a second physical-only key" do
      expect(described_class::PLATFORM_URL_SETTING).to eq("system.ci_builder.enroll_platform_url")
    end

    it "falls back to the environment when no setting is stored" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("POWERNODE_PLATFORM_URL").and_return("https://env.example")
      expect(described_class.platform_url).to eq("https://env.example")
    end

    it "prefers the SiteSetting over the environment" do
      allow(::SiteSetting).to receive(:get).with(described_class::PLATFORM_URL_SETTING)
                                           .and_return("https://setting.example")
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("POWERNODE_PLATFORM_URL").and_return("https://env.example")
      expect(described_class.platform_url).to eq("https://setting.example")
    end

    # THE regression. Anything non-nil here gets written verbatim onto a boot
    # partition, so "no answer" must stay "no answer" rather than becoming a
    # confident-looking wrong one.
    it "returns nil rather than inventing a host when nothing is configured" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("POWERNODE_PLATFORM_URL").and_return(nil)
      expect(described_class.platform_url).to be_nil
    end

    it "never returns the fabricated defaults it used to" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("POWERNODE_PLATFORM_URL").and_return(nil)
      %w[https://platform.local http://localhost:3000].each do |fabrication|
        expect(described_class.platform_url).not_to eq(fabrication)
      end
    end

    it "degrades to the environment rather than raising if the settings store is unavailable" do
      allow(::SiteSetting).to receive(:get).and_raise(StandardError, "db down")
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("POWERNODE_PLATFORM_URL").and_return("https://env.example")
      expect(described_class.platform_url).to eq("https://env.example")
    end
  end

  describe ".private_ca?" do
    # ops-hub is self-signed (verified live: subject == issuer == CN=ops-hub.ipnode.us,
    # openssl verify code 18). A device using the stock public-root image cannot
    # verify it, so the CA must travel on the BOOT partition.
    it "is true when an enrollment CA chain is configured" do
      allow(::SiteSetting).to receive(:get).with(described_class::ENROLL_CA_SETTING)
                                           .and_return("-----BEGIN CERTIFICATE-----\nMII...\n")
      expect(described_class.private_ca?).to be true
    end

    it "is false when the platform relies on public roots" do
      expect(described_class.private_ca?).to be false
    end

    it "is false rather than raising when the settings store is unavailable" do
      allow(::SiteSetting).to receive(:get).and_raise(StandardError, "db down")
      expect(described_class.private_ca?).to be false
    end
  end
end
