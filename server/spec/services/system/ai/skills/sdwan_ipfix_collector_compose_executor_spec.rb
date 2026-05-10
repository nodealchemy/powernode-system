# frozen_string_literal: true

require "rails_helper"

# Phase O6 of the OVS+OVN dual-profile networking roadmap.
RSpec.describe System::Ai::Skills::SdwanIpfixCollectorComposeExecutor do
  let(:account) { create(:account) }
  let(:exec)    { described_class.new(account: account) }

  describe ".descriptor" do
    it "advertises required inputs, structured outputs, and instance-method rollback" do
      d = described_class.descriptor

      expect(d[:name]).to eq("sdwan_ipfix_collector_compose")
      expect(d[:category]).to eq("devops")
      expect(d.dig(:inputs, :name, :required)).to be true
      expect(d.dig(:inputs, :host, :required)).to be true
      expect(d.dig(:inputs, :port, :required)).to be true
      expect(d.dig(:inputs, :sampling_rate, :required)).to be false
      expect(d.dig(:outputs, :outputs)).to include(:ipfix_collector_id, :created, :name,
                                                   :target_endpoint, :sampling_rate, :state,
                                                   :is_winning_collector)
      expect(d[:rollback]).to eq(:rollback_sdwan_ipfix_collector_compose)
      expect(d[:requires_approval]).to be false
      expect(d[:blast_radius]).to eq(:low)
    end
  end

  describe "#execute" do
    context "with a missing name" do
      it "rejects" do
        r = exec.execute(name: " ", host: "10.0.0.1", port: 4739)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/name is required/)
      end
    end

    context "with a missing host" do
      it "rejects" do
        r = exec.execute(name: "primary", host: " ", port: 4739)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/host is required/)
      end
    end

    context "with an out-of-range port" do
      it "rejects high" do
        r = exec.execute(name: "primary", host: "10.0.0.1", port: 99_999)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/port must be between/)
      end

      it "rejects zero" do
        r = exec.execute(name: "primary", host: "10.0.0.1", port: 0)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/port must be between/)
      end
    end

    context "with a sampling_rate < 1" do
      it "rejects" do
        r = exec.execute(name: "primary", host: "10.0.0.1", port: 4739, sampling_rate: 0)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/sampling_rate must be >= 1/)
      end
    end

    context "in dry_run mode (no existing collector)" do
      it "returns a plan + projected endpoint without persisting" do
        expect {
          r = exec.execute(name: "primary", host: "10.0.0.1", port: 4739,
                           sampling_rate: 100, dry_run: true)
          expect(r[:success]).to be true
          d = r[:data]
          expect(d[:dry_run]).to be true
          expect(d[:outputs][:created]).to be true
          expect(d[:outputs][:ipfix_collector_id]).to be_nil
          expect(d[:outputs][:target_endpoint]).to eq("10.0.0.1:4739")
          expect(d[:outputs][:is_winning_collector]).to be true
          expect(d[:planned_actions].first[:step]).to eq("create_collector")
        }.not_to change(::Sdwan::IpfixCollector, :count)
      end

      it "brackets IPv6 hosts in the projected endpoint" do
        r = exec.execute(name: "v6", host: "fd00::1", port: 4739, dry_run: true)
        expect(r[:data][:outputs][:target_endpoint]).to eq("[fd00::1]:4739")
      end
    end

    context "live execute on a fresh account" do
      it "creates the collector and reports it as the winning one" do
        r = exec.execute(name: "primary", host: "10.0.0.1", port: 4739, sampling_rate: 100)

        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:outputs][:created]).to be true
        expect(d[:outputs][:ipfix_collector_id]).to be_present
        expect(d[:outputs][:name]).to eq("primary")
        expect(d[:outputs][:target_endpoint]).to eq("10.0.0.1:4739")
        expect(d[:outputs][:sampling_rate]).to eq(100)
        expect(d[:outputs][:state]).to eq("active")
        expect(d[:outputs][:is_winning_collector]).to be true

        collector = ::Sdwan::IpfixCollector.for_account(account).first
        expect(collector).to be_present
        expect(collector.name).to eq("primary")
      end
    end

    context "live execute reusing an existing collector" do
      it "returns the existing row with created=false" do
        existing = ::Sdwan::IpfixCollector.create!(
          account_id: account.id, name: "primary", host: "10.0.0.1", port: 4739,
          sampling_rate: 1, state: "active"
        )

        r = exec.execute(name: "primary", host: "10.0.0.99", port: 9999, sampling_rate: 50)
        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:outputs][:created]).to be false
        expect(d[:outputs][:ipfix_collector_id]).to eq(existing.id)
        # Reuse does NOT mutate host/port/sampling — operator must use a
        # separate update action for that.
        expect(d[:outputs][:sampling_rate]).to eq(1)
        expect(d[:outputs][:target_endpoint]).to eq("10.0.0.1:4739")
        expect(::Sdwan::IpfixCollector.for_account(account).count).to eq(1)
      end
    end

    context "with a second collector created when one is already active" do
      it "reports is_winning_collector=false because the older row wins" do
        ::Sdwan::IpfixCollector.create!(
          account_id: account.id, name: "old-primary", host: "10.0.0.1", port: 4739,
          sampling_rate: 1, state: "active", created_at: 1.hour.ago
        )

        r = exec.execute(name: "newcomer", host: "10.0.0.2", port: 4739)
        expect(r[:success]).to be true
        expect(r[:data][:outputs][:created]).to be true
        expect(r[:data][:outputs][:is_winning_collector]).to be false
      end
    end
  end

  describe "#rollback_sdwan_ipfix_collector_compose" do
    it "destroys only newly-created collectors" do
      r = exec.execute(name: "doomed", host: "10.0.0.1", port: 4739)
      cid = r[:data][:outputs][:ipfix_collector_id]
      expect(::Sdwan::IpfixCollector.find_by(id: cid)).to be_present

      rb = exec.rollback_sdwan_ipfix_collector_compose(
        ipfix_collector_id: cid, created: true
      )

      expect(rb[:success]).to be true
      expect(::Sdwan::IpfixCollector.find_by(id: cid)).to be_nil
    end

    it "leaves re-used collectors alone" do
      existing = ::Sdwan::IpfixCollector.create!(
        account_id: account.id, name: "keepable", host: "10.0.0.1", port: 4739,
        sampling_rate: 1, state: "active"
      )
      r = exec.execute(name: "keepable", host: "10.0.0.1", port: 4739)
      expect(r[:data][:outputs][:created]).to be false

      exec.rollback_sdwan_ipfix_collector_compose(
        ipfix_collector_id: r[:data][:outputs][:ipfix_collector_id],
        created: false
      )

      expect(::Sdwan::IpfixCollector.find_by(id: existing.id)).to be_present
    end
  end
end
