# frozen_string_literal: true

require "rails_helper"

# IMP-ab73cc2fca65 — POST /api/v1/system/node_api/status/sdwan must persist the
# per-peer WireGuard byte counters the agent already measures and ships.
#
# The property under test is NOT "two columns get written". It is that the
# platform can tell three states apart for every peer:
#
#   NOT MEASURED     no heartbeat has ever carried a usable counter pair for
#                    this peer -> rx_bytes / tx_bytes / counters_sampled_at
#                    are all NULL. This is also where an unparseable or
#                    negative value lands: we never fabricate an observation.
#   MEASURED, ZERO   a heartbeat carried rx_bytes: 0 -> the column holds 0.
#                    An idle tunnel is a real observation of no traffic and
#                    must never read back as "unknown".
#   MEASURED, N      the column holds exactly what the kernel reported.
#
# and that a counter RESET (interface recreated / peer re-added, so WireGuard
# restarts the totals at zero) is stored verbatim rather than clamped, because
# a monotonic guard would freeze the counter at its pre-reset high-water mark
# forever.
RSpec.describe "node_api SDWAN peer byte counters", type: :request do
  let(:account)       { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }

  let(:node_a)     { create(:system_node, account: account, node_template: node_template) }
  let(:instance_a) { create(:system_node_instance, :running, node: node_a) }
  let(:network_a)  { create(:sdwan_network, account: account) }
  let!(:peer_a)    { create(:sdwan_peer, account: account, network: network_a, node_instance: instance_a) }

  # A peer belonging to a DIFFERENT instance in the same account. Counters are
  # attacker-controllable body content, so the write must be scoped exactly as
  # the handshake write is.
  let(:node_b)     { create(:system_node, account: account, node_template: node_template) }
  let(:instance_b) { create(:system_node_instance, :running, node: node_b) }
  let(:network_b)  { create(:sdwan_network, account: account) }
  let!(:peer_b)    { create(:sdwan_peer, account: account, network: network_b, node_instance: instance_b) }

  let!(:cert_a) do
    System::NodeCertificate.create!(
      node_instance: instance_a,
      serial:         SecureRandom.hex(16),
      subject:        "CN=#{instance_a.id}",
      not_before:     1.hour.ago,
      not_after:      90.days.from_now,
      issuer_subject: "CN=Powernode Internal CA"
    )
  end

  let(:auth_headers) do
    { "X-Forwarded-Tls-Client-Cert-Info" => CGI.escape(%(Subject="CN=#{instance_a.id}")) }
  end

  def report(peers)
    post "/api/v1/system/node_api/status/sdwan",
         params: { peers: peers }.to_json,
         headers: auth_headers.merge("CONTENT_TYPE" => "application/json")
  end

  # Fetch helpers are methods, never memoized lets: every assertion must read
  # the row as it stands AFTER the request under test, not a value captured
  # before it.
  def counters_for(peer)
    peer.class.where(id: peer.id).pick(:rx_bytes, :tx_bytes, :counters_sampled_at)
  end

  def rx_for(peer) = counters_for(peer)[0]
  def tx_for(peer) = counters_for(peer)[1]
  def sampled_at_for(peer) = counters_for(peer)[2]

  describe "NOT MEASURED is the default and survives a counter-less report" do
    it "leaves all three columns NULL for a peer that has never been reported" do
      expect(counters_for(peer_a)).to eq([ nil, nil, nil ])
    end

    it "leaves them NULL when a recognized peer reports a handshake but no counters" do
      report([ { peer_id: peer_a.id, last_handshake_at: 30.seconds.ago.utc.iso8601, status: "active" } ])

      expect(response).to have_http_status(:ok)
      # the handshake half still lands — this is a counter-only absence
      expect(peer_a.reload.last_handshake_at).to be_present
      expect(counters_for(peer_a)).to eq([ nil, nil, nil ])
    end
  end

  describe "MEASURED ZERO is distinct from NOT MEASURED" do
    it "records an explicit zero as an observation, not as unknown" do
      report([ { peer_id: peer_a.id, last_handshake_at: 30.seconds.ago.utc.iso8601,
                 rx_bytes: 0, tx_bytes: 0, status: "active" } ])

      expect(response).to have_http_status(:ok)
      expect(rx_for(peer_a)).to eq(0)
      expect(tx_for(peer_a)).to eq(0)
      expect(sampled_at_for(peer_a)).to be_present
    end

    it "records non-zero counters verbatim, including values past a 32-bit column" do
      report([ { peer_id: peer_a.id, rx_bytes: 8_589_934_592, tx_bytes: 17_179_869_184 } ])

      expect(rx_for(peer_a)).to eq(8_589_934_592)
      expect(tx_for(peer_a)).to eq(17_179_869_184)
    end
  end

  describe "counter reset / rollover" do
    it "stores a LOWER subsequent sample verbatim rather than clamping to the previous high-water mark" do
      report([ { peer_id: peer_a.id, rx_bytes: 9_000, tx_bytes: 9_000 } ])
      expect(rx_for(peer_a)).to eq(9_000)

      # interface recreated: WireGuard restarts the peer totals from zero
      report([ { peer_id: peer_a.id, rx_bytes: 12, tx_bytes: 0 } ])

      expect(rx_for(peer_a)).to eq(12)
      expect(tx_for(peer_a)).to eq(0)
    end
  end

  describe "a value we cannot trust is NOT MEASURED, never a fabricated zero" do
    it "refuses a negative counter" do
      report([ { peer_id: peer_a.id, rx_bytes: -1, tx_bytes: 5 } ])

      expect(response).to have_http_status(:ok)
      expect(counters_for(peer_a)).to eq([ nil, nil, nil ])
    end

    it "refuses a non-integer counter and does not 500 a heartbeat the agent retries" do
      report([ { peer_id: peer_a.id, rx_bytes: "lots", tx_bytes: 5 } ])

      expect(response).to have_http_status(:ok)
      expect(counters_for(peer_a)).to eq([ nil, nil, nil ])
    end

    # Without this the whole `when String` branch could be deleted and every
    # other example here would still pass, while a form-encoded heartbeat
    # silently became NOT MEASURED.
    it "accepts digit strings, as a form-encoded heartbeat sends them" do
      report([ { peer_id: peer_a.id, rx_bytes: "12", tx_bytes: "0" } ])

      expect(rx_for(peer_a)).to eq(12)
      expect(tx_for(peer_a)).to eq(0)
    end

    it "refuses string shapes that are not a plain unsigned decimal" do
      [ " 12", "0x10", "1.5", "+12", "1e3" ].each do |raw|
        report([ { peer_id: peer_a.id, rx_bytes: raw, tx_bytes: raw } ])

        expect(response).to have_http_status(:ok)
        expect(counters_for(peer_a)).to eq([ nil, nil, nil ]), "accepted #{raw.inspect}"
      end
    end

    it "accepts the widest value a Go int64 can carry" do
      report([ { peer_id: peer_a.id, rx_bytes: (2**63) - 1, tx_bytes: 0 } ])

      expect(response).to have_http_status(:ok)
      expect(rx_for(peer_a)).to eq((2**63) - 1)
    end

    # ActiveModel raises RangeError on the way to a bigint column, BEFORE
    # Postgres sees it. Left unguarded that is a 500 on an endpoint the agent
    # retries forever — a body-controlled retry storm, not a bad row.
    #
    # 2**63 is pinned as well as 2**64 because 2**63 is the FIRST rejected
    # value: an off-by-one ceiling of 2**63 passes a 2**64 test and still 500s
    # in production on the one value an off-by-one actually produces.
    it "refuses a counter too wide for the column instead of 500ing the heartbeat" do
      [ 2**63, 2**64 ].each do |raw|
        report([ { peer_id: peer_a.id, rx_bytes: raw, tx_bytes: raw } ])

        expect(response).to have_http_status(:ok), "500ed on #{raw}"
        expect(counters_for(peer_a)).to eq([ nil, nil, nil ]), "accepted #{raw}"
      end
    end

    it "refuses a half-populated pair rather than recording one side" do
      report([ { peer_id: peer_a.id, rx_bytes: 500 } ])

      expect(counters_for(peer_a)).to eq([ nil, nil, nil ])
    end

    it "does not roll back a previously good sample when a later report is junk" do
      report([ { peer_id: peer_a.id, rx_bytes: 700, tx_bytes: 800 } ])
      report([ { peer_id: peer_a.id, rx_bytes: -5, tx_bytes: -5 } ])

      expect(rx_for(peer_a)).to eq(700)
      expect(tx_for(peer_a)).to eq(800)
    end
  end

  describe "scoping" do
    it "does not write counters onto a peer belonging to another instance" do
      report([ { peer_id: peer_b.id, rx_bytes: 4_242, tx_bytes: 4_242 } ])

      expect(response).to have_http_status(:ok)
      expect(counters_for(peer_b)).to eq([ nil, nil, nil ])
    end
  end

  describe "an observation is not an edit" do
    # The heartbeat writes through update_columns, exactly as the pre-existing
    # last_handshake_at write did. Were it a save instead, every peer in the
    # fleet would look edited once a minute — destroying updated_at as a "last
    # changed" signal, and separately re-running the model's after_save hooks
    # on every tick. counters_sampled_at exists precisely so the observation
    # carries its own stamp and needs neither.
    it "does not bump updated_at" do
      before_stamp = peer_a.reload.updated_at

      report([ { peer_id: peer_a.id, rx_bytes: 1, tx_bytes: 2 } ])

      expect(rx_for(peer_a)).to eq(1)
      expect(peer_a.class.where(id: peer_a.id).pick(:updated_at)).to eq(before_stamp)
    end
  end
end
