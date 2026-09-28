# frozen_string_literal: true

require "rails_helper"

# IMP-ab73cc2fca65 — POST /api/v1/system/node_api/status/sdwan must persist the
# per-peer WireGuard byte counters the agent already measures and ships.
#
# IMP-329f2438cc8d — REWRITTEN to post the COUNTERPART's peer id, as the real
# agent does (Sdwan::PeerEntry.build's `peer_id: peer.id` names the REMOTE
# peer — agent/internal/sdwan/manager.go's peerReportsFromActual — never the
# reporter's own row). The pre-fix spec posted `peer_id: peer_a.id` from
# instance_a's own auth context, a payload the agent never sends; the old
# `own_peers_by_id` scope matched only that shape, so every real heartbeat's
# handshake/counters silently vanished behind a 200 `reported: 0`.
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
#
# DIRECTION: the counters a report carries are measured by the REPORTER, from
# the reporter's OWN wg show — rx is what the reporter received FROM the
# reported peer, tx is what it SENT to the reported peer. Every test below
# that uses an ASYMMETRIC (rx != tx) pair therefore expects the columns
# SWAPPED on write, so the stored row stays in the REPORTED peer's own
# perspective (see Sdwan::Peer#observed_traffic's doc and
# SdwanController#peer_observation_columns' "DIRECTION IS SWAPPED ON WRITE").
RSpec.describe "node_api SDWAN peer byte counters", type: :request do
  let(:account)       { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }

  # instance_a and instance_b PEER ON THE SAME NETWORK (network_ab) — a
  # genuine hub/spoke pair. This is the shape a real agent heartbeat reports
  # on: instance_a's own WireGuard interface has a live session with
  # instance_b's peer row, so instance_a reports handshake/counter data
  # using peer_b's id (the COUNTERPART), never peer_a's own id.
  let(:network_ab) { create(:sdwan_network, account: account) }

  let(:node_a)     { create(:system_node, account: account, node_template: node_template) }
  let(:instance_a) { create(:system_node_instance, :running, node: node_a) }
  let!(:peer_a)    { create(:sdwan_peer, :hub, account: account, network: network_ab, node_instance: instance_a) }

  let(:node_b)     { create(:system_node, account: account, node_template: node_template) }
  let(:instance_b) { create(:system_node_instance, :running, node: node_b) }
  let!(:peer_b)    { create(:sdwan_peer, account: account, network: network_ab, node_instance: instance_b) }

  # A peer belonging to a DIFFERENT instance on a DIFFERENT network — instance_a
  # holds NO peer there at all. Counters (and handshakes) are
  # attacker-controllable body content, so the write must be scoped exactly:
  # a caller can only ever name a peer on a network it itself belongs to.
  let(:node_c)     { create(:system_node, account: account, node_template: node_template) }
  let(:instance_c) { create(:system_node_instance, :running, node: node_c) }
  let(:network_c)  { create(:sdwan_network, account: account) }
  let!(:peer_c)    { create(:sdwan_peer, account: account, network: network_c, node_instance: instance_c) }

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

  def reported_count
    JSON.parse(response.body)["data"]["reported"]
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
      expect(counters_for(peer_b)).to eq([ nil, nil, nil ])
    end

    it "leaves them NULL when a recognized counterpart reports a handshake but no counters" do
      report([ { peer_id: peer_b.id, last_handshake_at: 30.seconds.ago.utc.iso8601, status: "active" } ])

      expect(response).to have_http_status(:ok)
      # the handshake half still lands — this is a counter-only absence
      expect(peer_b.reload.last_handshake_at).to be_present
      expect(counters_for(peer_b)).to eq([ nil, nil, nil ])
    end
  end

  describe "MEASURED ZERO is distinct from NOT MEASURED" do
    it "records an explicit zero as an observation, not as unknown" do
      report([ { peer_id: peer_b.id, last_handshake_at: 30.seconds.ago.utc.iso8601,
                 rx_bytes: 0, tx_bytes: 0, status: "active" } ])

      expect(response).to have_http_status(:ok)
      expect(rx_for(peer_b)).to eq(0)
      expect(tx_for(peer_b)).to eq(0)
      expect(sampled_at_for(peer_b)).to be_present
    end

    it "records non-zero counters verbatim (direction-swapped), including values past a 32-bit column" do
      report([ { peer_id: peer_b.id, rx_bytes: 8_589_934_592, tx_bytes: 17_179_869_184 } ])

      # reporter's tx (what it SENT to B) is B's rx; reporter's rx is B's tx.
      expect(rx_for(peer_b)).to eq(17_179_869_184)
      expect(tx_for(peer_b)).to eq(8_589_934_592)
    end
  end

  describe "counter direction is swapped into the reported peer's own perspective" do
    it "stores the reporter's tx as the reported peer's rx, and the reporter's rx as its tx" do
      report([ { peer_id: peer_b.id, rx_bytes: 1_000, tx_bytes: 2_000 } ])

      expect(rx_for(peer_b)).to eq(2_000) # what instance_a SENT to B is what B RECEIVED
      expect(tx_for(peer_b)).to eq(1_000) # what instance_a RECEIVED from B is what B SENT
    end
  end

  describe "counter reset / rollover" do
    it "stores a LOWER subsequent sample verbatim rather than clamping to the previous high-water mark" do
      report([ { peer_id: peer_b.id, rx_bytes: 9_000, tx_bytes: 9_000 } ])
      expect(rx_for(peer_b)).to eq(9_000)
      expect(tx_for(peer_b)).to eq(9_000)

      # interface recreated: WireGuard restarts the peer totals from zero
      report([ { peer_id: peer_b.id, rx_bytes: 12, tx_bytes: 0 } ])

      expect(rx_for(peer_b)).to eq(0)  # reporter's tx
      expect(tx_for(peer_b)).to eq(12) # reporter's rx
    end
  end

  describe "a value we cannot trust is NOT MEASURED, never a fabricated zero" do
    it "refuses a negative counter" do
      report([ { peer_id: peer_b.id, rx_bytes: -1, tx_bytes: 5 } ])

      expect(response).to have_http_status(:ok)
      expect(reported_count).to eq(1)
      expect(counters_for(peer_b)).to eq([ nil, nil, nil ])
    end

    it "refuses a non-integer counter and does not 500 a heartbeat the agent retries" do
      report([ { peer_id: peer_b.id, rx_bytes: "lots", tx_bytes: 5 } ])

      expect(response).to have_http_status(:ok)
      expect(reported_count).to eq(1)
      expect(counters_for(peer_b)).to eq([ nil, nil, nil ])
    end

    # Without this the whole `when String` branch could be deleted and every
    # other example here would still pass, while a form-encoded heartbeat
    # silently became NOT MEASURED.
    it "accepts digit strings, as a form-encoded heartbeat sends them" do
      report([ { peer_id: peer_b.id, rx_bytes: "12", tx_bytes: "0" } ])

      expect(reported_count).to eq(1)
      expect(rx_for(peer_b)).to eq(0)  # reporter's tx
      expect(tx_for(peer_b)).to eq(12) # reporter's rx
    end

    it "refuses string shapes that are not a plain unsigned decimal" do
      [ " 12", "0x10", "1.5", "+12", "1e3" ].each do |raw|
        report([ { peer_id: peer_b.id, rx_bytes: raw, tx_bytes: raw } ])

        expect(response).to have_http_status(:ok)
        expect(reported_count).to eq(1), "peer not recognized for #{raw.inspect}"
        expect(counters_for(peer_b)).to eq([ nil, nil, nil ]), "accepted #{raw.inspect}"
      end
    end

    it "accepts the widest value a Go int64 can carry" do
      report([ { peer_id: peer_b.id, rx_bytes: (2**63) - 1, tx_bytes: 0 } ])

      expect(response).to have_http_status(:ok)
      expect(reported_count).to eq(1)
      expect(rx_for(peer_b)).to eq(0)              # reporter's tx
      expect(tx_for(peer_b)).to eq((2**63) - 1)    # reporter's rx
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
        report([ { peer_id: peer_b.id, rx_bytes: raw, tx_bytes: raw } ])

        expect(response).to have_http_status(:ok), "500ed on #{raw}"
        expect(reported_count).to eq(1), "peer not recognized for #{raw}"
        expect(counters_for(peer_b)).to eq([ nil, nil, nil ]), "accepted #{raw}"
      end
    end

    it "refuses a half-populated pair rather than recording one side" do
      report([ { peer_id: peer_b.id, rx_bytes: 500 } ])

      expect(reported_count).to eq(1)
      expect(counters_for(peer_b)).to eq([ nil, nil, nil ])
    end

    it "does not roll back a previously good sample when a later report is junk" do
      report([ { peer_id: peer_b.id, rx_bytes: 700, tx_bytes: 800 } ])
      expect(reported_count).to eq(1)

      report([ { peer_id: peer_b.id, rx_bytes: -5, tx_bytes: -5 } ])
      expect(reported_count).to eq(1)

      expect(rx_for(peer_b)).to eq(800) # reporter's tx from the FIRST (good) report
      expect(tx_for(peer_b)).to eq(700) # reporter's rx from the FIRST (good) report
    end
  end

  describe "tenancy" do
    it "does not write counters (or a handshake) onto a peer on a network the caller does not belong to" do
      report([ { peer_id: peer_c.id, last_handshake_at: 30.seconds.ago.utc.iso8601,
                 rx_bytes: 4_242, tx_bytes: 4_242 } ])

      expect(response).to have_http_status(:ok)
      expect(peer_c.reload.last_handshake_at).to be_nil
      expect(counters_for(peer_c)).to eq([ nil, nil, nil ])
    end

    # Regression: this is the ORIGINAL spec's whole payload shape. It is not
    # what the real agent sends (peerReportsFromActual never reports the
    # reporter's OWN peer id), but nothing about #reportable_peers_by_id's
    # scope makes it stop working — a caller's own peer row is trivially "a
    # peer on a network the caller belongs to".
    it "still accepts a report naming the caller's OWN peer id" do
      report([ { peer_id: peer_a.id, last_handshake_at: 30.seconds.ago.utc.iso8601,
                 rx_bytes: 111, tx_bytes: 222 } ])

      expect(response).to have_http_status(:ok)
      expect(peer_a.reload.last_handshake_at).to be_present
      expect(rx_for(peer_a)).to eq(222) # reporter's tx
      expect(tx_for(peer_a)).to eq(111) # reporter's rx
    end
  end

  describe "handshake monotonicity and clock bounds" do
    # IMP-329f2438cc8d review round item 2: the ORIGINAL version of this test
    # used `older = 5.minutes.ago`, which is EXACTLY MAX_HANDSHAKE_CLOCK_SKEW
    # — combined with iso8601 truncating the fractional second (always
    # rounding down), that landed at or past the peer's OWN created_at lower
    # bound, so the report was rejected by the LOWER-BOUND check, not by
    # monotonicity — removing the `observed > peer.last_handshake_at` guard
    # entirely still passed. `older` here is 1 minute ago: comfortably clear
    # of the peer's created_at (created moments before this example runs, so
    # created_at - 5.minutes is many minutes further back), so the ONLY thing
    # that can reject it is the fresher value already on the row.
    it "does not regress last_handshake_at when a later report replays an older observation" do
      fresher = 10.seconds.ago.change(usec: 0)
      older   = 1.minute.ago.change(usec: 0)

      report([ { peer_id: peer_b.id, last_handshake_at: fresher.iso8601 } ])
      expect(peer_b.reload.last_handshake_at).to be_within(1.second).of(fresher)

      report([ { peer_id: peer_b.id, last_handshake_at: older.iso8601 } ])

      expect(peer_b.reload.last_handshake_at).to be_within(1.second).of(fresher)
    end

    it "refuses a handshake timestamp further in the future than the clock-skew allowance" do
      report([ { peer_id: peer_b.id, last_handshake_at: (Time.current + 1.hour).iso8601 } ])

      expect(response).to have_http_status(:ok)
      expect(peer_b.reload.last_handshake_at).to be_nil
    end

    it "accepts a handshake timestamp within the clock-skew allowance" do
      report([ { peer_id: peer_b.id, last_handshake_at: (Time.current + 30.seconds).iso8601 } ])

      expect(peer_b.reload.last_handshake_at).to be_present
    end

    # The nil-column path is covered above; this is the ALREADY-SET path —
    # both must refuse a too-far-future value, since GREATEST(existing,
    # future_value) would otherwise happily advance a good handshake to a
    # fabricated one.
    it "refuses a too-far-future timestamp even when the column already holds a good value" do
      good = 10.seconds.ago.change(usec: 0)
      report([ { peer_id: peer_b.id, last_handshake_at: good.iso8601 } ])
      expect(peer_b.reload.last_handshake_at).to be_within(1.second).of(good)

      report([ { peer_id: peer_b.id, last_handshake_at: (Time.current + 1.hour).iso8601 } ])

      expect(peer_b.reload.last_handshake_at).to be_within(1.second).of(good)
    end

    it "does not 500 and does not fabricate Time.current on a malformed timestamp" do
      report([ { peer_id: peer_b.id, last_handshake_at: "not-a-time" } ])

      expect(response).to have_http_status(:ok)
      expect(peer_b.reload.last_handshake_at).to be_nil
    end

    # The device arm's record_device_handshake! has always refused a
    # handshake predating the subject's own creation (a handshake cannot
    # precede the key existing); the peer arm now carries the identical
    # guard, but had no direct coverage of it.
    it "refuses a handshake timestamp predating the peer's own creation" do
      too_old = (peer_b.created_at - 1.hour).iso8601

      report([ { peer_id: peer_b.id, last_handshake_at: too_old } ])

      expect(response).to have_http_status(:ok)
      expect(peer_b.reload.last_handshake_at).to be_nil
    end
  end

  describe "a counterpart report is the live signal that flips status" do
    it "flips peer_b from pending to active, in both the response and after reload" do
      expect(peer_b.status).to eq("pending")

      report([ { peer_id: peer_b.id, last_handshake_at: 5.seconds.ago.utc.iso8601 } ])

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)["data"]
      entry = body["peers"].find { |p| p["peer_id"] == peer_b.id }
      expect(entry["status"]).to eq("active")
      expect(peer_b.reload.status).to eq("active")
    end
  end

  describe "counters ambiguity: a network with more than one possible reporter/reportee pairing" do
    # A THIRD peer joins network_ab, so peer_a (the hub) now has TWO spokes
    # (peer_b and peer_d) — a report naming peer_a's id could legitimately
    # come from either spoke, each measuring a DIFFERENT link. Kept simple
    # (see counters_unambiguous_for?'s own doc): the withholding is decided
    # by the NETWORK's total peer count, not by deriving which specific row
    # is the fanned-out one — so once a third peer joins, EVERY peer on that
    # network has its counters withheld, including peer_b, whose own link to
    # the hub is individually still unambiguous. That is intentionally
    # conservative rather than maximally precise. Handshakes are unaffected
    # either way and still update from whichever peer reports.
    let(:node_d)     { create(:system_node, account: account, node_template: node_template) }
    let(:instance_d) { create(:system_node_instance, :running, node: node_d) }
    let!(:peer_d)    { create(:sdwan_peer, account: account, network: network_ab, node_instance: instance_d) }

    it "still updates the handshake but withholds counters for the ambiguous (fan-out) hub peer" do
      report([ { peer_id: peer_a.id, last_handshake_at: 5.seconds.ago.utc.iso8601,
                 rx_bytes: 999, tx_bytes: 999 } ])

      expect(response).to have_http_status(:ok)
      expect(peer_a.reload.last_handshake_at).to be_present
      expect(counters_for(peer_a)).to eq([ nil, nil, nil ])
    end

    it "also withholds counters for a spoke on the same fanned-out network, conservatively" do
      report([ { peer_id: peer_b.id, last_handshake_at: 5.seconds.ago.utc.iso8601,
                 rx_bytes: 111, tx_bytes: 222 } ])

      expect(response).to have_http_status(:ok)
      expect(peer_b.reload.last_handshake_at).to be_present
      expect(counters_for(peer_b)).to eq([ nil, nil, nil ])
    end
  end

  describe "an observation is not an edit" do
    # The heartbeat write (a conditional/GREATEST raw UPDATE — see
    # SdwanController#apply_peer_observation!) never touches updated_at,
    # exactly as the original plain update_columns write did. Were it a save
    # instead, every peer in the fleet would look edited once a minute —
    # destroying updated_at as a "last changed" signal, and separately
    # re-running the model's after_save hooks on every tick.
    # counters_sampled_at exists precisely so the observation carries its own
    # stamp and needs neither.
    it "does not bump updated_at" do
      before_stamp = peer_b.reload.updated_at

      report([ { peer_id: peer_b.id, rx_bytes: 1, tx_bytes: 2 } ])

      expect(rx_for(peer_b)).to eq(2) # reporter's tx
      expect(peer_b.class.where(id: peer_b.id).pick(:updated_at)).to eq(before_stamp)
    end
  end
end
