# frozen_string_literal: true

require "rails_helper"

# Skill: acme_certificate_provision — issues a new ACME TLS certificate.
# ::Acme::CertificateManager.issue! is always stubbed so no ACME / network
# work happens; we assert the row is created, the manager is driven, and the
# return shape + validation guards hold.
RSpec.describe System::Ai::Skills::AcmeCertificateProvisionExecutor do
  let(:account)        { create(:account) }

  # APO-1c (IMP-7e2bdc1774e4). This executor declares `requires_approval: true`,
  # and BaseSkillExecutor#execute now resolves Ai::InterventionPolicy BEFORE
  # #perform — an unconfigured category defaults to require_approval, so every
  # example below would park an approval instead of performing. These examples
  # are about what #perform DOES, so an operator policy puts the gate on its
  # proceed branch rather than removing it: the real entry point still runs.
  # See spec/support/skill_gate_helpers.rb.
  before { auto_execute_skill_policy!(account, described_class) }
  let(:dns_credential) { create(:system_acme_dns_credential, :valid, account: account) }
  let(:exec)           { described_class.new(account: account) }

  # Recursively collect every scalar value in a nested hash/array — mirrors
  # system_acme_tool_spec.rb's own helper of the same name, used the same way.
  def deep_values(obj)
    case obj
    when Hash  then obj.flat_map { |k, v| [ k ] + deep_values(v) }
    when Array then obj.flat_map { |v| deep_values(v) }
    else [ obj ]
    end
  end

  # A Result-like stub: the manager mutates the row's lifecycle columns on a
  # real issuance; here we stamp the post-issuance attrs and return ok?=true.
  #
  # IMP-3b0e956d1d5e — reviewer finding: the paths below were a fictional
  # shape ("acme-certificates/<acct>/<id>/cert") this test invented; a
  # negative scan for THAT literal string proves nothing about the real
  # production shape, which certificate_manager_spec.rb documents as
  # on-disk paths ending in "<id>.crt"/"<id>.key" (P2.5.10). Use the SAME
  # path-building method CertificateManager/TraefikConfigWriter actually use
  # (Acme::TraefikConfigWriter.cert_file_path etc.) so the scan tests the
  # shape that would really leak, not an allowlisted alternative.
  def stub_successful_issue!
    allow(::Acme::CertificateManager).to receive(:issue!) do |certificate:|
      certificate.update_columns(
        status: "valid",
        issued_at: Time.current,
        expires_at: 90.days.from_now,
        vault_path_certificate: ::Acme::TraefikConfigWriter.cert_file_path(certificate),
        vault_path_private_key: ::Acme::TraefikConfigWriter.key_file_path(certificate),
        vault_path_chain: ::Acme::TraefikConfigWriter.chain_file_path(certificate)
      )
      ::Acme::CertificateManager::Result.new(ok?: true, certificate: certificate)
    end
  end

  describe ".descriptor" do
    it "is an approval-gated devops skill with the expected inputs" do
      d = described_class.descriptor
      expect(d[:name]).to eq("acme_certificate_provision")
      expect(d[:category]).to eq("devops")
      expect(d[:requires_approval]).to be true
      expect(d.dig(:inputs, :common_name, :required)).to be true
      expect(d.dig(:inputs, :issuer, :required)).to be true
      expect(d.dig(:inputs, :challenge_type, :required)).to be true
    end

    # IMP-3b0e956d1d5e — reviewer finding: the body was fixed but the
    # declared OUTPUTS contract still advertised the 3 literal vault_path_*
    # keys, one of them the certificate's PRIVATE KEY path — a model reading
    # this descriptor was told the disclosure was intentional and documented.
    # descriptor[:outputs] is a live, spec-asserted contract elsewhere in
    # this repo (e.g. system_fleet_tool_spec.rb's PlatformDeployExecutor
    # descriptor pin) — mirrored here.
    it "declares vault_paths_present, never the literal vault_path_* keys" do
      outputs = described_class.descriptor[:outputs]
      expect(outputs).to have_key(:vault_paths_present)
      expect(outputs[:vault_paths_present]).to eq(:boolean)
      expect(outputs.keys).not_to include(:vault_path_certificate, :vault_path_private_key, :vault_path_chain)
    end
  end

  describe "#execute" do
    context "with a valid dns-01 request" do
      before { stub_successful_issue! }

      it "creates an AcmeCertificate row and drives issuance" do
        expect(::Acme::CertificateManager).to receive(:issue!)
          .with(certificate: instance_of(System::AcmeCertificate)).and_call_original

        expect do
          exec.execute(
            common_name: "ops.example.com",
            issuer: "letsencrypt-prod",
            challenge_type: "dns-01",
            dns_credential_id: dns_credential.id
          )
        end.to change(System::AcmeCertificate, :count).by(1)

        cert = System::AcmeCertificate.order(:created_at).last
        expect(cert.account_id).to eq(account.id)
        expect(cert.common_name).to eq("ops.example.com")
        expect(cert.dns_credential_id).to eq(dns_credential.id)
      end

      # IMP-3b0e956d1d5e — reviewer-pinned bug: this test previously asserted
      # the leak was correct behavior (vault_path_certificate/_private_key/
      # _chain present verbatim in the result). `r` here is exactly the
      # object `run_executor` returns as the MCP tool result for
      # system_acme_provision_certificate (SystemIngressTool#run_executor
      # calls `build_skill_executor(klass).execute(**inputs)` and returns it
      # unchanged) -- this is the serialized-MCP-result boundary the task
      # requires asserting against, not an intermediate hash.
      it "returns the certificate attributes after a successful issue, with NO literal Vault path anywhere" do
        r = exec.execute(
          common_name: "ops.example.com",
          sans: [ "www.ops.example.com" ],
          issuer: "letsencrypt-prod",
          challenge_type: "dns-01",
          dns_credential_id: dns_credential.id,
          acme_email: "ops@example.com"
        )

        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:common_name]).to eq("ops.example.com")
        expect(d[:issuer]).to eq("letsencrypt-prod")
        expect(d[:challenge_type]).to eq("dns-01")
        expect(d[:status]).to eq("valid")
        expect(d[:certificate_id]).to be_present
        expect(d[:issued_at]).to be_present
        expect(d[:expires_at]).to be_present
        # Mirrors system_acme_tool.rb:371's vault_paths_present shape exactly
        # -- the fix is agreement between the two actions, not a new one.
        expect(d[:vault_paths_present]).to be(true)
        expect(d.keys).not_to include(:vault_path_certificate, :vault_path_private_key, :vault_path_chain)

        # IMP-3b0e956d1d5e — reviewer finding: scan the WHOLE result (r), not
        # just r[:data], and scan for the REAL production-shaped paths
        # (computed the same way CertificateManager/TraefikConfigWriter
        # actually compute them — see stub_successful_issue! above), not an
        # invented literal that only this test's own fixture ever produced.
        cert = System::AcmeCertificate.find(d[:certificate_id])
        real_paths = [
          ::Acme::TraefikConfigWriter.cert_file_path(cert),
          ::Acme::TraefikConfigWriter.key_file_path(cert),
          ::Acme::TraefikConfigWriter.chain_file_path(cert)
        ]
        flat = deep_values(r)
        expect(flat.none? { |v| v.is_a?(String) && real_paths.any? { |p| v.include?(p) } }).to be true
      end

      it "persists acme_email into metadata" do
        exec.execute(
          common_name: "ops.example.com",
          issuer: "letsencrypt-prod",
          challenge_type: "dns-01",
          dns_credential_id: dns_credential.id,
          acme_email: "ops@example.com"
        )
        cert = System::AcmeCertificate.order(:created_at).last
        expect(cert.metadata["acme_email"]).to eq("ops@example.com")
      end
    end

    context "with an http-01 request (no dns credential needed)" do
      before { stub_successful_issue! }

      it "succeeds without a dns_credential_id" do
        expect do
          r = exec.execute(
            common_name: "ops.example.com",
            issuer: "letsencrypt-staging",
            challenge_type: "http-01"
          )
          expect(r[:success]).to be true
        end.to change(System::AcmeCertificate, :count).by(1)
      end
    end

    context "validation failures" do
      it "rejects an unknown issuer without creating a row" do
        expect do
          r = exec.execute(
            common_name: "ops.example.com",
            issuer: "self-signed-bogus",
            challenge_type: "http-01"
          )
          expect(r[:success]).to be false
          expect(r[:error]).to match(/Invalid issuer/)
        end.not_to change(System::AcmeCertificate, :count)
      end

      it "rejects an unknown challenge_type" do
        r = exec.execute(
          common_name: "ops.example.com",
          issuer: "letsencrypt-prod",
          challenge_type: "carrier-pigeon"
        )
        expect(r[:success]).to be false
        expect(r[:error]).to match(/Invalid challenge_type/)
      end

      it "requires a dns_credential_id for dns-01" do
        expect do
          r = exec.execute(
            common_name: "ops.example.com",
            issuer: "letsencrypt-prod",
            challenge_type: "dns-01"
          )
          expect(r[:success]).to be false
          expect(r[:error]).to match(/dns_credential_id is required/)
        end.not_to change(System::AcmeCertificate, :count)
      end

      it "fails when the dns credential is not found in the account" do
        r = exec.execute(
          common_name: "ops.example.com",
          issuer: "letsencrypt-prod",
          challenge_type: "dns-01",
          dns_credential_id: SecureRandom.uuid
        )
        expect(r[:success]).to be false
        expect(r[:error]).to match(/DNS credential not found/)
      end

      it "fails fast on a missing required input before touching the manager" do
        expect(::Acme::CertificateManager).not_to receive(:issue!)
        r = exec.execute(issuer: "letsencrypt-prod", challenge_type: "http-01")
        expect(r[:success]).to be false
        expect(r[:error]).to match(/missing required input: common_name/)
      end
    end

    context "when issuance fails" do
      before do
        allow(::Acme::CertificateManager).to receive(:issue!) do |certificate:|
          certificate.transition_to!("failed", error_message: "ACME server unreachable")
          ::Acme::CertificateManager::Result.new(
            ok?: false, certificate: certificate, error: "ACME server unreachable"
          )
        end
      end

      it "returns a failure wrapping the manager error and keeps the row" do
        expect do
          r = exec.execute(
            common_name: "ops.example.com",
            issuer: "letsencrypt-prod",
            challenge_type: "http-01"
          )
          expect(r[:success]).to be false
          expect(r[:error]).to match(/issuance failed.*ACME server unreachable/)
        end.to change(System::AcmeCertificate, :count).by(1)
      end
    end

    # IMP-1a5c145c24eb — reviewer finding A2: this Result-path forward had no
    # caller_safe check at all before this fix (system_acme_provision_
    # certificate maps here via run_executor, unguarded, unlike SystemAcmeTool's
    # own renew_certificate/revoke_certificate which the earlier rounds fixed).
    context "when issuance fails on CertificateManager's blanket-rescue path (caller_safe: false)" do
      before do
        allow(::Acme::CertificateManager).to receive(:issue!) do |certificate:|
          certificate.transition_to!("failed", error_message: "PG::ConnectionBad: driver-internal detail")
          ::Acme::CertificateManager::Result.new(
            ok?: false, certificate: certificate, caller_safe: false,
            error: "PG::ConnectionBad: driver-internal detail nobody should see"
          )
        end
      end

      it "does not forward the raw text, and still logs it" do
        expect(Rails.logger).to receive(:error).with(/driver-internal detail/)

        r = exec.execute(
          common_name: "ops2.example.com",
          issuer: "letsencrypt-prod",
          challenge_type: "http-01"
        )

        expect(r[:success]).to be false
        expect(r[:error]).to eq("Certificate issuance failed")
        expect(r[:error]).not_to include("driver-internal detail")
      end
    end

    # IMP-156eb1a7bdbc — the check was `caller_safe == false`, which FAILS
    # OPEN: a Result built without the key (caller_safe nil) forwarded its
    # error verbatim. Forwarding requires an explicit truthy annotation, the
    # same rule SystemAcmeTool#renew_certificate/#revoke_certificate apply.
    context "when issuance fails with a Result that carries no caller_safe annotation (nil)" do
      before do
        allow(::Acme::CertificateManager).to receive(:issue!) do |certificate:|
          ::Acme::CertificateManager::Result.new(
            ok?: false, certificate: certificate,
            error: "MARKER-156eb1 unannotated internal detail"
          )
        end
      end

      it "withholds the text, as it does for caller_safe: false" do
        r = exec.execute(common_name: "ops3.example.com", issuer: "letsencrypt-prod", challenge_type: "http-01")

        expect(r[:success]).to be false
        expect(r[:error]).to eq("Certificate issuance failed")
        expect(deep_values(r).map(&:to_s).join(" ")).not_to include("MARKER-156eb1")
      end
    end

    context "when issuance fails with a Result marked caller_safe: true" do
      before do
        allow(::Acme::CertificateManager).to receive(:issue!) do |certificate:|
          ::Acme::CertificateManager::Result.new(
            ok?: false, certificate: certificate, caller_safe: true,
            error: "certificate was revoked mid-issuance; issue result discarded"
          )
        end
      end

      it "forwards the authored text" do
        r = exec.execute(common_name: "ops4.example.com", issuer: "letsencrypt-prod", challenge_type: "http-01")

        expect(r[:error]).to eq("Certificate issuance failed: certificate was revoked mid-issuance; issue result discarded")
      end
    end

    # Re-provision idempotency. The model scopes common_name uniqueness to
    # NON-terminal rows (only `revoked` is terminal), so a leftover `failed`
    # / `pending` / `issuing` row blocks a fresh `create!` for the same CN.
    # The executor must REUSE an existing non-terminal row instead of trying
    # to create a duplicate — otherwise an operator can't retry after a
    # transient ACME failure.
    context "re-provisioning a common name that already has a row" do
      # REPRODUCES THE BUG: with a leftover `failed` row for the CN, a
      # naive create! hits "Common name has already been taken". Against
      # the unfixed executor this example fails (RecordInvalid surfaced as
      # `Could not create certificate: ... Common name has already been
      # taken`, success=false, AND a brand-new row is never created).
      it "reuses an existing failed row and re-issues without a uniqueness error" do
        existing = create(
          :system_acme_certificate, :http01,
          account: account, common_name: "retry.example.com",
          issuer: "letsencrypt-staging", status: "failed"
        )

        stub_successful_issue!

        result = nil
        expect do
          result = exec.execute(
            common_name: "retry.example.com",
            issuer: "letsencrypt-prod",
            challenge_type: "http-01"
          )
        end.not_to change(System::AcmeCertificate, :count)

        expect(result[:success]).to be true
        expect(result[:error]).to be_nil
        # Same row, re-issued through the same CertificateManager path.
        expect(result[:data][:certificate_id]).to eq(existing.id)
        expect(result[:data][:status]).to eq("valid")
        # Mutable request fields are refreshed onto the reused row.
        expect(existing.reload.issuer).to eq("letsencrypt-prod")
      end

      it "reuses a leftover pending row (aborted issuance) for the same CN" do
        existing = create(
          :system_acme_certificate, :http01,
          account: account, common_name: "aborted.example.com", status: "pending"
        )

        stub_successful_issue!

        expect do
          r = exec.execute(
            common_name: "aborted.example.com",
            issuer: "letsencrypt-prod",
            challenge_type: "http-01"
          )
          expect(r[:success]).to be true
          expect(r[:data][:certificate_id]).to eq(existing.id)
        end.not_to change(System::AcmeCertificate, :count)
      end

      it "reuses a leftover issuing row (crashed mid-issuance) for the same CN" do
        existing = create(
          :system_acme_certificate, :http01,
          account: account, common_name: "stuck.example.com", status: "issuing"
        )

        stub_successful_issue!

        expect do
          r = exec.execute(
            common_name: "stuck.example.com",
            issuer: "letsencrypt-prod",
            challenge_type: "http-01"
          )
          expect(r[:success]).to be true
          expect(r[:data][:certificate_id]).to eq(existing.id)
        end.not_to change(System::AcmeCertificate, :count)
      end

      it "reuses a valid + unexpired row without re-issuing" do
        existing = create(
          :system_acme_certificate, :http01, :valid,
          account: account, common_name: "live.example.com"
        )

        # A valid+unexpired cert is reused as-is; no ACME work happens.
        expect(::Acme::CertificateManager).not_to receive(:issue!)

        result = nil
        expect do
          result = exec.execute(
            common_name: "live.example.com",
            issuer: "letsencrypt-prod",
            challenge_type: "http-01"
          )
        end.not_to change(System::AcmeCertificate, :count)

        expect(result[:success]).to be true
        expect(result[:data][:certificate_id]).to eq(existing.id)
        expect(result[:data][:status]).to eq("valid")
        # IMP-3b0e956d1d5e — the OTHER call site of certificate_attrs (the
        # reuse fast-path, not drive_issuance): presence must be reported
        # TRUTHFULLY, not hardcoded. This factory-built cert never had Vault
        # paths materialized, so presence is false here -- an assertion that
        # only ever checks "true" cannot fail differently from a fix that
        # hardcodes the boolean.
        expect(result[:data][:vault_paths_present]).to be(false)
        expect(result[:data].keys).not_to include(:vault_path_certificate, :vault_path_private_key, :vault_path_chain)
      end

      it "does not silently treat a valid-but-expired row as live (routes to renewal)" do
        existing = create(
          :system_acme_certificate, :http01,
          account: account, common_name: "stale.example.com",
          status: "valid", issued_at: 100.days.ago, expires_at: 1.day.ago
        )

        # An expired `valid` row is NOT reusable as-is, and the state machine
        # has no `valid → issuing` edge — re-issuance for it belongs to the
        # renewal path (AcmeCertificateRenewalJob), not this provision skill.
        # We must NOT create a duplicate and must NOT claim success.
        expect(::Acme::CertificateManager).not_to receive(:issue!)

        result = nil
        expect do
          result = exec.execute(
            common_name: "stale.example.com",
            issuer: "letsencrypt-prod",
            challenge_type: "http-01"
          )
        end.not_to change(System::AcmeCertificate, :count)

        expect(result[:success]).to be false
        expect(result[:error]).to match(/renew/i)
        expect(existing.reload.status).to eq("valid")
      end

      it "creates a fresh row for a brand-new common name" do
        stub_successful_issue!

        result = nil
        expect do
          result = exec.execute(
            common_name: "brand-new.example.com",
            issuer: "letsencrypt-prod",
            challenge_type: "http-01"
          )
        end.to change(System::AcmeCertificate, :count).by(1)

        expect(result[:success]).to be true
        created = System::AcmeCertificate.find_by(common_name: "brand-new.example.com", account: account)
        expect(result[:data][:certificate_id]).to eq(created.id)
      end

      it "does not reuse a row belonging to a different account" do
        other_account = create(:account)
        create(
          :system_acme_certificate, :http01,
          account: other_account, common_name: "scoped.example.com", status: "failed"
        )

        stub_successful_issue!

        result = nil
        expect do
          result = exec.execute(
            common_name: "scoped.example.com",
            issuer: "letsencrypt-prod",
            challenge_type: "http-01"
          )
        end.to change { System::AcmeCertificate.where(account: account).count }.by(1)

        expect(result[:success]).to be true
      end
    end
  end
end
