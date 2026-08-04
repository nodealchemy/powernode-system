# frozen_string_literal: true

require "rails_helper"

# SystemAcmeTool MCP surface.
# Mirrors system_fleet_tool_spec.rb shape: invoke .execute(params:) directly,
# assert success_result/error_result content (r[:success] / r[:data] / r[:error]).
#
# CRYPTO-MATERIAL SAFETY: for create_dns_credential we assert the provider
# token plaintext NEVER appears anywhere in the returned result hash, and is
# handed only to VaultCredentialProvider#store_credential (which is stubbed).
RSpec.describe Ai::Tools::SystemAcmeTool do
  let(:account) { create(:account) }
  # In-process caller: declares itself with `internal: true`. A bare userless
  # construction no longer bypasses the per-action map — see "principal
  # authorization (IMP-54bf2643f542)".
  let(:tool)    { described_class.new(account: account, internal: true) }

  def call(action, **rest)
    tool.execute(params: { action: action }.merge(rest))
  end

  # Recursively collect every scalar value in a nested hash/array so we can
  # prove a secret never leaks into the serialized result.
  def deep_values(obj)
    case obj
    when Hash  then obj.flat_map { |k, v| [ k ] + deep_values(v) }
    when Array then obj.flat_map { |v| deep_values(v) }
    else [ obj ]
    end
  end

  describe ".action_definitions" do
    it "registers the 4 system_acme_* actions" do
      keys = described_class.action_definitions.keys
      expect(keys).to contain_exactly(
        "system_acme_get_certificate",
        "system_acme_renew_certificate",
        "system_acme_revoke_certificate",
        "system_acme_create_dns_credential"
      )
      expect(keys).to all(start_with("system_acme_"))
    end
  end

  describe "system_acme_get_certificate" do
    let!(:cert) { create(:system_acme_certificate, :valid, account: account) }

    it "returns non-secret certificate detail" do
      r = call("system_acme_get_certificate", certificate_id: cert.id)
      expect(r[:success]).to be true
      data = r[:data][:certificate]
      expect(data[:id]).to eq(cert.id)
      expect(data[:common_name]).to eq(cert.common_name)
      expect(data[:hostname]).to eq(cert.common_name)
      expect(data[:status]).to eq("valid")
      expect(data[:issuer]).to eq("letsencrypt-prod")
      expect(data).to have_key(:expires_at)
      expect(data).to have_key(:vault_paths_present)
    end

    it "NEVER includes PEMs / private keys / vault paths in the payload" do
      cert.update_columns(vault_path_certificate: "acme-certificates/#{account.id}/#{cert.id}/cert")
      r = call("system_acme_get_certificate", certificate_id: cert.id)
      data = r[:data][:certificate]
      # vault_paths_present is a boolean, not the path itself
      expect(data[:vault_paths_present]).to be(true)
      expect(data.keys).not_to include(:vault_path_certificate, :certificate_pem, :private_key_pem, :chain_pem, :account_key_pem)
      flat = deep_values(data)
      expect(flat).not_to include("acme-certificates/#{account.id}/#{cert.id}/cert")
      expect(flat.none? { |v| v.is_a?(String) && v.include?("PRIVATE KEY") }).to be true
    end

    it "errors for an unknown id" do
      r = call("system_acme_get_certificate", certificate_id: SecureRandom.uuid)
      expect(r[:success]).to be false
      expect(r[:error]).to include("not found")
    end

    it "scopes to the current account" do
      other = create(:system_acme_certificate, :valid, account: create(:account))
      r = call("system_acme_get_certificate", certificate_id: other.id)
      expect(r[:success]).to be false
    end
  end

  describe "system_acme_renew_certificate" do
    let!(:cert) { create(:system_acme_certificate, :valid, account: account) }

    it "renews a valid cert via CertificateManager.renew! and returns serialized detail" do
      result = ::Acme::CertificateManager::Result.new(ok?: true, certificate: cert)
      expect(::Acme::CertificateManager).to receive(:renew!)
        .with(certificate: cert)
        .and_return(result)

      r = call("system_acme_renew_certificate", certificate_id: cert.id)
      expect(r[:success]).to be true
      expect(r[:data][:renewed]).to be true
      expect(r[:data][:certificate][:id]).to eq(cert.id)
    end

    it "guards on status=valid (refuses non-valid certs without calling the manager)" do
      pending_cert = create(:system_acme_certificate, account: account) # status: pending
      expect(::Acme::CertificateManager).not_to receive(:renew!)
      r = call("system_acme_renew_certificate", certificate_id: pending_cert.id)
      expect(r[:success]).to be false
      expect(r[:error]).to include("status=valid")
    end

    it "returns error_result with the manager's error on failure" do
      result = ::Acme::CertificateManager::Result.new(ok?: false, error: "lego timeout", certificate: cert)
      allow(::Acme::CertificateManager).to receive(:renew!).and_return(result)
      r = call("system_acme_renew_certificate", certificate_id: cert.id)
      expect(r[:success]).to be false
      expect(r[:error]).to include("lego timeout")
    end

    it "errors for an unknown id" do
      r = call("system_acme_renew_certificate", certificate_id: SecureRandom.uuid)
      expect(r[:success]).to be false
    end
  end

  describe "system_acme_revoke_certificate" do
    let!(:cert) { create(:system_acme_certificate, :valid, account: account) }

    it "revokes a non-terminal cert via CertificateManager.revoke! (passing reason)" do
      result = ::Acme::CertificateManager::Result.new(ok?: true, certificate: cert)
      expect(::Acme::CertificateManager).to receive(:revoke!)
        .with(certificate: cert, reason: "keyCompromise")
        .and_return(result)

      r = call("system_acme_revoke_certificate", certificate_id: cert.id, reason: "keyCompromise")
      expect(r[:success]).to be true
      expect(r[:data][:revoked]).to be true
      expect(r[:data][:certificate][:id]).to eq(cert.id)
    end

    it "passes reason: nil when omitted" do
      result = ::Acme::CertificateManager::Result.new(ok?: true, certificate: cert)
      expect(::Acme::CertificateManager).to receive(:revoke!)
        .with(certificate: cert, reason: nil)
        .and_return(result)
      call("system_acme_revoke_certificate", certificate_id: cert.id)
    end

    it "guards on !terminal? (refuses already-revoked certs without calling the manager)" do
      revoked_cert = create(:system_acme_certificate, :revoked, account: account)
      expect(::Acme::CertificateManager).not_to receive(:revoke!)
      r = call("system_acme_revoke_certificate", certificate_id: revoked_cert.id)
      expect(r[:success]).to be false
      expect(r[:error]).to include("Already revoked")
    end

    it "returns error_result with the manager's error on failure" do
      result = ::Acme::CertificateManager::Result.new(ok?: false, error: "acme unreachable", certificate: cert)
      allow(::Acme::CertificateManager).to receive(:revoke!).and_return(result)
      r = call("system_acme_revoke_certificate", certificate_id: cert.id)
      expect(r[:success]).to be false
      expect(r[:error]).to include("acme unreachable")
    end
  end

  describe "system_acme_create_dns_credential" do
    let(:secret_token) { "cf-SUPER-SECRET-TOKEN-#{SecureRandom.hex(8)}" }
    let(:vault_double) { instance_double(::Security::VaultCredentialProvider) }

    before do
      allow(::Security::VaultCredentialProvider).to receive(:new)
        .with(account_id: account.id)
        .and_return(vault_double)
      allow(vault_double).to receive(:store_credential).and_return({ stored_in: :vault, path: "acme-dns-credentials/x" })
    end

    it "creates the row (public fields only) and hands the secret STRAIGHT to Vault" do
      expect(vault_double).to receive(:store_credential).with(
        credential_type: :acme_dns,
        credential_id: kind_of(String),
        data: { "api_token" => secret_token },
        record: kind_of(::System::AcmeDnsCredential)
      ).and_return({ stored_in: :vault, path: "acme-dns-credentials/x" })

      r = call("system_acme_create_dns_credential",
               name: "prod-cloudflare",
               provider: "cloudflare",
               credentials: { "api_token" => secret_token })

      expect(r[:success]).to be true
      cred = ::System::AcmeDnsCredential.find(r[:data][:credential][:id])
      expect(cred.name).to eq("prod-cloudflare")
      expect(cred.provider).to eq("cloudflare")
      expect(cred.status).to eq("untested")
    end

    it "result serializes ONLY the public index (name, provider, status)" do
      r = call("system_acme_create_dns_credential",
               name: "prod-cloudflare",
               provider: "cloudflare",
               credentials: { "api_token" => secret_token })
      expect(r[:data][:credential].keys).to contain_exactly(:id, :name, :provider, :status)
    end

    # *** CRYPTO-MATERIAL SAFETY — the load-bearing assertion ***
    it "NEVER leaks the secret token anywhere in the returned result hash" do
      r = call("system_acme_create_dns_credential",
               name: "prod-cloudflare",
               provider: "cloudflare",
               credentials: { "api_token" => secret_token },
               metadata: { "note" => "primary zone" })

      expect(r[:success]).to be true
      flat = deep_values(r)
      expect(flat).not_to include(secret_token)
      # belt-and-suspenders: no value should even contain the secret substring
      expect(flat.none? { |v| v.is_a?(String) && v.include?(secret_token) }).to be true
    end

    it "rejects an unsupported provider (before touching Vault or DB)" do
      expect(::Security::VaultCredentialProvider).not_to receive(:new)
      r = call("system_acme_create_dns_credential",
               name: "bogus",
               provider: "namecheap",
               credentials: { "api_token" => secret_token })
      expect(r[:success]).to be false
      expect(r[:error]).to include("Unsupported provider")
    end

    it "rejects when a required credential field is missing" do
      r = call("system_acme_create_dns_credential",
               name: "incomplete",
               provider: "route53",
               credentials: { "access_key_id" => "AKIA..." }) # missing secret_access_key + region
      expect(r[:success]).to be false
      expect(r[:error]).to include("Missing required credential field")
    end

    it "drops fields not declared by the provider registry (allowlist)" do
      expect(vault_double).to receive(:store_credential).with(
        hash_including(data: { "api_token" => secret_token })
      ).and_return({ stored_in: :vault, path: "x" })

      call("system_acme_create_dns_credential",
           name: "extra-fields",
           provider: "cloudflare",
           credentials: { "api_token" => secret_token, "totally_unrelated" => "drop-me" })
    end
  end

  describe "Unknown action" do
    it "returns an error_result" do
      r = call("system_acme_definitely_not_real")
      expect(r[:success]).to be false
      expect(r[:error]).to include("Unknown action")
    end
  end

  describe "Per-action permission gating (mirrors SystemFleetTool)" do
    let(:no_perm_user) { create(:user, account: account, permissions: []) }
    let(:gated_tool)   { described_class.new(account: account, user: no_perm_user) }

    it "denies a user lacking the action permission" do
      cert = create(:system_acme_certificate, :valid, account: account)
      r = gated_tool.execute(params: { action: "system_acme_get_certificate", certificate_id: cert.id })
      expect(r[:success]).to be false
      expect(r[:error]).to include("permission denied")
    end

    it "allows a user holding the action permission" do
      user = create(:user, account: account, permissions: %w[system.acme.read])
      cert = create(:system_acme_certificate, :valid, account: account)
      r = described_class.new(account: account, user: user)
            .execute(params: { action: "system_acme_get_certificate", certificate_id: cert.id })
      expect(r[:success]).to be true
    end
  end

  # IMP-54bf2643f542 — action_permitted? used to read `@user.nil?` as
  # "internal/system caller" and return true (the comment on that line said so
  # outright). That premise (MCP callers always carry a user) predates instance
  # principals: an mTLS node cert authenticates with NO user, so every
  # per-action permission here was skipped and the peer's per-tool grant glob
  # was the only remaining control. Sibling of the SystemFleetTool fix
  # (IMP-9030413bc292): the bypass is now two EXPLICIT signals and a bare
  # userless call fails closed.
  describe "principal authorization (IMP-54bf2643f542)" do
    let(:gated_action) { "system_acme_revoke_certificate" }

    it "denies a bare userless call — no user, no internal flag, no instance grant" do
      bare = described_class.new(account: account, user: nil)

      expect(bare.send(:action_permitted?, gated_action)).to be false
    end

    it "surfaces the denial as an error_result rather than executing the action" do
      cert = create(:system_acme_certificate, :valid, account: account)
      bare = described_class.new(account: account, user: nil)

      result = bare.execute(params: { action: gated_action, certificate_id: cert.id })

      expect(result[:success]).to be false
      expect(result[:error]).to include("permission denied")
      expect(cert.reload.status).not_to eq("revoked")
    end

    it "preserves the internal/system bypass when declared explicitly" do
      internal = described_class.new(account: account, user: nil, internal: true)

      expect(internal.send(:action_permitted?, gated_action)).to be true
    end

    # Behaviour preservation for the live instance principal: the streamable
    # controller grant-gates the specific tool name via Mcp::Principal#may_invoke?
    # before dispatch, and the registrar marks the call. That marking — not the
    # nil user — is what carries it through here.
    it "still permits a grant-gated MCP instance principal" do
      instance_call = described_class.new(account: account, user: nil)
      instance_call.instance_authorized = true

      expect(instance_call.send(:action_permitted?, gated_action)).to be true
    end

    it "keeps enforcing per-action permissions for a user principal" do
      reader = create(:user, account: account, permissions: %w[system.acme.read])
      user_tool = described_class.new(account: account, user: reader)

      expect(user_tool.send(:action_permitted?, "system_acme_get_certificate")).to be true
      expect(user_tool.send(:action_permitted?, gated_action)).to be false
    end
  end
end
