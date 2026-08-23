# frozen_string_literal: true

require "rails_helper"

# IMP-6fe639b14797 — user-device liveness.
#
# The hub's compiled peer view includes every active user device with
# `peer_id: <UserDevice#id>` (Sdwan::TopologyStrategies::HubAndSpoke#hub_view),
# so the agent maps their pubkeys and POSTs a PeerStatusReport for them on
# every tick. #report used to look up ONLY Sdwan::Peer, so a device report was
# silently dropped and `system_sdwan_user_devices.last_seen_at` — serialized to
# operators on both REST and MCP — was permanently nil.
#
# Two properties are pinned here and they matter more than the happy path:
#
#   TENANCY — the reporting instance supplies the peer id, so it is
#   attacker-controllable input. The device lookup is scoped to networks THIS
#   instance hubs; an instance must not touch a device on any other network,
#   and must not be able to tell (from the response) whether such a device
#   exists at all.
#
#   ORACLE — last_seen_at means "a handshake was OBSERVED at T", never "a
#   report mentioning this device arrived". It is derived solely from the
#   agent's `last_handshake_at` field (RFC3339, "" when the peer has never
#   handshaked — agent/internal/sdwan/state.go:260). No handshake ⇒ no write.
RSpec.describe "Api::V1::System::NodeApi::Sdwan user-device liveness", type: :request do
  let(:account)       { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }

  # Instance A — the authenticated caller — is the HUB of network_a.
  let(:node_a)     { create(:system_node, account: account, node_template: node_template) }
  let(:instance_a) { create(:system_node_instance, :running, node: node_a) }
  let(:network_a)  { create(:sdwan_network, account: account) }
  let!(:hub_a)     { create(:sdwan_peer, :hub, account: account, network: network_a, node_instance: instance_a) }

  # Instance B — a different instance in the SAME account — hubs network_b.
  # Same-account is the harder case: account scoping alone would let A through.
  let(:node_b)     { create(:system_node, account: account, node_template: node_template) }
  let(:instance_b) { create(:system_node_instance, :running, node: node_b) }
  let(:network_b)  { create(:sdwan_network, account: account) }
  let!(:hub_b)     { create(:sdwan_peer, :hub, account: account, network: network_b, node_instance: instance_b) }

  let(:grant_a)  { create(:sdwan_access_grant, account: account, network: network_a) }
  let(:grant_b)  { create(:sdwan_access_grant, account: account, network: network_b) }
  let!(:device_a) { create(:sdwan_user_device, access_grant: grant_a) }
  let!(:device_b) { create(:sdwan_user_device, access_grant: grant_b) }

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

  # A real device is issued well before it ever handshakes. Factory rows are
  # created milliseconds ago, which would put every realistic handshake below
  # the "a handshake cannot predate the device" bound and make the age-based
  # examples below pass for the wrong reason.
  before do
    [ device_a, device_b ].each { |d| d.update_column(:created_at, 7.days.ago) }
  end

  def data
    JSON.parse(response.body)["data"]
  end

  def report(peers)
    post "/api/v1/system/node_api/status/sdwan",
         params: { peers: peers }.to_json,
         headers: auth_headers.merge("Content-Type" => "application/json")
  end

  describe "POST /api/v1/system/node_api/status/sdwan with a user-device peer id" do
    it "records last_seen_at from the reported handshake for a device on a network it hubs" do
      ts = 90.seconds.ago.change(usec: 0)

      report([ { peer_id: device_a.id, last_handshake_at: ts.utc.iso8601, status: "active" } ])

      expect(response).to have_http_status(:ok)
      expect(data["reported"]).to eq(1)
      expect(device_a.reload.last_seen_at).to be_within(1.second).of(ts)
    end

    it "returns a user_device-shaped entry carrying the recorded observation" do
      ts = 90.seconds.ago.change(usec: 0)

      report([ { peer_id: device_a.id, last_handshake_at: ts.utc.iso8601, status: "active" } ])

      entry = data["peers"].first
      expect(entry["peer_id"]).to eq(device_a.id)
      expect(entry["kind"]).to eq("user_device")
      expect(Time.iso8601(entry["last_seen_at"])).to be_within(1.second).of(ts)
    end

    it "counts a recognized device with no usable handshake but reports no observation" do
      # `reported` means RECOGNIZED, not WRITTEN — the entry says so.
      report([ { peer_id: device_a.id, last_handshake_at: "", status: "disconnected" } ])

      expect(data["reported"]).to eq(1)
      expect(data["peers"].first["last_seen_at"]).to be_nil
      expect(device_a.reload.last_seen_at).to be_nil
    end

    it "issues a bounded number of queries regardless of how many devices report" do
      # This endpoint runs on every heartbeat tick for every host in the
      # fleet; a per-entry lookup is an N+1 multiplied by the fleet.
      others = create_list(:sdwan_user_device, 4, access_grant: grant_a)
      ts = 60.seconds.ago.change(usec: 0)
      payload = ([ device_a ] + others).map { |d| { peer_id: d.id, last_handshake_at: ts.utc.iso8601 } }

      selects = 0
      counter = lambda do |_n, _s, _f, _i, p|
        selects += 1 if p[:sql].start_with?("SELECT") && p[:sql].include?("system_sdwan_")
      end

      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { report(payload) }

      expect(data["reported"]).to eq(5)
      # Two lookups (peers, then devices) + the hub-network scope query.
      # Well under one-per-entry; the assertion fails the moment the
      # lookups move back inside the loop.
      expect(selects).to be <= 4
    end

    it "does not regress the Sdwan::Peer path" do
      ts = 30.seconds.ago.change(usec: 0)

      report([ { peer_id: hub_a.id, last_handshake_at: ts.utc.iso8601, status: "active" } ])

      expect(response).to have_http_status(:ok)
      expect(data["reported"]).to eq(1)
      expect(hub_a.reload.last_handshake_at).to be_within(1.second).of(ts)
      expect(hub_a.status).to eq("active")
    end

    # Rails' uuid cast inside `where(id:)` accepts braces, missing dashes and
    # any case, and canonicalizes — so the pre-batching per-entry `find_by`
    # matched every one of these spellings. Batching keys rows by the
    # canonical id Postgres returns, so the request value must go through the
    # SAME cast or these shapes silently stop matching (a dropped peer
    # update, invisible to the agent).
    {
      "upper-cased"   => ->(id) { id.upcase },
      "brace-wrapped" => ->(id) { "{#{id}}" },
      "undashed"      => ->(id) { id.delete("-") }
    }.each do |shape, mangle|
      it "still matches a #{shape} id on both arms" do
        ts = 30.seconds.ago.change(usec: 0)

        report([
          { peer_id: mangle.call(hub_a.id),    last_handshake_at: ts.utc.iso8601 },
          { peer_id: mangle.call(device_a.id), last_handshake_at: ts.utc.iso8601 }
        ])

        expect(data["reported"]).to eq(2)
        expect(hub_a.reload.last_handshake_at).to be_within(1.second).of(ts)
        expect(device_a.reload.last_seen_at).to be_within(1.second).of(ts)
      end
    end

    it "does not 500 on a batch larger than the Postgres bind-parameter cap allows in one statement" do
      # `where(id: ids)` binds one parameter per id; the lookups slice so a
      # huge batch stays slow instead of becoming a 500 the agent retries.
      ts = 30.seconds.ago.change(usec: 0)
      noise = Array.new(2_500) { { peer_id: SecureRandom.uuid, last_handshake_at: ts.utc.iso8601 } }

      report(noise + [ { peer_id: device_a.id, last_handshake_at: ts.utc.iso8601 } ])

      expect(response).to have_http_status(:ok)
      expect(data["reported"]).to eq(1)
      expect(device_a.reload.last_seen_at).to be_within(1.second).of(ts)
    end

    it "processes every occurrence when one id appears twice in a batch" do
      older = 10.minutes.ago.change(usec: 0)
      newer = 30.seconds.ago.change(usec: 0)

      report([
        { peer_id: device_a.id, last_handshake_at: older.utc.iso8601 },
        { peer_id: device_a.id, last_handshake_at: newer.utc.iso8601 }
      ])

      expect(data["reported"]).to eq(2)
      expect(device_a.reload.last_seen_at).to be_within(1.second).of(newer)
    end

    it "skips non-object and non-string entries without 500ing the batch" do
      ts = 30.seconds.ago.change(usec: 0)

      report([
        "a-bare-string",
        { peer_id: nil, last_handshake_at: ts.utc.iso8601 },
        { peer_id: 12_345, last_handshake_at: ts.utc.iso8601 },
        { peer_id: device_a.id, last_handshake_at: ts.utc.iso8601 }
      ])

      expect(response).to have_http_status(:ok)
      expect(data["reported"]).to eq(1)
      expect(device_a.reload.last_seen_at).to be_within(1.second).of(ts)
    end

    it "handles a mixed batch of peers and devices in one report" do
      ts = 30.seconds.ago.change(usec: 0)

      report([
        { peer_id: hub_a.id,    last_handshake_at: ts.utc.iso8601, status: "active" },
        { peer_id: device_a.id, last_handshake_at: ts.utc.iso8601, status: "active" }
      ])

      expect(data["reported"]).to eq(2)
      expect(hub_a.reload.last_handshake_at).to be_within(1.second).of(ts)
      expect(device_a.reload.last_seen_at).to be_within(1.second).of(ts)
    end
  end

  # TRAP 1 — cross-hub tenancy. The peer id comes off the wire; the scope must
  # come from the authenticated instance.
  describe "tenancy scoping" do
    it "refuses to write last_seen_at on a device belonging to a network hubbed by another instance" do
      ts = 90.seconds.ago.change(usec: 0)

      report([ { peer_id: device_b.id, last_handshake_at: ts.utc.iso8601, status: "active" } ])

      expect(response).to have_http_status(:ok)
      expect(data["reported"]).to eq(0)
      expect(device_b.reload.last_seen_at).to be_nil
    end

    it "does not disclose whether a foreign device id exists" do
      ts = 90.seconds.ago.change(usec: 0)
      nonexistent = SecureRandom.uuid

      report([ { peer_id: device_b.id, last_handshake_at: ts.utc.iso8601 } ])
      foreign_body = response.body
      foreign_status = response.status

      report([ { peer_id: nonexistent, last_handshake_at: ts.utc.iso8601 } ])

      expect(response.status).to eq(foreign_status)
      expect(response.body).to eq(foreign_body)
      expect(response.body).not_to include(device_b.id)
    end

    it "refuses when the caller is only a SPOKE on the device's network" do
      # A is a spoke (not publicly_reachable) on network_c — it never receives
      # user devices in its compiled view, so it must not write them either.
      network_c = create(:sdwan_network, account: account)
      create(:sdwan_peer, account: account, network: network_c, node_instance: instance_a,
                          publicly_reachable: false)
      grant_c  = create(:sdwan_access_grant, account: account, network: network_c)
      device_c = create(:sdwan_user_device, access_grant: grant_c)

      report([ { peer_id: device_c.id, last_handshake_at: 1.minute.ago.utc.iso8601 } ])

      expect(data["reported"]).to eq(0)
      expect(device_c.reload.last_seen_at).to be_nil
    end

    it "refuses a revoked device — the writable set mirrors the compiled hub view" do
      # HubAndSpoke#hub_view compiles `network.user_devices.active`, so a
      # revoked device is cut off from the hub; a report claiming a
      # handshake for one is stale or fabricated either way.
      device_a.revoke!(reason: "lost laptop")

      report([ { peer_id: device_a.id, last_handshake_at: 1.minute.ago.utc.iso8601, status: "active" } ])

      expect(data["reported"]).to eq(0)
      expect(device_a.reload.last_seen_at).to be_nil
    end

    it "refuses when the caller has no peer on the device's network at all" do
      instance_c_node = create(:system_node, account: account, node_template: node_template)
      instance_c = create(:system_node_instance, :running, node: instance_c_node)
      System::NodeCertificate.create!(
        node_instance: instance_c, serial: SecureRandom.hex(16),
        subject: "CN=#{instance_c.id}", not_before: 1.hour.ago,
        not_after: 90.days.from_now, issuer_subject: "CN=Powernode Internal CA"
      )

      post "/api/v1/system/node_api/status/sdwan",
           params: { peers: [ { peer_id: device_a.id, last_handshake_at: 1.minute.ago.utc.iso8601 } ] }.to_json,
           headers: { "X-Forwarded-Tls-Client-Cert-Info" => CGI.escape(%(Subject="CN=#{instance_c.id}")),
                      "Content-Type" => "application/json" }

      expect(data["reported"]).to eq(0)
      expect(device_a.reload.last_seen_at).to be_nil
    end
  end

  # TRAP 2 — oracle discipline. "A report arrived" is NOT "the device is alive".
  describe "handshake oracle" do
    it "writes nothing when the agent reports no handshake (never connected)" do
      # peerReportsFromActual emits last_handshake_at: "" for a peer whose
      # kernel handshake timestamp is zero — i.e. it has NEVER connected.
      report([ { peer_id: device_a.id, last_handshake_at: "", status: "disconnected" } ])

      expect(response).to have_http_status(:ok)
      expect(device_a.reload.last_seen_at).to be_nil
    end

    it "writes nothing when last_handshake_at is absent entirely" do
      report([ { peer_id: device_a.id, rx_bytes: 0, tx_bytes: 0, status: "disconnected" } ])

      expect(device_a.reload.last_seen_at).to be_nil
    end

    it "does not advance an existing last_seen_at on a no-handshake report" do
      seen = 2.hours.ago.change(usec: 0)
      device_a.update_column(:last_seen_at, seen)

      report([ { peer_id: device_a.id, last_handshake_at: "", status: "disconnected" } ])

      expect(device_a.reload.last_seen_at).to be_within(1.second).of(seen)
    end

    it "keeps a stale handshake stale — it records T, not 'now'" do
      # The tunnel died an hour ago. last_seen_at must read one hour old, so a
      # staleness sensor (a separate offer) can see it.
      ts = 1.hour.ago.change(usec: 0)

      report([ { peer_id: device_a.id, last_handshake_at: ts.utc.iso8601, status: "disconnected" } ])

      expect(device_a.reload.last_seen_at).to be_within(1.second).of(ts)
      expect(device_a.last_seen_at).to be < 30.minutes.ago
    end

    it "never moves last_seen_at backwards (a second hub reporting an older handshake)" do
      newer = 1.minute.ago.change(usec: 0)
      device_a.update_column(:last_seen_at, newer)

      report([ { peer_id: device_a.id, last_handshake_at: 1.hour.ago.utc.iso8601, status: "degraded" } ])

      expect(device_a.reload.last_seen_at).to be_within(1.second).of(newer)
    end

    it "refuses a handshake in the future" do
      # A handshake cannot have been observed at a time that has not
      # happened. Accepting one would advance last_seen_at with no
      # observation AND — via the monotonic guard — pin it there
      # permanently, since every honest later report is older.
      report([ { peer_id: device_a.id, last_handshake_at: 1.year.from_now.utc.iso8601, status: "active" } ])

      expect(response).to have_http_status(:ok)
      expect(device_a.reload.last_seen_at).to be_nil

      # ...and the device is not poisoned: an honest report still lands.
      ts = 60.seconds.ago.change(usec: 0)
      report([ { peer_id: device_a.id, last_handshake_at: ts.utc.iso8601 } ])
      expect(device_a.reload.last_seen_at).to be_within(1.second).of(ts)
    end

    it "refuses a handshake predating the device itself" do
      # A handshake cannot have been observed before the key existed. The
      # monotonic guard does NOT cover this — it only fires once
      # last_seen_at is set, and never-seen is the normal state of a
      # freshly issued device.
      report([ { peer_id: device_a.id, last_handshake_at: (device_a.created_at - 1.day).utc.iso8601 } ])

      expect(response).to have_http_status(:ok)
      expect(device_a.reload.last_seen_at).to be_nil
    end

    it "returns 200 for a year below the Postgres timestamp floor" do
      # Time.iso8601 parses a negative year and it is NOT in the future, so
      # the future clamp alone lets it through to a write that Postgres
      # rejects — a 500 on an endpoint the agent retries forever.
      report([ { peer_id: device_a.id, last_handshake_at: "-5000-01-01T00:00:00Z" } ])

      expect(response).to have_http_status(:ok)
      expect(device_a.reload.last_seen_at).to be_nil
    end

    it "returns 200 for a year beyond the Postgres timestamp range" do
      # Time.iso8601 accepts year 999999999999; Postgres tops out at
      # 294276 AD, so writing it raises StatementInvalid and 500s a
      # heartbeat the agent retries forever.
      report([ { peer_id: device_a.id, last_handshake_at: "999999999999-01-01T00:00:00Z" } ])

      expect(response).to have_http_status(:ok)
      expect(device_a.reload.last_seen_at).to be_nil
    end

    it "refuses a timestamp with no explicit zone" do
      # Time.iso8601 reads a zone-less string in the server's LOCAL zone —
      # a free time-shift on a caller-controlled field.
      report([ { peer_id: device_a.id, last_handshake_at: "2026-08-20T12:00:00" } ])

      expect(response).to have_http_status(:ok)
      expect(device_a.reload.last_seen_at).to be_nil
    end

    it "accepts a non-UTC offset" do
      ts = 90.seconds.ago.change(usec: 0)

      report([ { peer_id: device_a.id, last_handshake_at: ts.getlocal("+02:00").iso8601 } ])

      expect(device_a.reload.last_seen_at).to be_within(1.second).of(ts)
    end

    it "writes nothing for non-string handshake values" do
      [ 1_755_000_000, 12.5, true, [ "2026-08-20T12:00:00Z" ], { "at" => "2026-08-20T12:00:00Z" } ].each do |bad|
        report([ { peer_id: device_a.id, last_handshake_at: bad } ])

        expect(response).to have_http_status(:ok), "500ed on #{bad.inspect}"
        expect(device_a.reload.last_seen_at).to be_nil
      end
    end

    it "writes nothing when the handshake timestamp is unparseable" do
      # An unparseable timestamp is NOT MEASURED. Falling back to Time.current
      # here would fabricate liveness out of a malformed field.
      report([ { peer_id: device_a.id, last_handshake_at: "not-a-timestamp", status: "active" } ])

      expect(response).to have_http_status(:ok)
      expect(device_a.reload.last_seen_at).to be_nil
    end
  end
end
