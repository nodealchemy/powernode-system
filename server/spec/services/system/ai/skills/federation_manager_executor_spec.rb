# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Ai::Skills::FederationManagerExecutor, type: :service do
  let(:account) { create(:account) }
  let(:user)    { create(:user, account: account) }

  subject(:executor) { described_class.new(account: account, user: user) }

  describe ".descriptor" do
    it "exposes the skill metadata" do
      desc = described_class.descriptor
      expect(desc[:name]).to eq("federation_manager")
      expect(desc[:category]).to eq("federation")
      expect(desc[:outputs].keys).to include(
        :cert_rotation_candidates, :grants_approaching_expiry,
        :grants_overdue_for_review, :broad_scope_grants, :capability_drift
      )
    end
  end

  describe "#execute" do
    it "returns success with empty findings on a clean account" do
      result = executor.execute
      expect(result[:success]).to be true
      expect(result[:data][:finding_count]).to eq(0)
      expect(result[:data][:account_id]).to eq(account.id)
    end

    context "cert_rotation_candidates" do
      it "flags federation_peer certs past 75% of their lifetime" do
        # 100-day lifetime, 80 days elapsed = 80% — over threshold
        cert = ::System::NodeCertificate.create!(
          account: account, subject_kind: "federation_peer",
          subject: "peer-#{SecureRandom.uuid}",
          serial: SecureRandom.hex(16),
          not_before: 80.days.ago, not_after: 20.days.from_now,
          pem_chain: "stub", issuer_subject: "Powernode Internal CA"
        )
        peer = create(:system_federation_peer, :active,
                      account: account, node_certificate: cert)
        result = executor.execute
        candidates = result[:data][:cert_rotation_candidates]
        expect(candidates.size).to eq(1)
        expect(candidates.first[:peer_id]).to eq(peer.id)
        expect(candidates.first[:lifetime_ratio_elapsed]).to be >= 0.75
      end

      it "ignores young certs" do
        cert = ::System::NodeCertificate.create!(
          account: account, subject_kind: "federation_peer",
          subject: "peer-#{SecureRandom.uuid}",
          serial: SecureRandom.hex(16),
          not_before: 5.days.ago, not_after: 175.days.from_now,
          pem_chain: "stub", issuer_subject: "Powernode Internal CA"
        )
        create(:system_federation_peer, :active,
               account: account, node_certificate: cert)
        result = executor.execute
        expect(result[:data][:cert_rotation_candidates]).to be_empty
      end
    end

    context "grants_approaching_expiry" do
      it "flags active grants expiring within 7 days" do
        grant = create(:system_federation_grant,
                       account: account,
                       federation_peer: create(:system_federation_peer, :platform, account: account),
                       grantor_user: user,
                       issued_at: 25.days.ago,
                       expires_at: 5.days.from_now)
        result = executor.execute
        expiring = result[:data][:grants_approaching_expiry]
        expect(expiring.size).to eq(1)
        expect(expiring.first[:grant_id]).to eq(grant.id)
        expect(expiring.first[:expires_in_days]).to eq(4)  # 5d − ε
      end

      it "does NOT flag grants comfortably far from expiry" do
        create(:system_federation_grant,
               account: account,
               federation_peer: create(:system_federation_peer, :platform, account: account),
               grantor_user: user,
               issued_at: 1.day.ago,
               expires_at: 28.days.from_now)
        result = executor.execute
        expect(result[:data][:grants_approaching_expiry]).to be_empty
      end
    end

    context "grants_overdue_for_review" do
      it "flags active grants issued >90 days ago" do
        grant = create(:system_federation_grant,
                       account: account,
                       federation_peer: create(:system_federation_peer, :platform, account: account),
                       grantor_user: user,
                       issued_at: 100.days.ago,
                       expires_at: 30.days.from_now)
        result = executor.execute
        stale = result[:data][:grants_overdue_for_review]
        expect(stale.size).to eq(1)
        expect(stale.first[:grant_id]).to eq(grant.id)
        expect(stale.first[:age_days]).to be >= 90
      end
    end

    context "broad_scope_grants" do
      it "flags grants carrying admin or migrate scope" do
        admin_grant = create(:system_federation_grant,
                              account: account,
                              federation_peer: create(:system_federation_peer, :platform, account: account),
                              grantor_user: user,
                              permission_scopes: %w[read admin])
        create(:system_federation_grant,
               account: account,
               federation_peer: create(:system_federation_peer, :platform, account: account),
               grantor_user: user,
               permission_scopes: %w[read])  # benign
        result = executor.execute
        broad = result[:data][:broad_scope_grants]
        expect(broad.size).to eq(1)
        expect(broad.first[:grant_id]).to eq(admin_grant.id)
        expect(broad.first[:broad_scopes]).to eq([ "admin" ])
      end

      it "flags migrate scope as broad" do
        grant = create(:system_federation_grant,
                       account: account,
                       federation_peer: create(:system_federation_peer, :platform, account: account),
                       grantor_user: user,
                       permission_scopes: %w[read migrate])
        result = executor.execute
        broad = result[:data][:broad_scope_grants]
        expect(broad.size).to eq(1)
        expect(broad.first[:grant_id]).to eq(grant.id)
      end
    end

    context "capability_drift" do
      it "flags platform peers with declared extensions but no capabilities" do
        peer = create(:system_federation_peer, :active,
                      account: account,
                      extension_slugs: [ "trading" ],
                      capabilities: {})
        result = executor.execute
        drift = result[:data][:capability_drift]
        expect(drift.size).to eq(1)
        expect(drift.first[:peer_id]).to eq(peer.id)
        expect(drift.first[:extension_slugs]).to eq([ "trading" ])
      end

      it "does NOT flag peers with matching capability rows" do
        peer = create(:system_federation_peer, :active,
                      account: account, extension_slugs: [ "trading" ])
        create(:system_federation_capability,
               account: account, federation_peer: peer,
               resource_kind: "trading_strategy")
        result = executor.execute
        expect(result[:data][:capability_drift]).to be_empty
      end
    end

    it "accumulates finding_count across all check categories" do
      cert = ::System::NodeCertificate.create!(
        account: account, subject_kind: "federation_peer",
        subject: "peer-#{SecureRandom.uuid}", serial: SecureRandom.hex(16),
        not_before: 80.days.ago, not_after: 20.days.from_now,
        pem_chain: "stub", issuer_subject: "Powernode Internal CA"
      )
      create(:system_federation_peer, :active,
             account: account, node_certificate: cert,
             extension_slugs: [ "trading" ])
      create(:system_federation_grant,
             account: account,
             federation_peer: create(:system_federation_peer, :platform, account: account),
             grantor_user: user,
             permission_scopes: %w[admin])
      result = executor.execute
      expect(result[:data][:finding_count]).to be >= 3  # cert + drift + admin grant (at minimum)
    end
  end
end
