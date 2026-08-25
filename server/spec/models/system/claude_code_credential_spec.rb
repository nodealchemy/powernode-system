# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::ClaudeCodeCredential, type: :model do
  describe "associations" do
    it "belongs to a node_instance and delegates account through it" do
      credential = create(:system_claude_code_credential)
      expect(credential.node_instance).to be_a(System::NodeInstance)
      expect(credential.account).to eq(credential.node_instance.account)
      expect(credential.account_id).to eq(credential.node_instance.account_id)
    end
  end

  describe "validations" do
    it "enforces one credential per node_instance" do
      instance = create(:system_node_instance)
      create(:system_claude_code_credential, node_instance: instance)
      duplicate = build(:system_claude_code_credential, node_instance: instance)

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:node_instance_id]).to be_present
    end
  end

  describe "VaultCredential concern wiring" do
    it "uses the claude_code_api_key credential type" do
      expect(described_class.vault_credential_type).to eq("claude_code_api_key")
    end

    it "aliases vault_path to the vault_path_credentials column" do
      credential = build(:system_claude_code_credential)
      credential.vault_path = "system/claude-code-api-keys/some-id"
      expect(credential.vault_path_credentials).to eq("system/claude-code-api-keys/some-id")
    end

    it "encrypts the api key at rest via encrypted_credentials on the Vault-less DB fallback path" do
      credential = create(:system_claude_code_credential)
      plaintext = "sk-ant-fake-api-key"

      result = credential.store_in_vault("api_key" => plaintext)

      expect(result[:stored_in]).to eq(:database)
      expect(credential.reload.encrypted_credentials).to be_present
      expect(credential.encrypted_credentials).not_to include(plaintext)
      expect(credential.credentials["api_key"]).to eq(plaintext)
    end
  end

  describe "credential_kind" do
    it "defaults to api_key and exposes both kinds" do
      expect(described_class::KINDS).to eq(%w[api_key oauth])
      expect(build(:system_claude_code_credential).credential_kind).to eq("api_key")
    end

    it "rejects an unknown kind" do
      credential = build(:system_claude_code_credential, credential_kind: "magic")
      expect(credential).not_to be_valid
      expect(credential.errors[:credential_kind]).to be_present
    end

    it "maps each kind to its own vault credential type so rotations stay independent" do
      expect(build(:system_claude_code_credential, credential_kind: "api_key").vault_kind_type)
        .to eq(:claude_code_api_key)
      expect(build(:system_claude_code_credential, credential_kind: "oauth").vault_kind_type)
        .to eq(:claude_code_oauth)
    end
  end

  describe "provider_type" do
    it "defaults to anthropic so every pre-existing row keeps its meaning" do
      expect(build(:system_claude_code_credential).provider_type).to eq("anthropic")
    end

    it "rejects a provider no NodeModule fetches over the node_api" do
      credential = build(:system_claude_code_credential, provider_type: "openai")
      expect(credential).not_to be_valid
      expect(credential.errors[:provider_type]).to be_present
    end

    it "allows one credential per instance PER PROVIDER" do
      instance = create(:system_node_instance)
      create(:system_claude_code_credential, node_instance: instance, provider_type: "anthropic")
      grok = build(:system_claude_code_credential, node_instance: instance, provider_type: "grok")

      expect(grok).to be_valid
    end

    it "still refuses a second credential for the SAME instance and provider" do
      instance = create(:system_node_instance)
      create(:system_claude_code_credential, node_instance: instance, provider_type: "grok")
      duplicate = build(:system_claude_code_credential, node_instance: instance, provider_type: "grok")

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:node_instance_id]).to be_present
    end

    it "keeps anthropic on its ORIGINAL vault path segments so live credentials stay resolvable" do
      expect(build(:system_claude_code_credential, provider_type: "anthropic",
                                                   credential_kind: "api_key").vault_kind_type)
        .to eq(:claude_code_api_key)
      expect(build(:system_claude_code_credential, provider_type: "anthropic",
                                                   credential_kind: "oauth").vault_kind_type)
        .to eq(:claude_code_oauth)
    end

    it "gives every other provider its own vault path segment" do
      expect(build(:system_claude_code_credential, provider_type: "grok").vault_kind_type)
        .to eq(:grok_api_key)
    end

    # The list is a hand-picked SUBSET of the provider catalog, so it cannot
    # be derived from core — but every member must still be a real provider
    # type, or the account-fallback lookup silently matches nothing and the
    # Vault path segment names a vendor that does not exist.
    it "names only real Ai::Provider provider types" do
      expect(described_class::PROVIDER_TYPES - ::Ai::Constants::ProviderTypes::ALL).to be_empty
      expect(described_class::OAUTH_CAPABLE_PROVIDER_TYPES - described_class::PROVIDER_TYPES).to be_empty
    end

    it "refuses the oauth kind for a provider that has no oauth shape" do
      credential = build(:system_claude_code_credential, provider_type: "grok", credential_kind: "oauth")

      expect(credential).not_to be_valid
      expect(credential.errors[:credential_kind].join).to include("oauth is not supported")
    end
  end

  describe ".normalize_oauth_payload!" do
    # Obviously-fake values only — never real token material in specs.
    let(:future_ms) { (Time.current.to_f * 1000).to_i + (90 * 24 * 3600 * 1000) }
    let(:past_ms)   { (Time.current.to_f * 1000).to_i - (24 * 3600 * 1000) }
    let(:valid_blob) do
      {
        "accessToken" => "fake-oauth-access-token-for-spec",
        "refreshToken" => "fake-oauth-refresh-token-for-spec",
        "expiresAt" => future_ms,
        "refreshTokenExpiresAt" => future_ms,
        "scopes" => ["user:inference"],
        "subscriptionType" => "max"
      }
    end

    it "accepts a bare claudeAiOauth blob" do
      expect(described_class.normalize_oauth_payload!(valid_blob)).to eq(valid_blob)
    end

    it "unwraps the full ~/.claude/.credentials.json file shape ({claudeAiOauth: {...}})" do
      expect(described_class.normalize_oauth_payload!({ "claudeAiOauth" => valid_blob }))
        .to eq(valid_blob)
    end

    it "preserves unknown keys verbatim (Claude Code may add fields)" do
      out = described_class.normalize_oauth_payload!(valid_blob.merge("futureField" => "x"))
      expect(out["futureField"]).to eq("x")
    end

    it "allows omitting the optional fields (refreshTokenExpiresAt, scopes, subscriptionType)" do
      minimal = valid_blob.slice("accessToken", "refreshToken", "expiresAt")
      expect(described_class.normalize_oauth_payload!(minimal)).to eq(minimal)
    end

    it "allows an already-expired accessToken expiry (the refresh token is the seed's lifeline)" do
      expect(described_class.normalize_oauth_payload!(valid_blob.merge("expiresAt" => past_ms))["expiresAt"])
        .to eq(past_ms)
    end

    it "rejects a non-hash payload" do
      expect { described_class.normalize_oauth_payload!("a string") }
        .to raise_error(described_class::InvalidOauthPayload, /JSON object/)
    end

    it "rejects a missing accessToken" do
      expect { described_class.normalize_oauth_payload!(valid_blob.except("accessToken")) }
        .to raise_error(described_class::InvalidOauthPayload, /accessToken/)
    end

    it "rejects a blank refreshToken" do
      expect { described_class.normalize_oauth_payload!(valid_blob.merge("refreshToken" => "")) }
        .to raise_error(described_class::InvalidOauthPayload, /refreshToken/)
    end

    it "rejects a non-integer expiresAt" do
      expect { described_class.normalize_oauth_payload!(valid_blob.merge("expiresAt" => "soon")) }
        .to raise_error(described_class::InvalidOauthPayload, /expiresAt/)
    end

    it "rejects an expiresAt in epoch SECONDS (the file shape is epoch milliseconds)" do
      expect { described_class.normalize_oauth_payload!(valid_blob.merge("expiresAt" => Time.current.to_i + 3600)) }
        .to raise_error(described_class::InvalidOauthPayload, /milliseconds/)
    end

    it "rejects an already-expired refreshTokenExpiresAt (a dead seed can never authenticate)" do
      expect { described_class.normalize_oauth_payload!(valid_blob.merge("refreshTokenExpiresAt" => past_ms)) }
        .to raise_error(described_class::InvalidOauthPayload, /already expired/)
    end

    it "rejects non-array scopes" do
      expect { described_class.normalize_oauth_payload!(valid_blob.merge("scopes" => "user:inference")) }
        .to raise_error(described_class::InvalidOauthPayload, /scopes/)
    end

    it "rejects a non-string subscriptionType" do
      expect { described_class.normalize_oauth_payload!(valid_blob.merge("subscriptionType" => 5)) }
        .to raise_error(described_class::InvalidOauthPayload, /subscriptionType/)
    end
  end
end
