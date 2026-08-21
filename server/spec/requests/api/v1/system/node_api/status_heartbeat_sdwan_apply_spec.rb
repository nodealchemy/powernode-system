# frozen_string_literal: true

require "rails_helper"

# IMP-da1b772c2596 — the heartbeat is where the agent's SDWAN APPLY outcome
# enters the platform.
#
# The producer has shipped `sdwan_state` (runtime.HeartbeatPayload) since the
# SDWAN manager existed, and 28460bbb gave it per-subsystem applier outcomes.
# Nothing on the server ever read the key: a repo-wide grep for `sdwan_state`
# across both Rails trees returned zero hits, so a node whose nftables/vrf/
# bridge apply failed every tick looked exactly like a node that applied
# cleanly. "Served" was being scored as "applied".
#
# The ORACLE contract this spec pins:
#
#   * a per-subsystem outcome is recorded as the agent OBSERVED it;
#   * absence of the block is absence — nothing is stamped, and nothing
#     renders as healthy;
#   * a pre-28460bbb agent (which sends network entries with NO
#     subsystem_states and NO healthy_peers) is recorded as NOT MEASURED,
#     never as healthy and never as a measured zero. Deployed fleet agents
#     may still be on that build, so this is the live shape today.
RSpec.describe "Api::V1::System::NodeApi::Status#heartbeat — SDWAN apply state", type: :request do
  let(:account)       { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }
  let(:node)          { create(:system_node, account: account, node_template: node_template) }
  let(:instance)      { create(:system_node_instance, node: node, status: "running") }

  let!(:active_cert) do
    System::NodeCertificate.create!(
      node_instance: instance,
      serial:         SecureRandom.hex(16),
      subject:        "CN=#{instance.id}",
      not_before:     1.hour.ago,
      not_after:      90.days.from_now,
      issuer_subject: "CN=Powernode Internal CA"
    )
  end

  let(:headers) do
    { "X-Forwarded-Tls-Client-Cert-Info" => CGI.escape(%(Subject="CN=#{instance.id}")) }
  end

  let(:base_body) do
    { boot_id: "boot-sdwan-1", agent_version: "1.4.0-test", mount_state: "mounted" }
  end

  def post_heartbeat(extra = {})
    post "/api/v1/system/node_api/status/heartbeat",
         params: base_body.merge(extra), headers: headers, as: :json
  end

  def recorded_state
    instance.reload.config["sdwan_state"]
  end

  # The exact wire shape from agent/internal/sdwan/state.go — HeartbeatStatus
  # (interface / network_id / peer_count / healthy_peers / last_reconcile_at /
  # last_error / subsystem_states) nesting SubsystemStatus (subsystem / scope /
  # state / message / observed_at).
  def wire_entry(network_id:, **overrides)
    {
      interface:         "wg0",
      network_id:        network_id,
      peer_count:        3,
      healthy_peers:     2,
      last_reconcile_at: Time.current.utc.iso8601,
      subsystem_states:  []
    }.merge(overrides)
  end

  describe "a failing applier" do
    it "records the agent-observed subsystem failure verbatim" do
      post_heartbeat(sdwan_state: [
        wire_entry(
          network_id: "net-a",
          last_error: "nft: apply failed: exit status 1",
          subsystem_states: [
            { subsystem: "apply_firewall", scope: "", state: "error",
              message: "nft: apply failed: exit status 1",
              observed_at: "2026-08-21T10:00:00Z" },
            { subsystem: "apply_peers", scope: "net-a", state: "ok",
              message: "", observed_at: "2026-08-21T10:00:01Z" }
          ]
        )
      ])

      expect(response).to have_http_status(:ok)

      state = recorded_state
      expect(state).to be_a(Hash)
      expect(state["observed_at"]).to be_present

      net = state["networks"].first
      expect(net["network_id"]).to eq("net-a")
      expect(net["interface"]).to eq("wg0")
      expect(net["subsystems_reported"]).to be(true)
      expect(net["healthy_peers"]).to eq(2)
      expect(net["healthy_peers_measured"]).to be(true)

      failed = net["subsystems"].find { |s| s["subsystem"] == "apply_firewall" }
      expect(failed["state"]).to eq("error")
      expect(failed["message"]).to eq("nft: apply failed: exit status 1")
      expect(failed["scope"]).to eq("")
      expect(failed["observed_at"]).to eq("2026-08-21T10:00:00Z")
    end

    it "never coerces an unrecognized state string into ok" do
      post_heartbeat(sdwan_state: [
        wire_entry(network_id: "net-a", subsystem_states: [
          { subsystem: "apply_vrfs", state: "weird", observed_at: "2026-08-21T10:00:00Z" }
        ])
      ])

      sub = recorded_state["networks"].first["subsystems"].first
      expect(sub["state"]).to eq("unknown")
    end
  end

  describe "a pre-28460bbb agent (the shape deployed nodes still send)" do
    it "records the report as carrying NO subsystem observation" do
      post_heartbeat(sdwan_state: [
        { interface: "wg0", network_id: "net-a", peer_count: 3,
          last_reconcile_at: Time.current.utc.iso8601 }
      ])

      net = recorded_state["networks"].first
      expect(net["subsystems"]).to eq([])
      expect(net["subsystems_reported"]).to be(false)
    end

    it "records an unmeasured healthy_peers as unmeasured, NOT as zero" do
      post_heartbeat(sdwan_state: [
        { interface: "wg0", network_id: "net-a", peer_count: 3,
          healthy_peers: nil, last_reconcile_at: Time.current.utc.iso8601 }
      ])

      net = recorded_state["networks"].first
      expect(net["healthy_peers_measured"]).to be(false)
      expect(net["healthy_peers"]).to be_nil
    end
  end

  describe "absence" do
    it "stamps nothing when the heartbeat carries no sdwan_state block" do
      post_heartbeat

      expect(response).to have_http_status(:ok)
      expect(instance.reload.config).not_to have_key("sdwan_state")
    end

    # A host with zero desired networks emits no entries at all (the
    # omitempty PAYLOAD-SHAPE LIMIT documented on HeartbeatStatus). An
    # explicitly empty array must therefore read as "nothing observable
    # here", never as "SDWAN healthy".
    it "records an explicitly empty block as a report with no networks" do
      post_heartbeat(sdwan_state: [])

      state = recorded_state
      expect(state["networks"]).to eq([])
    end
  end

  describe "robustness" do
    it "preserves unrelated config keys" do
      instance.update!(config: instance.config.merge("cloud_instance_id" => "i-123"))

      post_heartbeat(sdwan_state: [ wire_entry(network_id: "net-a") ])

      expect(instance.reload.config["cloud_instance_id"]).to eq("i-123")
      expect(instance.config["sdwan_state"]).to be_present
    end

    it "acknowledges the heartbeat when the block is malformed" do
      post_heartbeat(sdwan_state: [ "not-an-object" ])

      expect(response).to have_http_status(:ok)
      expect(recorded_state["networks"]).to eq([])
    end

    # The block arrives from a node, so a compromised or simply buggy agent
    # decides its size. Everything it sends lands in a jsonb column the fleet
    # tick reads on every pass, and `subsystem`/`scope` additionally become
    # part of the sensor's signal FINGERPRINT — which keys rows in a second
    # table. The caps are load-bearing, not decoration.
    it "caps a hostile message length" do
      post_heartbeat(sdwan_state: [
        wire_entry(network_id: "net-a", subsystem_states: [
          { subsystem: "apply_firewall", state: "error", message: "x" * 5_000 }
        ])
      ])

      sub = recorded_state["networks"].first["subsystems"].first
      expect(sub["message"].length).to eq(Sdwan::AgentApplyStateWriter::MAX_MESSAGE_CHARS)
    end

    it "caps a hostile identifier length" do
      post_heartbeat(sdwan_state: [
        wire_entry(network_id: "n" * 5_000, subsystem_states: [
          { subsystem: "s" * 5_000, scope: "c" * 5_000, state: "error" }
        ])
      ])

      net = recorded_state["networks"].first
      cap = Sdwan::AgentApplyStateWriter::MAX_IDENTIFIER_CHARS
      expect(net["network_id"].length).to eq(cap)
      expect(net["subsystems"].first["subsystem"].length).to eq(cap)
      expect(net["subsystems"].first["scope"].length).to eq(cap)
    end

    it "caps the number of network entries it will store" do
      entries = (1..(Sdwan::AgentApplyStateWriter::MAX_NETWORKS + 20)).map do |i|
        wire_entry(network_id: "net-#{i}")
      end
      post_heartbeat(sdwan_state: entries)

      expect(recorded_state["networks"].size).to eq(Sdwan::AgentApplyStateWriter::MAX_NETWORKS)
    end

    # A nameless entry is KEPT rather than dropped. Dropping it shrank the
    # list silently, and a network whose every entry was nameless then read
    # as measured-with-nothing-wrong — a failure in the green direction.
    it "keeps a nameless subsystem entry instead of silently dropping it" do
      post_heartbeat(sdwan_state: [
        wire_entry(network_id: "net-a", subsystem_states: [
          { subsystem: "", state: "error", message: "boom" }
        ])
      ])

      net = recorded_state["networks"].first
      expect(net["subsystems_reported"]).to be(true)
      expect(net["subsystems"].first["subsystem"]).to eq("unnamed")
      expect(net["subsystems"].first["state"]).to eq("error")
    end

    it "records a list it could not read at all as NOT reported" do
      post_heartbeat(sdwan_state: [
        wire_entry(network_id: "net-a", subsystem_states: [ "garbage" ])
      ])

      net = recorded_state["networks"].first
      expect(net["subsystems_reported"]).to be(false)
      expect(net["subsystems"]).to eq([])
    end
  end
end
