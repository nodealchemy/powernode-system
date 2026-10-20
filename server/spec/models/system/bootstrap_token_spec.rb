# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M0.L — BootstrapToken
RSpec.describe System::BootstrapToken, type: :model do
  let(:account)  { create(:account) }
  let(:template) { create(:system_node_template, account: account) }
  let(:node)     { create(:system_node, account: account, node_template: template) }

  describe ".issue!" do
    it "returns [model, plaintext] and only stores the SHA-256 hash" do
      token, plaintext = described_class.issue!(node: node, intended_subject: "instance-abc")

      expect(plaintext).to be_present
      expect(plaintext).to match(/\A[A-Za-z0-9_-]+\z/) # urlsafe_base64
      expect(token.token_hash).to eq(Digest::SHA256.hexdigest(plaintext))
      expect(token.expires_at).to be_within(5.seconds).of(described_class::DEFAULT_TTL.from_now)
      expect(token.intended_subject).to eq("instance-abc")
      expect(token).to be_single_use
    end

    it "honors a custom TTL and purpose" do
      token, _ = described_class.issue!(
        node: node, intended_subject: "x", ttl: 5.minutes, purpose: "cloud_seed"
      )
      expect(token.expires_at).to be_within(5.seconds).of(5.minutes.from_now)
      expect(token.purpose).to eq("cloud_seed")
    end
  end

  describe ".find_active_by_plaintext" do
    it "matches a fresh token by plaintext" do
      token, plaintext = described_class.issue!(node: node, intended_subject: "x")
      expect(described_class.find_active_by_plaintext(plaintext)).to eq(token)
    end

    it "returns nil after consumption" do
      token, plaintext = described_class.issue!(node: node, intended_subject: "x")
      token.consume!
      expect(described_class.find_active_by_plaintext(plaintext)).to be_nil
    end

    it "returns nil after expiry" do
      token, plaintext = described_class.issue!(node: node, intended_subject: "x", ttl: 1.second)
      travel 2.seconds do
        expect(described_class.find_active_by_plaintext(plaintext)).to be_nil
      end
    end
  end

  describe "#consume!" do
    it "stamps consumed_at + consumed_from_ip" do
      token, _ = described_class.issue!(node: node, intended_subject: "x")
      token.consume!(from_ip: "10.0.0.1")
      expect(token.reload.consumed_at).to be_present
      expect(token.consumed_from_ip).to eq("10.0.0.1")
    end

    it "raises on double-consumption" do
      token, _ = described_class.issue!(node: node, intended_subject: "x")
      token.consume!
      expect { token.consume! }.to raise_error(described_class::InvalidConsumption, /already consumed/)
    end

    it "raises when expired" do
      token, _ = described_class.issue!(node: node, intended_subject: "x", ttl: 1.second)
      travel 2.seconds do
        expect { token.reload.consume! }.to raise_error(described_class::InvalidConsumption, /expired/)
      end
    end
  end

  # improvement 019f5cc9 — before the FK on system_bootstrap_tokens.
  # node_instance_id was relaxed to on_delete: :nullify (see
  # db/migrate/20260713140000_nullify_node_instance_on_delete_for_system_bootstrap_tokens.rb),
  # destroying a NodeInstance that still had a token pointing at it raised
  # ActiveRecord::InvalidForeignKey — masking
  # System::InstancePoolService::PoolError, "cloud provision failed: ..."
  # behind an unrelated integrity-constraint crash whenever a pool-warming
  # provider create failed AFTER EnrollmentSeed had already issued a token
  # for the just-created (and now-orphaned) NodeInstance.
  describe "on_delete behavior when the referenced NodeInstance is destroyed" do
    it "does not raise, and nullifies node_instance_id instead of blocking the destroy" do
      instance = create(:system_node_instance, node: node)
      token, _plaintext = described_class.issue!(
        node: node, node_instance: instance, intended_subject: instance.id, purpose: "proxmox_uefi_provision"
      )

      expect { instance.destroy! }.not_to raise_error

      expect(token.reload.node_instance_id).to be_nil
      # The audit record itself (node_id, purpose, token_hash, expires_at)
      # survives — only the dangling FK is cleared.
      expect(token.node_id).to eq(node.id)
      expect(token.purpose).to eq("proxmox_uefi_provision")
    end

    it "cleans up a NodeInstance destroyed via its parent Node (the real provision_warming_member! failure path)" do
      instance = create(:system_node_instance, node: node)
      _token, _plaintext = described_class.issue!(
        node: node, node_instance: instance, intended_subject: instance.id, purpose: "proxmox_uefi_provision"
      )

      expect { node.destroy! }.not_to raise_error
      expect(System::NodeInstance.exists?(instance.id)).to be false
    end
  end

  describe "purpose" do
    it "accepts every purpose in use plus the design purposes" do
      %w[operator_key cloud_seed netboot local_qemu_provision proxmox_uefi_provision
         physical_claim federation_managed_child_accept].each do |purpose|
        expect { described_class.issue!(node: node, intended_subject: "x", purpose: purpose) }
          .not_to raise_error, "expected #{purpose} to be accepted"
      end
      expect(described_class::PURPOSES).to include("operator_key", "cloud_seed", "netboot")
    end

    it "rejects an unknown purpose" do
      expect { described_class.issue!(node: node, intended_subject: "x", purpose: "bogus") }
        .to raise_error(ActiveRecord::RecordInvalid, /purpose/i)
    end
  end

  describe "per-purpose TTL" do
    it "defaults operator_key to 24 hours" do
      token, _ = described_class.issue!(node: node, intended_subject: "x", purpose: "operator_key")
      expect(token.expires_at).to be_within(5.seconds).of(24.hours.from_now)
    end

    it "allows operator_key up to 7 days and refuses longer" do
      token, _ = described_class.issue!(node: node, intended_subject: "x", purpose: "operator_key", ttl: 7.days)
      expect(token.expires_at).to be_within(5.seconds).of(7.days.from_now)
      expect { described_class.issue!(node: node, intended_subject: "x", purpose: "operator_key", ttl: 7.days + 1.minute) }
        .to raise_error(ArgumentError, /ttl/i)
    end

    it "keeps cloud_seed and netboot at 1 hour by default" do
      %w[cloud_seed netboot].each do |purpose|
        token, _ = described_class.issue!(node: node, intended_subject: "x", purpose: purpose)
        expect(token.expires_at).to be_within(5.seconds).of(1.hour.from_now)
      end
    end

    it "caps every non-operator purpose at 1 hour" do
      (described_class::PURPOSES - %w[operator_key]).each do |purpose|
        expect(described_class.max_ttl_for(purpose)).to eq(1.hour)
        expect { described_class.issue!(node: node, intended_subject: "x", purpose: purpose, ttl: 61.minutes) }
          .to raise_error(ArgumentError, /ttl/i), "expected #{purpose} capped at 1h"
        expect { described_class.issue!(node: node, intended_subject: "x", purpose: purpose, ttl: 1.hour) }
          .not_to raise_error
      end
      expect(described_class.max_ttl_for(nil)).to eq(1.hour)
    end

    it "enforces the cap on save, not only in issue!" do
      token, _ = described_class.issue!(node: node, intended_subject: "x", purpose: "netboot")
      token.expires_at = 3.hours.from_now
      expect(token).not_to be_valid
      expect(token.errors[:expires_at]).to be_present
      expect { described_class.create!(node: node, intended_subject: "x", purpose: "cloud_seed",
                                       token_hash: "h1", expires_at: 2.hours.from_now) }
        .to raise_error(ActiveRecord::RecordInvalid, /expires at/i)
    end

    it "does not re-check the cap when an unrelated column changes (legacy rows)" do
      token, _ = described_class.issue!(node: node, intended_subject: "x", purpose: "netboot")
      token.update_columns(expires_at: 5.hours.from_now)
      expect { token.reload.consume! }.not_to raise_error
    end

    it "does not re-check the purpose on update, so a legacy row can be consumed or revoked" do
      legacy, _ = described_class.issue!(node: node, intended_subject: "x", purpose: "netboot")
      legacy.update_columns(purpose: "retired_purpose")
      expect { legacy.reload.revoke! }.not_to raise_error
      other, _ = described_class.issue!(node: node, intended_subject: "y", purpose: "netboot")
      other.update_columns(purpose: "retired_purpose")
      expect { other.reload.consume! }.not_to raise_error
    end
  end

  describe "single use only" do
    it "forces single_use for operator_key" do
      token, _ = described_class.issue!(node: node, intended_subject: "x", purpose: "operator_key")
      expect(token).to be_single_use
    end

    it "refuses to issue a multi-use token" do
      expect { described_class.issue!(node: node, intended_subject: "x", purpose: "operator_key", single_use: false) }
        .to raise_error(ActiveRecord::RecordInvalid, /single/i)
      expect { described_class.issue!(node: node, intended_subject: "x", purpose: "netboot", single_use: false) }
        .to raise_error(ActiveRecord::RecordInvalid, /single/i)
    end
  end

  describe "issuer and revocation" do
    let(:user) { create(:user, account: account) }

    it "records created_by when given and allows a machine issuer" do
      human, _   = described_class.issue!(node: node, intended_subject: "x", purpose: "operator_key", created_by: user)
      machine, _ = described_class.issue!(node: node, intended_subject: "x", purpose: "cloud_seed")
      expect(human.created_by).to eq(user)
      expect(machine.created_by).to be_nil
    end

    it "#revoke! stamps revoked_at/revoked_by and makes the token unusable" do
      token, plaintext = described_class.issue!(node: node, intended_subject: "x", purpose: "operator_key")
      token.revoke!(by: user)
      expect(token.reload.revoked_at).to be_present
      expect(token.revoked_by).to eq(user)
      expect(token).to be_revoked
      expect(token).not_to be_usable
      expect(described_class.find_active_by_plaintext(plaintext)).to be_nil
    end

    it "#consume! refuses a revoked token" do
      token, _ = described_class.issue!(node: node, intended_subject: "x", purpose: "operator_key")
      token.revoke!
      expect { token.consume! }.to raise_error(described_class::InvalidConsumption, /revoked/)
      expect(token.reload.consumed_at).to be_nil
    end

    it "#consume! refuses when a stale in-memory copy was revoked elsewhere" do
      token, _ = described_class.issue!(node: node, intended_subject: "x", purpose: "operator_key")
      stale = described_class.find(token.id)
      token.revoke!
      expect { stale.consume! }.to raise_error(described_class::InvalidConsumption, /revoked/)
    end

    it "#revoke! refuses a consumed token and is idempotent on a revoked one" do
      token, _ = described_class.issue!(node: node, intended_subject: "x", purpose: "operator_key")
      token.revoke!
      first = token.revoked_at
      expect { token.revoke! }.not_to raise_error
      expect(token.reload.revoked_at).to eq(first)

      used, _ = described_class.issue!(node: node, intended_subject: "y", purpose: "operator_key")
      used.consume!
      expect { used.revoke! }.to raise_error(described_class::InvalidConsumption, /consumed/)
    end

    it "excludes revoked tokens from .active and lists them in .revoked" do
      token, _ = described_class.issue!(node: node, intended_subject: "x", purpose: "operator_key")
      token.revoke!
      expect(described_class.active).not_to include(token)
      expect(described_class.revoked).to include(token)
    end
  end

  describe "audit hook timing" do
    it "fires issued/consumed/revoked after commit, not before" do
      node
      events = []
      allow_any_instance_of(described_class).to receive(:audit_hook) { |_, e| events << e }

      ActiveRecord::Base.transaction do
        token, _ = described_class.issue!(node: node, intended_subject: "x", purpose: "operator_key")
        token.revoke!
        expect(events).to be_empty
      end
      expect(events).to eq(%i[issued revoked])
    end

    it "fires nothing when the surrounding transaction rolls back" do
      node
      events = []
      allow_any_instance_of(described_class).to receive(:audit_hook) { |_, e| events << e }

      ActiveRecord::Base.transaction do
        described_class.issue!(node: node, intended_subject: "x", purpose: "operator_key")
        raise ActiveRecord::Rollback
      end
      expect(events).to be_empty
    end
  end

  describe "scopes" do
    it "categorizes tokens by lifecycle state" do
      fresh, _    = described_class.issue!(node: node, intended_subject: "fresh")
      consumed, _ = described_class.issue!(node: node, intended_subject: "consumed")
      consumed.consume!
      stale, _    = described_class.issue!(node: node, intended_subject: "stale", ttl: 1.second)
      travel 2.seconds do
        expect(described_class.active).to include(fresh)
        expect(described_class.active).not_to include(consumed, stale)
        expect(described_class.consumed).to  include(consumed)
        expect(described_class.expired).to   include(stale)
      end
    end
  end
end
