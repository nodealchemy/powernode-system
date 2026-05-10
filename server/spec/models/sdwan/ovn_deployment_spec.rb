# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::OvnDeployment, type: :model do
  let(:account) { Account.first || create(:account) }

  before do
    Sdwan::OvnDeployment.where(account_id: account.id).delete_all
  end

  def build_deployment(overrides = {})
    described_class.new({
      account: account,
      nb_db_endpoint: "tcp:10.0.0.1:6641",
      sb_db_endpoint: "tcp:10.0.0.1:6642",
      northd_host: "fd00::1"
    }.merge(overrides))
  end

  describe "validations" do
    it "is valid with endpoints + account" do
      expect(build_deployment).to be_valid
    end

    it "is valid in pending state with blank endpoints" do
      d = build_deployment(nb_db_endpoint: nil, sb_db_endpoint: nil)
      expect(d.status).to eq("pending")
      expect(d).to be_valid
    end

    it "rejects blank endpoints once status is bootstrapping" do
      d = build_deployment(nb_db_endpoint: nil, sb_db_endpoint: nil, status: "bootstrapping")
      expect(d).not_to be_valid
      expect(d.errors[:nb_db_endpoint]).to be_present
      expect(d.errors[:sb_db_endpoint]).to be_present
    end

    it "rejects malformed endpoints" do
      d = build_deployment(nb_db_endpoint: "10.0.0.1:6641") # missing scheme
      expect(d).not_to be_valid
      expect(d.errors[:nb_db_endpoint]).to be_present
    end

    it "accepts ssl: and unix: schemes alongside tcp:" do
      expect(build_deployment(nb_db_endpoint: "ssl:10.0.0.1:6641")).to be_valid
      expect(build_deployment(nb_db_endpoint: "unix:/var/run/ovn/ovnnb_db.sock")).to be_valid
    end

    it "enforces uniqueness on account_id (one deployment per account in O3)" do
      build_deployment.save!
      collision = build_deployment(nb_db_endpoint: "tcp:10.0.0.2:6641",
                                   sb_db_endpoint: "tcp:10.0.0.2:6642")
      expect(collision).not_to be_valid
      expect(collision.errors[:account_id]).to include("has already been taken")
    end

    it "rejects unknown status values" do
      d = build_deployment(status: "ghost")
      expect(d).not_to be_valid
      expect(d.errors[:status]).to be_present
    end
  end

  describe "AASM lifecycle" do
    let(:deployment) { build_deployment.tap(&:save!) }

    it "starts in :pending" do
      expect(deployment.status).to eq("pending")
    end

    it "transitions pending → bootstrapping and stamps bootstrapped_at" do
      expect { deployment.start_bootstrap! }
        .to change(deployment, :status).from("pending").to("bootstrapping")
      expect(deployment.bootstrapped_at).to be_present
    end

    it "transitions bootstrapping → active and stamps activated_at" do
      deployment.start_bootstrap!
      expect { deployment.mark_active! }
        .to change(deployment, :status).from("bootstrapping").to("active")
      expect(deployment.activated_at).to be_present
    end

    it "transitions active → degraded and stamps degraded_at" do
      deployment.start_bootstrap!
      deployment.mark_active!
      expect { deployment.mark_degraded! }
        .to change(deployment, :status).from("active").to("degraded")
      expect(deployment.degraded_at).to be_present
    end

    it "readopt clears degraded_at and returns to active" do
      deployment.start_bootstrap!
      deployment.mark_active!
      deployment.mark_degraded!
      expect(deployment.degraded_at).to be_present

      deployment.readopt!
      expect(deployment.status).to eq("active")
      expect(deployment.degraded_at).to be_nil
    end

    it "mark_active from degraded clears degraded_at" do
      deployment.start_bootstrap!
      deployment.mark_active!
      deployment.mark_degraded!
      deployment.mark_active!
      expect(deployment.status).to eq("active")
      expect(deployment.degraded_at).to be_nil
    end
  end

  describe "scopes" do
    let!(:d_pending) { build_deployment.tap(&:save!) }

    after do
      Account.where.not(id: account.id).find_each do |a|
        Sdwan::OvnDeployment.where(account_id: a.id).delete_all
      end
    end

    it "pending returns only pending rows" do
      expect(described_class.pending.pluck(:id)).to include(d_pending.id)
    end

    it "active returns only active rows" do
      d_pending.start_bootstrap!
      d_pending.mark_active!
      expect(described_class.active.pluck(:id)).to include(d_pending.id)
      expect(described_class.pending.pluck(:id)).not_to include(d_pending.id)
    end

    it "for_account scopes to a single account" do
      expect(described_class.for_account(account).pluck(:id))
        .to contain_exactly(d_pending.id)
    end
  end

  describe "DB-level guards" do
    it "the check constraint rejects unknown status values" do
      d = build_deployment.tap(&:save!)
      d.status = "ghost"
      expect { d.save(validate: false) }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "the unique index rejects a second row for the same account" do
      build_deployment.save!
      dup = build_deployment(nb_db_endpoint: "tcp:10.0.0.2:6641",
                             sb_db_endpoint: "tcp:10.0.0.2:6642")
      expect { dup.save(validate: false) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "associations" do
    it "destroys child logical switches on destroy" do
      d = build_deployment.tap(&:save!)
      Sdwan::OvnLogicalSwitch.create!(
        account: account,
        sdwan_ovn_deployment_id: d.id,
        name: "ls1"
      )
      expect { d.destroy }.to change(Sdwan::OvnLogicalSwitch, :count).by(-1)
    end
  end
end
