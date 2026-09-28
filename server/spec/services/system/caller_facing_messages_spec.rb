# frozen_string_literal: true

require "rails_helper"

# IMP-7e549d7506cf (Route 2 remediation, round-2 review Finding 3) — the
# ProviderError sentinel oracles in volume_management_service_spec.rb and
# instance_control_service_spec.rb only ever raise the base
# Providers::BaseProvider::ProviderError class, so they exercise the `else`
# (GENERIC) branch and would pass just as well against a naive
# `for_provider_error` that always returned GENERIC — they cannot see
# whether the class-keyed mapping this review round asked for actually
# exists. This file drives every branch directly.
RSpec.describe System::CallerFacingMessages do
  describe ".for_provider_error" do
    # Each subclass carries a sentinel in its #message; the assertion that
    # matters is that the STATIC phrase is returned regardless — never the
    # exception's own message, which is exactly the raw-text leak this
    # module exists to close (base_provider.rb's own `raise ProviderError,
    # error.message`, pro_cloud_provider.rb's "pro_cloud upstream error:
    # \#{error.message}").
    {
      System::Providers::BaseProvider::AuthenticationError => "provider authentication failed",
      System::Providers::BaseProvider::RateLimitError => "provider rate limit exceeded",
      System::Providers::BaseProvider::QuotaExceededError => "provider quota exceeded",
      System::Providers::BaseProvider::ResourceNotFoundError => "provider resource not found"
    }.each do |klass, expected_phrase|
      it "classifies #{klass} as #{expected_phrase.inspect}, never its own message" do
        sentinel = "SENTINEL_CFM_#{klass.name.demodulize}_#{SecureRandom.hex(8)}"
        exception = klass.new(sentinel)

        result = described_class.for_provider_error(exception)

        expect(result).to eq(expected_phrase)
        expect(result).not_to include(sentinel)
      end
    end

    it "falls back to the generic message for the base ProviderError class" do
      sentinel = "SENTINEL_CFM_BASE_#{SecureRandom.hex(8)}"
      exception = System::Providers::BaseProvider::ProviderError.new(sentinel)

      result = described_class.for_provider_error(exception)

      expect(result).to eq(described_class::GENERIC)
      expect(result).not_to include(sentinel)
    end

    it "falls back to the generic message for an undeclared ProviderError subclass (future-proofing via ===)" do
      undeclared = Class.new(System::Providers::BaseProvider::ProviderError)
      sentinel = "SENTINEL_CFM_UNDECLARED_#{SecureRandom.hex(8)}"

      result = described_class.for_provider_error(undeclared.new(sentinel))

      expect(result).to eq(described_class::GENERIC)
      expect(result).not_to include(sentinel)
    end
  end

  # IMP-88ad4adbf97d — the defense-in-depth backstop for a provider adapter
  # that returns a raw client-error message in a result hash instead of
  # raising (the shape for_provider_error does not see at all, since it only
  # classifies an EXCEPTION). Unlike for_provider_error's exact class
  # dispatch, this has no shared exception hierarchy to key on across
  # vendors — it recognizes the STRUCTURAL SHAPE of the leak instead
  # (host:port), which is what a driver's own connection-failure text
  # actually carries.
  describe ".scrub_adapter_leak" do
    it "scrubs an IPv4:port pair and logs the raw message" do
      sentinel = "SENTINEL_CFM_LEAK_IPV4_#{SecureRandom.hex(8)}"
      raw = "connection failed: 192.0.2.10:8006 (#{sentinel})"
      expect(Rails.logger).to receive(:error).with(a_string_including(raw))

      result = described_class.scrub_adapter_leak(raw, context: "spec")

      expect(result).to eq(described_class::GENERIC)
      expect(result).not_to include(sentinel)
    end

    it "scrubs a hostname:port pair" do
      raw = "PVE connection failed: Failed to open TCP connection to pve1.internal:8006"
      allow(Rails.logger).to receive(:error)

      expect(described_class.scrub_adapter_leak(raw)).to eq(described_class::GENERIC)
    end

    it "scrubs a bracketed IPv6:port pair" do
      raw = "connection failed: [fe80::1]:8006"
      allow(Rails.logger).to receive(:error)

      expect(described_class.scrub_adapter_leak(raw)).to eq(described_class::GENERIC)
    end

    it "passes through a message with no host:port shape unchanged" do
      expect(Rails.logger).not_to receive(:error)

      expect(described_class.scrub_adapter_leak("guest is locked")).to eq("guest is locked")
    end

    it "does not false-positive on an ordinary time or ratio in an otherwise-safe message" do
      expect(Rails.logger).not_to receive(:error)

      expect(described_class.scrub_adapter_leak("retry scheduled for 12:34")).to eq("retry scheduled for 12:34")
      expect(described_class.scrub_adapter_leak("odds are 3:20 against")).to eq("odds are 3:20 against")
    end

    it "passes through the already-static class-keyed phrases untouched" do
      allow(Rails.logger).to receive(:error)

      expect(described_class.scrub_adapter_leak(described_class::GENERIC)).to eq(described_class::GENERIC)
      expect(described_class.scrub_adapter_leak(described_class.for_provider_error(
        System::Providers::BaseProvider::AuthenticationError.new("x")
      ))).to eq("provider authentication failed")
    end

    it "handles a nil or non-string message without raising" do
      expect(described_class.scrub_adapter_leak(nil)).to be_nil
    end
  end
end
