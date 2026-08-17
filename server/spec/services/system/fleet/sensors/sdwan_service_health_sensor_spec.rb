# frozen_string_literal: true

require "rails_helper"

# IMP-c7d663f24a0b — service-level connectivity sensing.
#
# The behavioural claim under test: before this sensor existed, an active
# published service could stop serving entirely and NOTHING in the platform
# noticed, because every SDWAN sensor read infrastructure and the one signal
# that would have caught it (Sdwan::FlowSample IPFIX telemetry) was ingested
# and consumed by nobody.
RSpec.describe System::Fleet::Sensors::SdwanServiceHealthSensor do
  let(:account) { Account.first || create(:account) }
  let(:sensor)  { described_class.new(account: account) }

  before do
    Sdwan::FlowSample.where(account_id: account.id).delete_all
    Sdwan::IpfixCollector.where(account_id: account.id).delete_all
    Sdwan::PortMapping.where(account_id: account.id).delete_all
    Sdwan::Service.where(account_id: account.id).delete_all
    Sdwan::VirtualIp.where(account_id: account.id).delete_all
    Sdwan::Peer.where(account_id: account.id).delete_all
    Sdwan::Network.where(account_id: account.id).delete_all
    SiteSetting.where("key LIKE 'system.sdwan.service_health%'").delete_all
  end

  let(:network)   { create(:sdwan_network, account: account) }
  let(:collector) { create(:sdwan_ipfix_collector, account: account, state: "active") }

  # A holder whose WG handshake is fresh — the "pipe is up" half of the AND.
  let(:holder) do
    create(:sdwan_peer, account: account, network: network,
                        last_handshake_at: 30.seconds.ago)
  end

  let(:vip) do
    create(:sdwan_virtual_ip, account: account, network: network,
                              state: "active", holder_peer_ids: [ holder.id ])
  end

  let(:vip_address) { vip.cidr.to_s.split("/").first }

  # Older than the grace period, so "no traffic yet" is not the explanation.
  # let! (not let): most examples exercise the sensor WITHOUT naming the
  # service, so a lazy let would leave nothing for the sweep to find and the
  # positive cases would pass for the wrong reason.
  let!(:service) do
    create(:sdwan_service, account: account, backend_vip: vip, backend_host: nil,
                           backend_port: 8443, protocol: "https",
                           created_at: 2.hours.ago)
  end

  # Coverage for THIS service: its VIP holder is visible in the flow record
  # (here on an unrelated port), proving the exporter covering that host is
  # alive while nothing arrived for the service's own port. Without such a
  # sample the sensor refuses to infer anything — see "telemetry gating".
  def deliver_unrelated_flow!
    create(:sdwan_flow_sample, account: account, ipfix_collector: collector,
                              dst_ip: holder.assigned_address.to_s.split("/").first,
                              dst_port: 22, observed_at: 1.minute.ago)
  end

  def deliver_flow_to_service!(observed_at: 1.minute.ago)
    create(:sdwan_flow_sample, account: account, ipfix_collector: collector,
                              dst_ip: vip_address, dst_port: service.backend_port,
                              observed_at: observed_at)
  end

  def silent_signals(signals)
    signals.select { |s| s.kind == "system.sdwan_service_silent" }
  end

  describe "a service that is serving" do
    it "emits no signal and records the observation" do
      sample = deliver_flow_to_service!

      expect(silent_signals(sensor.sense)).to be_empty
      expect(service.reload.health_state).to eq("serving")
      # Compare against the sample's own timestamp, not a re-evaluated
      # `1.minute.ago` — the latter drifts by however long the example ran.
      expect(service.last_observed_flow_at).to be_within(1.second).of(sample.observed_at)
    end
  end

  describe "a service that has gone silent while its overlay is healthy" do
    it "emits sdwan_service_silent and marks the service silent" do
      deliver_unrelated_flow!

      signals = silent_signals(sensor.sense)

      expect(signals.size).to eq(1)
      sig = signals.first
      expect(sig.payload["service_id"]).to eq(service.id)
      expect(sig.payload["backend_address"]).to eq(vip_address)
      expect(sig.payload["backend_port"]).to eq(8443)
      # No blind remediation: the overlay was just proven healthy.
      expect(sig.payload["remediation_action"]).to be_nil
      expect(sig.fingerprint).to eq("sdwan_service_silent:#{service.id}")
      expect(service.reload.health_state).to eq("silent")
    end

    it "raises severity for a service that is actually exposed" do
      service.update!(local_enabled: true, local_auth_mode: "authenticated")
      service.update_column(:last_observed_flow_at, 3.hours.ago)
      deliver_unrelated_flow!

      expect(silent_signals(sensor.sense).first.severity).to eq(:high)
    end
  end

  # The conservative half of the AND: when the tunnel itself is down,
  # SdwanVipReachabilitySensor already owns that alarm. Firing here too would
  # make one infra failure produce two independent alerts.
  describe "when the overlay itself is down" do
    # Each example carries its own POSITIVE CONTROL: the identical fixture,
    # with only the overlay fact restored, must alarm. Without that second
    # half an empty result proves nothing — a fixture that never reaches the
    # sensor at all is also empty, and "it stayed quiet" is exactly the
    # assertion that rots into a tautology first.
    it "stays silent for a stale holder handshake" do
      holder.update!(last_handshake_at: 45.minutes.ago)
      deliver_unrelated_flow!

      expect(silent_signals(described_class.new(account: account).sense)).to be_empty

      holder.update!(last_handshake_at: 10.seconds.ago)
      expect(silent_signals(described_class.new(account: account).sense).size).to eq(1)
    end

    it "stays silent for a VIP with no holder at all" do
      vip.update!(holder_peer_ids: [])
      deliver_unrelated_flow!

      expect(silent_signals(described_class.new(account: account).sense)).to be_empty

      vip.update!(holder_peer_ids: [ holder.id ])
      expect(silent_signals(described_class.new(account: account).sense).size).to eq(1)
    end

    # The state a service is left in matters as much as the signal it doesn't
    # produce: an unprovable service must not keep a "serving" an earlier
    # tick stamped, or the read model asserts health it cannot support.
    it "reverts a previously-serving service to unknown rather than leaving it stale" do
      deliver_flow_to_service!
      sensor.sense
      expect(service.reload.health_state).to eq("serving")

      Sdwan::FlowSample.where(account_id: account.id).delete_all
      holder.update!(last_handshake_at: 45.minutes.ago)
      deliver_unrelated_flow!

      expect(silent_signals(described_class.new(account: account).sense)).to be_empty
      expect(service.reload.health_state).to eq("unknown")
      # The observation itself is retained — only the health claim is dropped.
      expect(service.last_observed_flow_at).to be_present
    end
  end

  # backend_host is a free-text column and a hostname is an ordinary value in
  # it. Compared against the inet-typed dst_ip this RAISES rather than missing
  # quietly, and FleetAutonomyService rescues per sensor — so the sensor would
  # be marked failed and drop ALL its signals (orphans included) on every tick
  # for the whole account, permanently.
  describe "a backend that cannot be correlated at all" do
    let!(:hostname_service) do
      create(:sdwan_service, account: account, backend_vip: nil,
                             backend_host: "backend.example.com",
                             backend_port: 443, created_at: 2.hours.ago)
    end

    it "does not raise, and marks the service unobservable rather than unknown" do
      deliver_unrelated_flow!

      expect { sensor.sense }.not_to raise_error
      expect(hostname_service.reload.health_state).to eq("unobservable")
    end

    it "still emits the orphan half despite the uncorrelatable service" do
      hub = create(:sdwan_peer, account: account, network: network)
      create(:sdwan_port_mapping, account: account, network: network,
                                  hub_peer: hub, target_peer: nil,
                                  target_virtual_ip: vip)
      vip.update!(holder_peer_ids: [])

      expect(sensor.sense.map(&:kind)).to include("system.sdwan_portmap_orphaned")
    end
  end

  # Absence of telemetry is not evidence of silence. This is the guard that
  # keeps one collector outage from alarming on every service at once.
  describe "telemetry gating" do
    # The account-wide form of this guard defended only the all-collectors-down
    # case. Traffic to somebody ELSE's host is not evidence that the exporter
    # covering THIS service is alive — that gap is the two-site false alarm.
    it "does not treat another host's traffic as coverage of this service" do
      other_peer = create(:sdwan_peer, account: account, network: network,
                                       assigned_address: "fd00:abcd:9::9")
      create(:sdwan_flow_sample, account: account, ipfix_collector: collector,
                                 dst_ip: other_peer.assigned_address,
                                 dst_port: 22, observed_at: 1.minute.ago)

      expect(silent_signals(sensor.sense)).to be_empty
      expect(service.reload.health_state).to eq("unknown")

      # Positive control: the SAME fixture alarms once this service's own
      # holder appears in the flow record.
      deliver_unrelated_flow!
      expect(silent_signals(described_class.new(account: account).sense).size).to eq(1)
    end

    it "reverts a stale serving claim when telemetry stops arriving" do
      deliver_flow_to_service!
      sensor.sense
      expect(service.reload.health_state).to eq("serving")

      Sdwan::FlowSample.where(account_id: account.id).delete_all

      expect(described_class.new(account: account).sense).to be_empty
      expect(service.reload.health_state).to eq("unknown")
    end

    it "clears a health claim off a service that is no longer active" do
      deliver_flow_to_service!
      sensor.sense
      expect(service.reload.health_state).to eq("serving")

      service.update!(status: "disabled")
      described_class.new(account: account).sense

      expect(service.reload.health_state).to eq("unknown")
      expect(Sdwan::Service.silent).not_to include(service)
    end

    it "emits nothing when no flow has been delivered in the window" do
      collector # an active collector exists, but it has delivered nothing
      service

      expect(sensor.sense).to be_empty
      expect(service.reload.health_state).to eq("unknown")
    end

    it "emits nothing when the account has no active collector" do
      collector.update!(state: "disabled")
      create(:sdwan_flow_sample, account: account, ipfix_collector: collector,
                                 dst_ip: "fd00:dead::1", observed_at: 1.minute.ago)
      service

      expect(sensor.sense).to be_empty
    end

    it "does not alarm on a service younger than the grace period" do
      service.update_column(:created_at, 1.minute.ago)
      deliver_unrelated_flow!

      expect(silent_signals(sensor.sense)).to be_empty

      # Positive control — age is the only thing being tested here.
      service.update_column(:created_at, 2.hours.ago)
      expect(silent_signals(described_class.new(account: account).sense).size).to eq(1)
    end
  end

  describe "DB-driven thresholds" do
    it "honours a SiteSetting flow window instead of the constant" do
      # Serving 40 minutes ago is outside the 15-minute default but inside a
      # widened 2-hour window, so the widened setting must suppress the alarm.
      deliver_flow_to_service!(observed_at: 40.minutes.ago)
      deliver_unrelated_flow!

      expect(silent_signals(described_class.new(account: account).sense).size).to eq(1)

      SiteSetting.set("system.sdwan.service_health.flow_window_seconds", 7_200,
                      setting_type: "integer")

      expect(silent_signals(described_class.new(account: account).sense)).to be_empty
    end

    # This is a multi-tenant control plane: one tenant widening its window
    # must not move everyone else's threshold, so the per-account value has
    # to WIN over the deployment-wide one rather than merely exist.
    it "prefers an Account#settings override over the SiteSetting" do
      deliver_flow_to_service!(observed_at: 40.minutes.ago)
      deliver_unrelated_flow!
      # 5 minutes: wide enough that the 1-minute-old unrelated flow still
      # proves the pipeline is delivering (or `telemetry_live?` gates the
      # whole sweep off and the example would pass for the wrong reason),
      # narrow enough that the service's own 40-minute-old flow falls out.
      SiteSetting.set("system.sdwan.service_health.flow_window_seconds", 300,
                      setting_type: "integer")

      expect(silent_signals(described_class.new(account: account).sense).size).to eq(1)

      account.update!(settings: (account.settings || {}).merge(
        "sdwan_service_health_flow_window_seconds" => 7_200
      ))

      expect(silent_signals(described_class.new(account: account.reload).sense)).to be_empty
    end
  end

  describe "orphaned port mappings" do
    let(:hub) { create(:sdwan_peer, account: account, network: network) }

    it "flags an enabled DNAT rule whose target VIP has no holder" do
      mapping = create(:sdwan_port_mapping, account: account, network: network,
                                            hub_peer: hub, target_peer: nil,
                                            target_virtual_ip: vip)
      vip.update!(holder_peer_ids: [])
      deliver_unrelated_flow!

      sig = sensor.sense.find { |s| s.kind == "system.sdwan_portmap_orphaned" }

      expect(sig).not_to be_nil
      expect(sig.payload["port_mapping_id"]).to eq(mapping.id)
      expect(sig.payload["reason"]).to eq("vip_has_no_holder")
      expect(sig.fingerprint).to eq("sdwan_portmap_orphaned:#{mapping.id}")
    end

    # The orphan half must NOT inherit the silence half's telemetry gate: an
    # orphaned DNAT is read entirely from DNAT rows and their targets, and
    # IPFIX collectors are optional operator-run sidecars. Gating both halves
    # left this one inert on every account that never configured one.
    it "flags an orphan when the account has no IPFIX telemetry at all" do
      mapping = create(:sdwan_port_mapping, account: account, network: network,
                                            hub_peer: hub, target_peer: nil,
                                            target_virtual_ip: vip)
      vip.update!(holder_peer_ids: [])

      kinds = sensor.sense.map(&:kind)

      expect(Sdwan::IpfixCollector.where(account_id: account.id)).to be_empty
      expect(kinds).to include("system.sdwan_portmap_orphaned")
      # ...while the silence half stays gated: no telemetry, no claim about
      # the service that `let!` put in front of the same sweep.
      expect(kinds).not_to include("system.sdwan_service_silent")
      expect(sensor.sense.first.payload["port_mapping_id"]).to eq(mapping.id)
    end

    # Orphans arrive in herds — draining one hub strands every rule behind it,
    # and this half runs on every account regardless of IPFIX. Uncapped, that
    # is one notification per rule per dedup window.
    it "caps itemised orphans per tick and summarises the remainder" do
      cap = described_class::MAX_ORPHANS_PER_TICK
      (cap + 3).times do
        create(:sdwan_port_mapping, account: account, network: network,
                                    hub_peer: hub, target_peer: nil,
                                    target_virtual_ip: vip)
      end
      vip.update!(holder_peer_ids: [])

      orphans = sensor.sense.select { |s| s.kind == "system.sdwan_portmap_orphaned" }
      itemised, overflow = orphans.partition { |s| s.payload["overflow"].blank? }

      expect(itemised.size).to eq(cap)
      expect(overflow.size).to eq(1)
      expect(overflow.first.payload["emitted_count"]).to eq(cap)
      expect(overflow.first.fingerprint).to eq("sdwan_portmap_orphaned_overflow:#{account.id}")
    end

    # The reason names the object the operator should go look at. A review
    # asked for a "target row was deleted" reason too; that state is
    # unreachable — both target FKs are RESTRICT, so the delete is refused
    # outright. This pins the guarantee, so if anyone ever adds
    # on_delete: :nullify the sensor's reasoning is revisited rather than
    # silently starting to lie.
    it "cannot be reached by a deleted target: the FK refuses the delete" do
      create(:sdwan_port_mapping, account: account, network: network,
                                  hub_peer: hub, target_peer: nil,
                                  target_virtual_ip: vip)

      expect { Sdwan::VirtualIp.where(id: vip.id).delete_all }
        .to raise_error(ActiveRecord::InvalidForeignKey)
    end

    # Defensive branch: assigned_address is NOT NULL, presence-validated, and
    # auto-allocated by a callback, so only a blank written straight past the
    # model reaches it. resolved_target_address guards with .presence, so the
    # branch exists — this pins that it is labelled for the PEER rather than
    # inheriting the VIP wording.
    it "names the peer, not the VIP, when the target peer has no overlay address" do
      target = create(:sdwan_peer, account: account, network: network)
      target.update_column(:assigned_address, "")
      mapping = create(:sdwan_port_mapping, account: account, network: network,
                                            hub_peer: hub, target_peer: target,
                                            target_virtual_ip: nil)
      deliver_unrelated_flow!

      sig = sensor.sense.find { |s| s.payload["port_mapping_id"] == mapping.id }

      expect(sig.payload["reason"]).to eq("target_peer_unaddressed")
    end

    it "does not flag a mapping whose target still resolves" do
      create(:sdwan_port_mapping, account: account, network: network,
                                  hub_peer: hub, target_peer: nil,
                                  target_virtual_ip: vip)
      deliver_unrelated_flow!

      expect(sensor.sense.map(&:kind)).not_to include("system.sdwan_portmap_orphaned")
    end
  end

  # A sensor that is not in SENSORS never runs, and a signal kind with no
  # SIGNAL_BINDINGS entry is dropped by DecisionEngine as :skipped. Both ends
  # of the lane are asserted here so it cannot ship inert.
  describe "wiring" do
    it "is registered in the fleet sense pass" do
      expect(System::Fleet::FleetAutonomyService::SENSORS).to include(described_class)
    end

    it "routes both kinds to the notify-level investigate category" do
      bindings = System::Fleet::DecisionEngine::SIGNAL_BINDINGS

      %w[system.sdwan_service_silent system.sdwan_portmap_orphaned].each do |kind|
        expect(bindings).to have_key(kind)
        expect(bindings[kind][:action_category]).to eq("system.sdwan_service_health_investigate")
        expect(bindings[kind][:skill]).to be_nil
      end
    end

    # The policy must be seeded on the agent that RUNS the tick — Fleet
    # Autonomy resolves policies with where(ai_agent_id: agent.id), so a
    # policy on any other agent leaves gate_action! returning :blocked.
    it "seeds the gate policy on the agent that runs the sense pass" do
      seed = Rails.root.join("../extensions/system/server/db/seeds/fleet_autonomy_agent.rb")
      expect(seed.read).to include('"system.sdwan_service_health_investigate" => "notify_and_proceed"')
    end

    # The third end of the lane, and the least obvious. notify_and_proceed
    # decides :proceed, which mints a pending RemediationOutcome — but this
    # lane never actuates anything, and a dead workload cannot clear inside
    # the 90s SETTLE_WINDOW. Undeclared, it would score ineffective every
    # window until STUCK_STREAK_THRESHOLD manufactured a false
    # fleet.remediation_stuck HIGH escalation and forced require_approval.
    it "is declared non-remediating so it stays out of the validate arc" do
      expect(System::Fleet::RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES)
        .to include("system.sdwan_service_health_investigate")
    end
  end
end
