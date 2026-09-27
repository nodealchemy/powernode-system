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
end
