# frozen_string_literal: true

require "rails_helper"

# AI/MCP workload substrate L2.5 (A2A) — Ed25519 capability-token signer.
# Minting is gated on PeerCapabilityService.authorize; verification is offline
# (the on-node agent does the equivalent with crypto/ed25519).
RSpec.describe System::PeerCapabilityTokenSigner, type: :service do
  let(:account) { create(:account) }

  def announce(handle:, declared_skills: [], enabled: true, status: "active", granted: [], account: self.account)
    inst = create(:system_node_instance, account: account, status: "running")
    peer = System::NodeInstancePeer.create!(
      node_instance: inst, account: account, handle: "#{handle}-#{SecureRandom.hex(2)}",
      status: status, enabled: enabled, trust_score: 0.5, daily_decision_budget: 10,
      declared_skills: declared_skills
    )
    peer.grant_peer_skills!(granted) if granted.any?
    inst
  end

  let(:caller_inst) { announce(handle: "caller", granted: %w[embed-*]) }
  let(:target_inst) { announce(handle: "target", declared_skills: [ { "name" => "embed-text" } ]) }

  describe ".mint! + .verify!" do
    it "mints a signed token when the A2A policy authorizes it, and verifies offline" do
      token = described_class.mint!(caller_instance: caller_inst, target_instance: target_inst, skill: "embed-text")
      expect(token.claims["sub"]).to eq(caller_inst.id)
      expect(token.claims["aud"]).to eq(target_inst.id)
      expect(token.claims["skill"]).to eq("embed-text")
      expect(token.public_key_b64).to be_present

      claims = described_class.verify!(
        envelope_json: token.envelope_json, signature_b64: token.signature_b64,
        public_key_b64: token.public_key_b64, audience: target_inst.id, skill: "embed-text"
      )
      expect(claims["jti"]).to eq(token.claims["jti"])
    end

    it "reuses one signing key per account across mints" do
      described_class.mint!(caller_instance: caller_inst, target_instance: target_inst, skill: "embed-text")
      described_class.mint!(caller_instance: caller_inst, target_instance: target_inst, skill: "embed-text")
      expect(System::PeerCapabilitySigningKey.where(account_id: account.id).count).to eq(1)
    end

    # Audit F2-06 — a broken active key (private half gone) raised a terminal
    # MissingKeyError forever: mint! only created a fresh key when NO active
    # key existed, so all A2A minting for the account was permanently bricked
    # despite the model's unused revoke!/rotated_from rotation machinery.
    context "signing-key self-heal (F2-06)" do
      def break_active_key!
        described_class.mint!(caller_instance: caller_inst, target_instance: target_inst, skill: "embed-text")
        key = System::PeerCapabilitySigningKey.active.find_by(account_id: account.id)
        key.update_columns(encrypted_credentials: nil) # private half lost (DB-fallback storage in test)
        key
      end

      it "auto-rotates when the private half is permanently lost" do
        broken = break_active_key!

        token = described_class.mint!(caller_instance: caller_inst, target_instance: target_inst, skill: "embed-text")

        expect(broken.reload).to be_revoked
        fresh = System::PeerCapabilitySigningKey.active.find_by(account_id: account.id)
        expect(fresh.id).not_to eq(broken.id)
        expect(fresh.rotated_from_id).to eq(broken.id)
        expect(token.claims["iss"]).to eq(fresh.handle)

        handles = described_class.advertised_keys_for(account).map { |k| k["handle"] }
        expect(handles).to contain_exactly(fresh.handle)
      end

      it "emits a fleet event so operators know rotation happened" do
        break_active_key!

        described_class.mint!(caller_instance: caller_inst, target_instance: target_inst, skill: "embed-text")

        events = System::FleetEvent.where(account: account, kind: "system.a2a_signing_key_rotated")
        expect(events.count).to eq(1)
        expect(events.first.payload).to include("reason" => "private_key_material_lost")
      end

      it "does not rotate on a transient Vault outage" do
        broken = break_active_key!
        allow_any_instance_of(System::PeerCapabilitySigningKey)
          .to receive(:stored_in_vault?).and_return(true)
        allow(Security::VaultClient).to receive(:healthy?).and_return(false)

        expect do
          described_class.mint!(caller_instance: caller_inst, target_instance: target_inst, skill: "embed-text")
        end.to raise_error(described_class::MissingKeyError, /not rotating/)
        expect(broken.reload).not_to be_revoked
      end
    end

    # Audit F2-04 — ttl_seconds flowed into exp unclamped, so a caller could
    # mint an effectively-permanent token while the only revocation lever
    # (rotating the account signing key) kills ALL tokens.
    it "clamps ttl_seconds to MAX_TTL_SECONDS" do
      token = described_class.mint!(
        caller_instance: caller_inst, target_instance: target_inst,
        skill: "embed-text", ttl_seconds: 999_999_999
      )

      ttl = token.claims["exp"] - token.claims["iat"]
      expect(ttl).to be <= described_class::MAX_TTL_SECONDS
    end
  end

  describe "authorization gate" do
    it "refuses to mint when the caller is not granted the skill" do
      ungranted = announce(handle: "ungranted") # no granted peer skills
      expect do
        described_class.mint!(caller_instance: ungranted, target_instance: target_inst, skill: "embed-text")
      end.to raise_error(described_class::NotAuthorizedError, /not granted/)
    end

    it "refuses cross-account minting" do
      other = create(:account)
      other_inst = announce(handle: "other", declared_skills: [ { "name" => "embed-text" } ], account: other)
      expect do
        described_class.mint!(caller_instance: caller_inst, target_instance: other_inst, skill: "embed-text")
      end.to raise_error(described_class::NotAuthorizedError)
    end
  end

  describe ".verify! rejections" do
    let(:token) { described_class.mint!(caller_instance: caller_inst, target_instance: target_inst, skill: "embed-text") }

    it "rejects a tampered envelope" do
      tampered = token.envelope_json.sub("embed-text", "embed-texX")
      expect(tampered).not_to eq(token.envelope_json)
      expect do
        described_class.verify!(envelope_json: tampered, signature_b64: token.signature_b64, public_key_b64: token.public_key_b64)
      end.to raise_error(described_class::SigningError, /signature/)
    end

    it "rejects the wrong audience" do
      expect do
        described_class.verify!(envelope_json: token.envelope_json, signature_b64: token.signature_b64,
                                public_key_b64: token.public_key_b64, audience: "someone-else")
      end.to raise_error(described_class::SigningError, /audience/)
    end

    it "rejects an expired token" do
      future = Time.current.to_i + 10_000
      expect do
        described_class.verify!(envelope_json: token.envelope_json, signature_b64: token.signature_b64,
                                public_key_b64: token.public_key_b64, now: future)
      end.to raise_error(described_class::SigningError, /expired/)
    end
  end

  describe ".advertised_keys_for" do
    it "returns the account's active public key by handle" do
      described_class.mint!(caller_instance: caller_inst, target_instance: target_inst, skill: "embed-text")
      keys = described_class.advertised_keys_for(account)
      expect(keys.size).to eq(1)
      expect(keys.first["public_key_b64"]).to be_present
      expect(keys.first["algorithm"]).to eq("ED25519")
    end
  end
end
