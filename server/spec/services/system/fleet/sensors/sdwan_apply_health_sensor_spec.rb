# frozen_string_literal: true

require "rails_helper"

# IMP-da1b772c2596 — the consumer half of the SDWAN apply oracle.
#
# The compile pipeline proves the platform SERVED a config. Only the agent
# knows whether the kernel ACCEPTED it, and until this sensor existed nothing
# read the answer: a node whose nftables/vrf/bridge apply failed on every tick
# was indistinguishable from a node that applied cleanly.
#
# The two claims this file pins hardest, because both are the "false green"
# class the task exists to end:
#
#   1. ABSENCE IS NOT HEALTH. A node that has never reported, whose report
#      is stale, or whose agent predates per-subsystem reporting is NOT
#      MEASURED — it emits system.sdwan_apply_not_measured, and no code path
#      renders it as healthy or as a measured zero.
#   2. The failure fingerprint is per (instance, subsystem, scope), so a
#      persistently failing applier DEDUPS instead of storming, while two
#      genuinely different failures stay two signals.
RSpec.describe System::Fleet::Sensors::SdwanApplyHealthSensor do
  let(:account) { create(:account) }
  let(:network) { create(:sdwan_network, account: account) }

  subject(:signals) { described_class.new(account: account).sense }

  def kinds = signals.map { |s| s[:kind] }
  def failures = signals.select { |s| s[:kind] == "system.sdwan_apply_failed" }
  def not_measured = signals.find { |s| s[:kind] == "system.sdwan_apply_not_measured" }

  # An instance the platform EXPECTS to be applying SDWAN: it has a peer, and
  # it is currently talking to us. A silent node is InstanceStatusSensor's
  # alarm, not this one's.
  def sdwan_instance(heartbeat_at: 1.minute.ago, account_for: nil, **attrs)
    acct     = account_for || account
    template = create(:system_node_template, account: acct)
    node     = create(:system_node, account: acct, node_template: template)
    instance = create(:system_node_instance, node: node, status: "running",
                      last_heartbeat_at: heartbeat_at, **attrs)
    net = acct == account ? network : create(:sdwan_network, account: acct)
    create(:sdwan_peer, account: acct, network: net, node_instance: instance)
    instance
  end

  def subsystem(name, state:, scope: "", message: "")
    { "subsystem" => name, "scope" => scope, "state" => state,
      "message" => message, "observed_at" => 1.minute.ago.utc.iso8601 }
  end

  def record_state!(instance, networks:, observed_at: Time.current)
    instance.update!(config: instance.config.merge(
      "sdwan_state" => {
        "observed_at" => observed_at.utc.iso8601,
        "networks"    => networks
      }
    ))
  end

  def network_entry(network_id: "net-a", subsystems: [], subsystems_reported: true,
                    healthy_peers: 2, healthy_peers_measured: true,
                    last_reconcile_at: 1.minute.ago)
    {
      "network_id"             => network_id,
      "interface"              => "wg0",
      "peer_count"             => 3,
      "healthy_peers"          => healthy_peers,
      "healthy_peers_measured" => healthy_peers_measured,
      "last_reconcile_at"      => last_reconcile_at&.utc&.iso8601,
      "subsystems_reported"    => subsystems_reported,
      "subsystems"             => subsystems
    }
  end

  describe "an observed apply failure" do
    let!(:instance) { sdwan_instance }

    before do
      record_state!(instance, networks: [
        network_entry(subsystems: [
          subsystem("apply_firewall", state: "error", message: "nft: exit status 1"),
          subsystem("apply_peers", state: "ok", scope: "net-a")
        ])
      ])
    end

    it "emits a high-severity signal naming the subsystem the AGENT reported" do
      expect(kinds).to eq([ "system.sdwan_apply_failed" ])

      sig = failures.first
      expect(sig[:severity]).to eq(:high)
      expect(sig[:payload]["subsystem"]).to eq("apply_firewall")
      expect(sig[:payload]["message"]).to eq("nft: exit status 1")
      expect(sig[:payload]["instance_id"]).to eq(instance.id)
      expect(sig[:payload]["network_ids"]).to eq([ "net-a" ])
      expect(sig[:payload]["remediation_action"]).to be_nil
    end

    it "fingerprints per (instance, subsystem, scope)" do
      expect(failures.first[:fingerprint])
        .to eq("sdwan_apply_failed:#{instance.id}:apply_firewall:")
    end
  end

  describe "dedup" do
    # A host-global applier (empty scope) is replayed under EVERY network in
    # the payload — see HeartbeatStatuses' netScopes branch. One failure must
    # stay one signal.
    it "collapses one host-global failure reported under several networks" do
      instance = sdwan_instance
      failure  = subsystem("apply_vrfs", state: "error", message: "Unknown device type")
      record_state!(instance, networks: [
        network_entry(network_id: "net-a", subsystems: [ failure ]),
        network_entry(network_id: "net-b", subsystems: [ failure ])
      ])

      expect(failures.size).to eq(1)
      expect(failures.first[:payload]["network_ids"]).to contain_exactly("net-a", "net-b")
    end

    # The counter-case: same subsystem, DIFFERENT scope is a different
    # failure. A per-instance fingerprint would silently drop one of these.
    it "keeps two scopes of one subsystem apart" do
      instance = sdwan_instance
      record_state!(instance, networks: [
        network_entry(network_id: "net-a", subsystems: [
          subsystem("apply_peers", state: "error", scope: "net-a", message: "a"),
          subsystem("apply_peers", state: "error", scope: "net-b", message: "b")
        ])
      ])

      expect(failures.map { |s| s[:fingerprint] }).to contain_exactly(
        "sdwan_apply_failed:#{instance.id}:apply_peers:net-a",
        "sdwan_apply_failed:#{instance.id}:apply_peers:net-b"
      )
    end

    # And a per-subsystem-only fingerprint would collapse two hosts into one.
    it "keeps the same subsystem failing on two instances apart" do
      one = sdwan_instance
      two = sdwan_instance
      [ one, two ].each do |i|
        record_state!(i, networks: [
          network_entry(subsystems: [ subsystem("apply_firewall", state: "error") ])
        ])
      end

      expect(failures.map { |s| s[:fingerprint] }).to contain_exactly(
        "sdwan_apply_failed:#{one.id}:apply_firewall:",
        "sdwan_apply_failed:#{two.id}:apply_firewall:"
      )
    end
  end

  describe "ABSENCE IS NOT HEALTH" do
    it "reports a node that has NEVER sent sdwan_state as not measured" do
      instance = sdwan_instance

      expect(kinds).to include("system.sdwan_apply_not_measured")
      sig = not_measured
      expect(sig[:fingerprint]).to eq("sdwan_apply_not_measured:#{account.id}")
      expect(sig[:payload]["instance_count"]).to eq(1)
      expect(sig[:payload]["reasons"]).to eq("never_reported" => 1)
      expect(sig[:payload]["instances"].first["instance_id"]).to eq(instance.id)
      expect(sig[:payload]["remediation_action"]).to be_nil
    end

    # The shape deployed fleet agents still send today: network entries with
    # no subsystem_states at all. Reading that as "nothing failed" is the
    # exact false green this sensor exists to prevent.
    it "reports a pre-28460bbb agent's report as not measured, never as healthy" do
      sdwan_instance.then do |instance|
        record_state!(instance, networks: [
          network_entry(subsystems: [], subsystems_reported: false,
                        healthy_peers: nil, healthy_peers_measured: false)
        ])
      end

      expect(kinds).to eq([ "system.sdwan_apply_not_measured" ])
      expect(not_measured[:payload]["reasons"]).to eq("no_subsystem_observation" => 1)
    end

    it "reports a stale report as not measured" do
      instance = sdwan_instance
      record_state!(instance, observed_at: 3.hours.ago, networks: [
        network_entry(subsystems: [ subsystem("apply_firewall", state: "ok") ])
      ])

      expect(not_measured[:payload]["reasons"]).to eq("stale_report" => 1)
    end

    # A host with zero desired networks emits no entries at all. That is
    # "nothing observable here" — never "SDWAN healthy".
    it "reports an empty-networks report as not measured" do
      instance = sdwan_instance
      record_state!(instance, networks: [])

      expect(not_measured[:payload]["reasons"]).to eq("no_networks" => 1)
    end

    # THE WEDGED-RECONCILER CASE. Manager#HeartbeatStatuses is a pure
    # snapshot under a mutex — it does not run a reconcile — and the
    # heartbeat loop is a different loop from the reconcile it calls in
    # PostSend. So a node whose reconcile has died keeps re-shipping the same
    # frozen, all-ok block every 30s, and the SERVER re-stamps it fresh on
    # arrival. Keying freshness on the ingest clock alone would launder a
    # six-hour-dead reconciler as current and healthy.
    it "reports a frozen snapshot from a wedged reconciler as not measured" do
      instance = sdwan_instance
      record_state!(instance, observed_at: Time.current, networks: [
        network_entry(subsystems: [ subsystem("apply_firewall", state: "ok") ],
                      last_reconcile_at: 3.hours.ago)
      ])

      expect(kinds).to eq([ "system.sdwan_apply_not_measured" ])
      expect(not_measured[:payload]["reasons"]).to eq("stale_reconcile" => 1)
    end

    it "reports a report with no agent reconcile clock at all as not measured" do
      instance = sdwan_instance
      record_state!(instance, networks: [
        network_entry(subsystems: [ subsystem("apply_firewall", state: "ok") ],
                      last_reconcile_at: nil)
      ])

      expect(not_measured[:payload]["reasons"]).to eq("stale_reconcile" => 1)
    end

    # The writer maps an unrecognized state to "unknown", never "ok". That is
    # only honest at rest — if the sensor then treats "unknown" as silence,
    # a producer that renames its error constant takes the whole fleet
    # silently green on the next agent rollout.
    it "reports an unrecognized state string as not measured, not as silence" do
      instance = sdwan_instance
      record_state!(instance, networks: [
        network_entry(subsystems: [ subsystem("apply_vrfs", state: "unknown") ])
      ])

      expect(kinds).to eq([ "system.sdwan_apply_not_measured" ])
      expect(not_measured[:payload]["reasons"]).to eq("unrecognized_state" => 1)
    end

    # Additive, not exclusive — a real failure alongside an unreadable state
    # is two facts, and swallowing either is a loss.
    it "still emits the real failure when another subsystem is unrecognized" do
      instance = sdwan_instance
      record_state!(instance, networks: [
        network_entry(subsystems: [
          subsystem("apply_firewall", state: "error", message: "nft"),
          subsystem("apply_vrfs", state: "unknown")
        ])
      ])

      expect(failures.map { |s| s[:payload]["subsystem"] }).to eq([ "apply_firewall" ])
      expect(not_measured[:payload]["reasons"]).to eq("unrecognized_state" => 1)
    end

    # One fingerprint per ACCOUNT for this kind, deliberately: the initial
    # fleet-wide state is "every node runs a pre-28460bbb agent", and one
    # signal per node would be a rollout-sized storm of the same fact.
    it "aggregates every unmeasured instance into ONE signal" do
      3.times { sdwan_instance }

      expect(signals.count { |s| s[:kind] == "system.sdwan_apply_not_measured" }).to eq(1)
      expect(not_measured[:payload]["instance_count"]).to eq(3)
    end
  end

  describe "silence" do
    it "emits nothing when every reported subsystem is ok" do
      instance = sdwan_instance
      record_state!(instance, networks: [
        network_entry(subsystems: [
          subsystem("apply_firewall", state: "ok"),
          subsystem("apply_peers", state: "ok", scope: "net-a")
        ])
      ])

      expect(signals).to eq([])
    end

    it "ignores an instance with no SDWAN peer — the platform asked it for nothing" do
      template = create(:system_node_template, account: account)
      node     = create(:system_node, account: account, node_template: template)
      create(:system_node_instance, node: node, status: "running", last_heartbeat_at: 1.minute.ago)

      expect(signals).to eq([])
    end

    # A node that stopped heartbeating is InstanceStatusSensor's alarm. Two
    # sensors alarming on one cause is the double-alarm the SDWAN sensor
    # family already refuses elsewhere.
    it "ignores an instance that is no longer heartbeating" do
      sdwan_instance(heartbeat_at: 6.hours.ago)

      expect(signals).to eq([])
    end

    it "ignores another account's failing instance" do
      other = create(:account)
      inst  = sdwan_instance(account_for: other)
      record_state!(inst, networks: [
        network_entry(subsystems: [ subsystem("apply_firewall", state: "error") ])
      ])

      expect(signals).to eq([])
    end
  end

  # Both ends of the lane, so it cannot ship inert. Mirrors the wiring block
  # in sdwan_service_health_sensor_spec.rb.
  describe "wiring" do
    it "is registered in the fleet sense pass" do
      expect(System::Fleet::FleetAutonomyService::SENSORS).to include(described_class)
    end

    it "routes both kinds to the notify-level investigate category" do
      bindings = System::Fleet::DecisionEngine::SIGNAL_BINDINGS

      %w[system.sdwan_apply_failed system.sdwan_apply_not_measured].each do |kind|
        expect(bindings).to have_key(kind)
        expect(bindings[kind][:action_category]).to eq("system.sdwan_apply_investigate")
        expect(bindings[kind][:skill]).to be_nil
      end
    end

    # NOT system.observation: the fleet seed maps that category to
    # auto_approve, which collects for dashboards without ever reaching an
    # operator — the silent downgrade this lane must not inherit.
    it "seeds the gate policy on the agent that runs the sense pass" do
      seed = Rails.root.join("../extensions/system/server/db/seeds/fleet_autonomy_agent.rb")
      expect(seed.read).to include('"system.sdwan_apply_investigate" => "notify_and_proceed"')
    end

    # Membership here is DECLARED, never inferred. Without it the standing
    # fingerprint of a permanently failing applier scores ineffective every
    # settle window until F3-11 manufactures a false fleet.remediation_stuck
    # escalation on a lane that never actuated anything.
    it "is declared non-remediating so it stays out of the validate arc" do
      expect(System::Fleet::RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES)
        .to include("system.sdwan_apply_investigate")
    end

    it "registers the category so an operator can retune it" do
      expect(Ai::InterventionPolicy.category_registered?("system.sdwan_apply_investigate")).to be(true)
    end
  end
end
