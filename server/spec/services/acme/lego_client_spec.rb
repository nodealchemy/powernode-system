# frozen_string_literal: true

require "rails_helper"

RSpec.describe Acme::LegoClient do
  subject(:client) { described_class.new }

  # build_provider_env is the provider-agnostic DNS env mapping that feeds the
  # bundled go-acme/lego binary for DNS-01 cert issuance. Tested directly (it is
  # private) — the env-var names are lego's documented provider vars.
  describe "#build_provider_env" do
    def env_for(provider, creds)
      client.send(:build_provider_env, provider, creds)
    end

    it "maps cloudflare api_token" do
      name, env = env_for("cloudflare", { "api_token" => "cf-tok" })
      expect(name).to eq("CLOUDFLARE_DNS_API_TOKEN")
      expect(env).to eq("CLOUDFLARE_DNS_API_TOKEN" => "cf-tok")
    end

    it "maps digitalocean auth_token" do
      _, env = env_for("digitalocean", { "auth_token" => "do-tok" })
      expect(env).to eq("DO_AUTH_TOKEN" => "do-tok")
    end

    it "maps hetzner api_token" do
      _, env = env_for("hetzner", { "api_token" => "hz-tok" })
      expect(env).to eq("HETZNER_API_KEY" => "hz-tok")
    end

    it "maps route53 access key + secret + region" do
      _, env = env_for("route53", { "access_key_id" => "AK", "secret_access_key" => "SK", "region" => "us-east-1" })
      expect(env).to eq(
        "AWS_ACCESS_KEY_ID" => "AK", "AWS_SECRET_ACCESS_KEY" => "SK", "AWS_REGION" => "us-east-1"
      )
    end

    it "maps gcloud service-account JSON + project" do
      _, env = env_for("gcloud", { "service_account_json" => "{}", "project_id" => "proj" })
      expect(env).to eq("GCE_SERVICE_ACCOUNT" => "{}", "GCE_PROJECT" => "proj")
    end

    it "maps porkbun api_key + secret_api_key" do
      _, env = env_for("porkbun", { "api_key" => "pk", "secret_api_key" => "sk" })
      expect(env).to eq("PORKBUN_API_KEY" => "pk", "PORKBUN_SECRET_API_KEY" => "sk")
    end

    it "maps ovh application credentials (all four vars)" do
      _, env = env_for("ovh", {
        "application_key" => "ak", "application_secret" => "as",
        "consumer_key" => "ck", "endpoint" => "ovh-eu"
      })
      expect(env).to eq(
        "OVH_APPLICATION_KEY" => "ak", "OVH_APPLICATION_SECRET" => "as",
        "OVH_CONSUMER_KEY" => "ck", "OVH_ENDPOINT" => "ovh-eu"
      )
    end

    it "tolerates symbol-keyed credentials" do
      _, env = env_for("route53", { access_key_id: "AK", secret_access_key: "SK", region: "us-east-1" })
      expect(env["AWS_ACCESS_KEY_ID"]).to eq("AK")
    end

    it "raises IntegrationError when a required credential is missing" do
      expect { env_for("route53", { "access_key_id" => "AK" }) }
        .to raise_error(described_class::IntegrationError, /secret_access_key/)
      expect { env_for("cloudflare", {}) }
        .to raise_error(described_class::IntegrationError, /api_token/)
    end

    it "raises for a truly unknown provider" do
      expect { env_for("unknowndns", { "api_token" => "x" }) }
        .to raise_error(described_class::IntegrationError, /not yet wired/)
    end
  end
end
