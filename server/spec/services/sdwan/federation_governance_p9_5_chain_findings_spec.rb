# frozen_string_literal: true

require "rails_helper"

# P9.5 — Multi-hop migration chain findings in Sdwan::FederationGovernance#scan.
# Covers migration_chain_stalled + migration_chain_failed kinds.
RSpec.describe ::Sdwan::FederationGovernance, type: :service do
  let(:account) { create(:account) }

  def make_peer(label)
    ::System::FederationPeer.create!(
      account: account,
      remote_instance_url: "https://#{label}-#{SecureRandom.hex(4)}.example.com",
      peer_kind: "platform",
      spawn_role: "symmetric", spawn_mode: "out_of_band",
      status: "active"
    )
  end

  let(:peer_b) { make_peer("b") }
  let(:peer_c) { make_peer("c") }

  def compose_chain
    ::System::Migrations::ChainComposer.compose!(
      account: account,
      hop_peer_ids: [ nil, peer_b.id, peer_c.id ],
      root_resource_kind: "skill",
      root_resource_id: SecureRandom.uuid
    ).chain
  end

  describe "migration_chain_stalled" do
    it "flags in_flight chains with no progress beyond the stall threshold" do
      chain = compose_chain
      # Set in_flight 2h ago, but rewrite the audit_log so the most
      # recent entry's timestamp is also 2h ago (the composer stamped
      # `at => now` on the chain_composed entry).
      chain.update!(
        status:        "in_flight",
        started_at:    2.hours.ago,
        audit_log:     [ { "event" => "chain_started", "at" => 2.hours.ago.iso8601 } ]
      )

      findings = described_class.scan(account: account)
      kinds = findings.map { |f| f[:kind] }
      expect(kinds).to include(:migration_chain_stalled)

      f = findings.find { |x| x[:kind] == :migration_chain_stalled }
      expect(f[:severity]).to eq(:medium)
      expect(f[:payload][:migration_chain_id]).to eq(chain.id)
    end

    it "does NOT flag chains with recent audit activity" do
      chain = compose_chain
      chain.update!(
        status:    "in_flight",
        started_at: 2.hours.ago,
        audit_log: [
          { "event" => "chain_started", "at" => 2.hours.ago.iso8601 },
          { "event" => "hop_applied",   "at" => 2.minutes.ago.iso8601 }
        ]
      )
      findings = described_class.scan(account: account)
      expect(findings.map { |f| f[:kind] }).not_to include(:migration_chain_stalled)
    end

    it "does NOT flag planned chains" do
      compose_chain # status: "planned" by default
      findings = described_class.scan(account: account)
      expect(findings.map { |f| f[:kind] }).not_to include(:migration_chain_stalled)
    end
  end

  describe "migration_chain_failed" do
    it "flags chains that failed in the recent visibility window" do
      chain = compose_chain
      chain.update!(
        status:        "failed",
        started_at:    1.day.ago,
        failed_at:     2.hours.ago,
        error_message: "remote NACK at hop 1"
      )

      findings = described_class.scan(account: account)
      f = findings.find { |x| x[:kind] == :migration_chain_failed }
      expect(f).not_to be_nil
      expect(f[:severity]).to eq(:high)
      expect(f[:payload][:migration_chain_id]).to eq(chain.id)
      expect(f[:message]).to match(/remote NACK/)
    end

    it "does NOT flag long-ago failed chains (past visibility window)" do
      chain = compose_chain
      chain.update!(
        status:    "failed",
        started_at: 30.days.ago,
        failed_at:  10.days.ago,
        error_message: "ancient"
      )
      findings = described_class.scan(account: account)
      expect(findings.map { |f| f[:kind] }).not_to include(:migration_chain_failed)
    end

    it "does NOT flag cancelled chains" do
      chain = compose_chain
      chain.update!(status: "cancelled")
      findings = described_class.scan(account: account)
      expect(findings.map { |f| f[:kind] }).not_to include(:migration_chain_failed)
    end
  end
end
