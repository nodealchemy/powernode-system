# frozen_string_literal: true

require "rails_helper"

RSpec.describe Acme::CertificateManager, type: :service do
  let(:account) { create(:account) }
  let(:dns_cred) do
    create(:system_acme_dns_credential, :valid, account: account).tap do |c|
      c.update_columns(vault_path_credentials: "acme-dns/#{c.id}")
    end
  end

  # Stub ACME client that records calls and returns canned cert material.
  let(:stub_client) do
    instance_double("Acme::LegoClient",
                    issue: cert_material,
                    renew: cert_material,
                    revoke: true)
  end

  let(:cert_material) do
    {
      cert_pem: "-----BEGIN CERT-----\nstub\n-----END CERT-----",
      key_pem: "-----BEGIN KEY-----\nstub\n-----END KEY-----",
      chain_pem: "-----BEGIN CHAIN-----\nstub\n-----END CHAIN-----",
      account_key_pem: "-----BEGIN ACCT KEY-----\nstub\n-----END ACCT KEY-----",
      issued_at: Time.current,
      expires_at: 90.days.from_now
    }
  end

  # Stub VaultCredentialProvider so we don't hit a real Vault.
  let(:fake_vault) { instance_double("Security::VaultCredentialProvider") }

  before do
    allow(::Security::VaultCredentialProvider).to receive(:new).and_return(fake_vault)
    # `get_credential` returns the DNS credentials hash for issuance flows
    # AND the cert material hash for revoke flows — return a hash that
    # works for both. Cloudflare's api_token field is what
    # DnsProviderRegistry.validate_credential_shape! checks.
    allow(fake_vault).to receive(:get_credential).and_return(
      "api_token" => "stub-token",
      cert_pem: "-----BEGIN CERT-----\nstub\n-----END CERT-----"
    )
    allow(fake_vault).to receive(:store_credential).and_return(true)
  end

  describe ".issue!" do
    let(:cert) { create(:system_acme_certificate, account: account, dns_credential: dns_cred) }

    it "drives pending → issuing → valid on success" do
      result = described_class.issue!(certificate: cert, acme_client: stub_client)
      expect(result.ok?).to be true
      cert.reload
      expect(cert.status).to eq("valid")
      expect(cert.issued_at).to be_present
      expect(cert.expires_at).to be > 60.days.from_now
      # P2.5.10: the vault_path_* columns now hold on-disk paths
      # (where the PEMs land for Traefik to read), not the old fictional
      # Vault sub-paths. Cert PEM ends with `<cert_id>.crt`.
      expect(cert.vault_path_certificate).to end_with("#{cert.id}.crt")
      expect(cert.vault_path_private_key).to end_with("#{cert.id}.key")
    end

    it "passes the right args to the ACME client" do
      described_class.issue!(certificate: cert, acme_client: stub_client)
      expect(stub_client).to have_received(:issue).with(
        hash_including(
          common_name: cert.common_name,
          sans: [],
          challenge: "dns-01",
          provider: "cloudflare",
          issuer: "letsencrypt-prod"
        )
      )
    end

    it "fails when cert is not eligible for issuing (e.g. already valid)" do
      cert.update!(status: "valid", issued_at: Time.current, expires_at: 90.days.from_now)
      result = described_class.issue!(certificate: cert, acme_client: stub_client)
      expect(result.ok?).to be false
      expect(result.error).to match(/not eligible for issuance.*valid/)
    end

    it "fails the cert when ACME client raises" do
      allow(stub_client).to receive(:issue).and_raise(StandardError, "ACME server unreachable")
      result = described_class.issue!(certificate: cert, acme_client: stub_client)
      expect(result.ok?).to be false
      expect(cert.reload.status).to eq("failed")
      expect(cert.last_renewal_error).to include("ACME server unreachable")
    end

    it "fails when DNS credential shape is invalid" do
      # Empty hash → missing api_token → shape validation raises
      allow(fake_vault).to receive(:get_credential).and_return({})
      result = described_class.issue!(certificate: cert, acme_client: stub_client)
      expect(result.ok?).to be false
      expect(cert.reload.status).to eq("failed")
      expect(cert.last_renewal_error).to match(/missing required fields/)
    end

    it "fails when DNS provider is unsupported (defensive — model validation should catch first)" do
      # Bypass model validation by direct column update
      dns_cred.update_columns(provider: "megacorp-dns")
      result = described_class.issue!(certificate: cert, acme_client: stub_client)
      expect(result.ok?).to be false
      expect(cert.reload.status).to eq("failed")
    end
  end

  describe ".renew!" do
    let(:cert) do
      create(:system_acme_certificate, :valid, account: account, dns_credential: dns_cred).tap do |c|
        c.update_columns(
          vault_path_certificate: "acme-certificates/#{account.id}/#{c.id}/cert",
          vault_path_private_key: "acme-certificates/#{account.id}/#{c.id}/key"
        )
      end
    end

    it "drives valid → renewing → valid on success" do
      result = described_class.renew!(certificate: cert, acme_client: stub_client)
      expect(result.ok?).to be true
      cert.reload
      expect(cert.status).to eq("valid")
      expect(cert.expires_at).to be > 60.days.from_now
    end

    it "fails the cert when ACME renew raises" do
      allow(stub_client).to receive(:renew).and_raise(StandardError, "challenge timeout")
      result = described_class.renew!(certificate: cert, acme_client: stub_client)
      expect(result.ok?).to be false
      expect(cert.reload.status).to eq("failed")
      expect(cert.last_renewal_error).to include("challenge timeout")
    end

    it "rejects renewal of a non-valid cert" do
      cert.update!(status: "pending")
      result = described_class.renew!(certificate: cert, acme_client: stub_client)
      expect(result.ok?).to be false
    end
  end

  describe ".revoke!" do
    let(:cert) do
      create(:system_acme_certificate, :valid, account: account, dns_credential: dns_cred).tap do |c|
        c.update_columns(vault_path_certificate: "acme-certificates/#{account.id}/#{c.id}/cert")
      end
    end

    it "moves cert to revoked + records reason" do
      result = described_class.revoke!(certificate: cert, reason: "key compromise", acme_client: stub_client)
      expect(result.ok?).to be true
      cert.reload
      expect(cert.status).to eq("revoked")
      expect(cert.metadata["revocation_reason"]).to eq("key compromise")
    end

    it "revokes locally even if ACME-server revoke fails" do
      allow(stub_client).to receive(:revoke).and_raise(StandardError, "ACME 503")
      result = described_class.revoke!(certificate: cert, reason: "rotated key", acme_client: stub_client)
      expect(result.ok?).to be true
      expect(cert.reload.status).to eq("revoked")
    end

    it "refuses to revoke an already-revoked cert" do
      cert.update!(status: "revoked")
      result = described_class.revoke!(certificate: cert, acme_client: stub_client)
      expect(result.ok?).to be false
      expect(result.error).to match(/terminal state/)
    end

    # P2.5.7 acceptance smoke surfaced three lifecycle bugs at revoke
    # time — these specs lock the fix.
    it "stamps revoked_at when transitioning to revoked", :time_helpers do
      freeze_at = Time.utc(2026, 5, 17, 12, 0, 0)
      travel_to(freeze_at) do
        described_class.revoke!(certificate: cert, reason: "test", acme_client: stub_client)
      end
      expect(cert.reload.revoked_at).to be_within(1.second).of(freeze_at)
    end

    it "regenerates Traefik dynamic config so the revoked cert disappears" do
      writer_call = nil
      allow(::Acme::TraefikConfigWriter).to receive(:write!) do |account:, **_|
        writer_call = account
        { output_path: "/tmp/test", cert_count: 0 }
      end
      described_class.revoke!(certificate: cert, acme_client: stub_client)
      expect(writer_call).to eq(account)
    end

    it "removes the on-disk cert/key/chain PEMs at revoke time" do
      cert_path  = Acme::TraefikConfigWriter.cert_file_path(cert)
      key_path   = Acme::TraefikConfigWriter.key_file_path(cert)
      chain_path = Acme::TraefikConfigWriter.chain_file_path(cert)
      FileUtils.mkdir_p(File.dirname(cert_path))
      [ cert_path, key_path, chain_path ].each { |p| File.write(p, "TEST PEM") }

      described_class.revoke!(certificate: cert, acme_client: stub_client)

      [ cert_path, key_path, chain_path ].each do |p|
        expect(File.exist?(p)).to be(false), "expected #{p} to be removed after revoke!"
      end
    end
  end

  describe "#resolve_acme_email (private; fallback chain)" do
    let(:cert) { create(:system_acme_certificate, account: account, dns_credential: dns_cred) }
    let(:manager) { described_class.new(acme_client: stub_client) }

    around do |example|
      saved = ENV["POWERNODE_ACME_EMAIL"]
      ENV.delete("POWERNODE_ACME_EMAIL")
      example.run
      saved.nil? ? ENV.delete("POWERNODE_ACME_EMAIL") : ENV["POWERNODE_ACME_EMAIL"] = saved
    end

    it "prefers certificate.metadata['acme_email'] when set" do
      cert.update!(metadata: { "acme_email" => "explicit@example.com" })
      expect(manager.send(:resolve_acme_email, cert)).to eq("explicit@example.com")
    end

    # P2.5.7 acceptance smoke surfaced this: the resolver hardcoded
    # role "admin" but the platform's role catalog uses super_admin /
    # owner as admin-equivalent in production. Lock that all three
    # admin-tier role names match.
    it "accepts super_admin/owner/admin via ADMIN_EQUIVALENT_ROLES constant" do
      expect(::Acme::CertificateManager::ADMIN_EQUIVALENT_ROLES)
        .to match_array(%w[owner super_admin admin])
    end

    it "queries users.joins(:roles).where(roles: { name: ADMIN_EQUIVALENT_ROLES })" do
      # Override the factory's metadata so the resolver falls through
      # past steps 1 (metadata) and 2 (env, cleared by around) to the
      # admin-equivalent role lookup.
      cert.update!(metadata: {})
      fake_account = instance_double("Account")
      fake_users   = double("UsersRelation")
      fake_filter  = double("FilteredRelation")
      fake_user    = instance_double("User", email: "ops@example.com")
      allow(cert).to receive(:account).and_return(fake_account)
      allow(fake_account).to receive(:users).and_return(fake_users)
      allow(fake_users).to receive(:joins).with(:roles).and_return(fake_filter)
      allow(fake_filter).to receive(:where)
        .with(roles: { name: ::Acme::CertificateManager::ADMIN_EQUIVALENT_ROLES })
        .and_return(double(order: double(first: fake_user)))
      expect(manager.send(:resolve_acme_email, cert)).to eq("ops@example.com")
    end

    it "raises a clear error when no email source is available" do
      cert.update!(metadata: {})
      # Stub out the account's user lookup to return nil (no admin
      # found) so the resolver falls past all three sources.
      fake_account = instance_double("Account")
      fake_users   = double("UsersRelation")
      fake_filter  = double("FilteredRelation")
      allow(cert).to receive(:account).and_return(fake_account)
      allow(fake_account).to receive(:users).and_return(fake_users)
      allow(fake_users).to receive(:joins).with(:roles).and_return(fake_filter)
      allow(fake_filter).to receive(:where).and_return(double(order: double(first: nil)))
      expect { manager.send(:resolve_acme_email, cert) }
        .to raise_error(ArgumentError, /No ACME email/)
    end
  end

  describe "uniqueness scoping (model)" do
    it "allows re-issuing for the same common_name after revocation" do
      original = create(:system_acme_certificate, :valid,
                        account: account, dns_credential: dns_cred,
                        common_name: "reissue.example.com")
      original.update!(status: "revoked", revoked_at: Time.current)

      fresh = build(:system_acme_certificate,
                    account: account, dns_credential: dns_cred,
                    common_name: "reissue.example.com",
                    status: "pending",
                    issuer: "letsencrypt-staging",
                    challenge_type: "dns-01")
      expect(fresh).to be_valid
    end

    it "still rejects a duplicate common_name on a live row" do
      create(:system_acme_certificate, :valid,
             account: account, dns_credential: dns_cred,
             common_name: "live.example.com")
      dupe = build(:system_acme_certificate,
                   account: account, dns_credential: dns_cred,
                   common_name: "live.example.com",
                   status: "pending",
                   issuer: "letsencrypt-staging",
                   challenge_type: "dns-01")
      expect(dupe).not_to be_valid
      expect(dupe.errors[:common_name]).to be_present
    end
  end
end
