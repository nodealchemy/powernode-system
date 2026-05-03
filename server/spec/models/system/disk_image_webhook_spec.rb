# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::DiskImageWebhook, type: :model do
  let(:account) { create(:account) }

  describe ".create_with_secret!" do
    it "returns the persisted record AND the plaintext secret" do
      webhook, secret = described_class.create_with_secret!(
        account: account, label: "main-ci"
      )
      expect(webhook).to be_persisted
      expect(secret).to start_with("pndis_")
      expect(secret.length).to be > 20
    end

    it "stores secret_preview as the first 8 chars of the plaintext" do
      webhook, secret = described_class.create_with_secret!(
        account: account, label: "release-pipeline"
      )
      expect(webhook.secret_preview).to eq(secret[0, 8])
    end

    it "encrypts the secret column at rest" do
      _webhook, secret = described_class.create_with_secret!(
        account: account, label: "encrypted-test"
      )
      # The raw column value should be the encrypted ciphertext, NOT the plaintext.
      raw_row = ActiveRecord::Base.connection.execute(
        "SELECT secret FROM system_disk_image_webhooks WHERE label = 'encrypted-test'"
      ).first
      expect(raw_row["secret"]).not_to eq(secret)
    end
  end

  describe "#verify_signature" do
    let!(:webhook_pair) { described_class.create_with_secret!(account: account, label: "verify-test") }
    let(:webhook) { webhook_pair[0] }
    let(:secret) { webhook_pair[1] }
    let(:body) { '{"platform_name":"test","sha256":"abc"}' }
    let(:good_sig) { "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, body)}" }

    it "accepts a correctly signed body" do
      expect(webhook.verify_signature(body, good_sig)).to be true
    end

    it "accepts the bare hex variant (no sha256= prefix)" do
      bare = OpenSSL::HMAC.hexdigest("SHA256", secret, body)
      expect(webhook.verify_signature(body, bare)).to be true
    end

    it "rejects a mismatched signature" do
      expect(webhook.verify_signature(body, "sha256=deadbeef")).to be false
    end

    it "rejects a missing header" do
      expect(webhook.verify_signature(body, nil)).to be false
      expect(webhook.verify_signature(body, "")).to be false
    end

    it "rejects when body is empty" do
      expect(webhook.verify_signature(nil, good_sig)).to be false
      expect(webhook.verify_signature("", good_sig)).to be false
    end

    it "uses constant-time comparison (does not raise on garbage input)" do
      # ActiveSupport::SecurityUtils.secure_compare needs strings the same
      # length — with a sha256 header that's the wrong length we expect
      # graceful rejection, not an exception.
      expect(webhook.verify_signature(body, "sha256=tooshort")).to be false
    end
  end

  describe "#rotate_secret!" do
    let!(:webhook_pair) { described_class.create_with_secret!(account: account, label: "rotate-test") }
    let(:webhook) { webhook_pair[0] }
    let(:original_secret) { webhook_pair[1] }
    let(:body) { "{}" }

    it "returns a new plaintext secret different from the original" do
      new_secret = webhook.rotate_secret!
      expect(new_secret).not_to eq(original_secret)
      expect(new_secret).to start_with("pndis_")
    end

    it "invalidates the prior signature" do
      webhook.rotate_secret!
      old_sig = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', original_secret, body)}"
      expect(webhook.verify_signature(body, old_sig)).to be false
    end

    it "validates new signatures against the rotated secret" do
      new_secret = webhook.rotate_secret!
      new_sig = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', new_secret, body)}"
      expect(webhook.verify_signature(body, new_sig)).to be true
    end

    it "stamps last_rotated_at" do
      freeze_time do
        webhook.rotate_secret!
        expect(webhook.reload.last_rotated_at).to eq(Time.current)
      end
    end

    it "updates secret_preview to match the new plaintext" do
      new_secret = webhook.rotate_secret!
      expect(webhook.secret_preview).to eq(new_secret[0, 8])
    end
  end

  describe "#record_received!" do
    let!(:webhook) { create(:system_disk_image_webhook, account: account) }

    it "increments received_count" do
      expect { webhook.record_received! }.to change { webhook.reload.received_count }.by(1)
    end

    it "stamps last_received_at" do
      freeze_time do
        webhook.record_received!
        expect(webhook.reload.last_received_at).to eq(Time.current)
      end
    end
  end

  describe "validations" do
    it "requires unique label per account (case-insensitive)" do
      create(:system_disk_image_webhook, account: account, label: "ci-main")
      dup = build(:system_disk_image_webhook, account: account, label: "CI-MAIN")
      expect(dup).not_to be_valid
      expect(dup.errors[:label]).to be_present
    end

    it "allows the same label across different accounts" do
      other_account = create(:account)
      create(:system_disk_image_webhook, account: account, label: "ci-main")
      cross = build(:system_disk_image_webhook, account: other_account, label: "ci-main")
      expect(cross).to be_valid
    end

    it "rejects unknown status values" do
      invalid = build(:system_disk_image_webhook, account: account, status: "bogus")
      expect(invalid).not_to be_valid
      expect(invalid.errors[:status]).to be_present
    end
  end

  describe "scopes" do
    it ".active returns only active rows" do
      a = create(:system_disk_image_webhook, account: account, status: "active")
      _b = create(:system_disk_image_webhook, account: account, status: "disabled")
      _c = create(:system_disk_image_webhook, account: account, status: "revoked")
      expect(described_class.active.pluck(:id)).to eq([a.id])
    end
  end
end
