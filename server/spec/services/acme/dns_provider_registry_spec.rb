# frozen_string_literal: true

require "rails_helper"

RSpec.describe Acme::DnsProviderRegistry, type: :service do
  describe ".supported?" do
    it "is true for every provider in PROVIDERS" do
      described_class::PROVIDERS.each_key do |slug|
        expect(described_class.supported?(slug)).to be true
      end
    end

    it "is false for unknown slugs" do
      expect(described_class.supported?("megacorp-dns")).to be false
    end

    it "is symbol/string indifferent" do
      expect(described_class.supported?(:cloudflare)).to be true
    end
  end

  describe ".lookup" do
    it "returns the provider hash for a known slug" do
      info = described_class.lookup("cloudflare")
      expect(info[:lego_id]).to eq("cloudflare")
      expect(info[:required_fields]).to eq(%w[api_token])
    end

    it "raises UnknownProviderError for unsupported slugs" do
      expect { described_class.lookup("megacorp-dns") }
        .to raise_error(described_class::UnknownProviderError, /Unknown DNS provider/)
    end
  end

  describe ".lego_id_for" do
    it "returns the Lego provider id" do
      expect(described_class.lego_id_for("cloudflare")).to eq("cloudflare")
      expect(described_class.lego_id_for("gcloud")).to eq("gcloud")
    end
  end

  describe ".validate_credential_shape!" do
    it "passes for a complete cloudflare credential" do
      expect {
        described_class.validate_credential_shape!(
          slug: "cloudflare",
          credentials_hash: { "api_token" => "secret" }
        )
      }.not_to raise_error
    end

    it "passes when credentials use symbol keys" do
      expect {
        described_class.validate_credential_shape!(
          slug: "cloudflare",
          credentials_hash: { api_token: "secret" }
        )
      }.not_to raise_error
    end

    it "raises when a required field is missing" do
      expect {
        described_class.validate_credential_shape!(
          slug: "route53",
          credentials_hash: { "access_key_id" => "AKIA…" }  # missing secret_access_key + region
        )
      }.to raise_error(described_class::ProviderError, /missing required fields/)
    end

    it "raises when a required field is empty string" do
      expect {
        described_class.validate_credential_shape!(
          slug: "cloudflare",
          credentials_hash: { "api_token" => "" }
        )
      }.to raise_error(described_class::ProviderError, /missing/)
    end

    it "raises UnknownProviderError for unsupported provider" do
      expect {
        described_class.validate_credential_shape!(
          slug: "bogus",
          credentials_hash: {}
        )
      }.to raise_error(described_class::UnknownProviderError)
    end
  end

  describe ".all_slugs" do
    it "lists every known provider" do
      expect(described_class.all_slugs).to match_array(
        %w[cloudflare route53 gcloud digitalocean hetzner porkbun ovh]
      )
    end
  end
end
