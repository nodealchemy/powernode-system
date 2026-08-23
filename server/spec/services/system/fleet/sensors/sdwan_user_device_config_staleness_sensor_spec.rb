# frozen_string_literal: true

require "rails_helper"

# IMP-7034199a5a19 — issued user-device configs drift silently.
#
# Sdwan::WgConfigRenderer widens a client's AllowedIPs to the network /64 PLUS
# every active/pending VirtualIp, every peer's advertised lan_subnets, and
# every federated prefix (IMP-94f3ec671b15). Node peers re-pull that surface on
# every tick; a USER DEVICE is rendered exactly once, at download time
# (BootstrapController#show, then mark_downloaded! makes the URL 410). A VIP or
# a federation prefix added AFTERWARDS is therefore absent from every
# previously-issued client's cryptographic routing filter — unreachable, with
# no error anywhere, until someone re-issues by hand.
#
# This sensor is the missing comparison. It is READ-SIDE and NOTIFY-ONLY: no
# applier exists and none can, because the config lives on a user's laptop.
#
# ============================================================================
# THE THREE-STATE ORACLE (the whole point of this file)
# ============================================================================
# `last_downloaded_at` has three meanings and conflating any two of them is the
# failure mode:
#
#   nil            NEVER DOWNLOADED. No config was ever issued, so there is
#                  nothing to be stale. It must NOT read as infinitely stale
#                  (the naive `last_downloaded_at < changed_at` in SQL treats
#                  NULL as unknown, but a Ruby `nil <=> Time` raises or, worse,
#                  a `.to_i` coercion makes it epoch-0 = maximally stale). It
#                  must ALSO not read as current.
#   >= changed_at  DOWNLOADED AND CURRENT. Genuinely fine.
#   <  changed_at  DOWNLOADED AND STALE. The actual signal.
#
# Each state has its OWN observable position in the payload —
# `stale_devices` / `pending_download_count` / `current_device_count` — so a
# spec can tell them apart. An assertion that merely checks "a signal fired"
# cannot, which is why the three-state example below reads all three fields off
# ONE signal with one device in each state.
RSpec.describe System::Fleet::Sensors::SdwanUserDeviceConfigStalenessSensor do
  let(:account) { create(:account) }
  let(:network) { create(:sdwan_network, account: account) }

  subject(:signals) { described_class.new(account: account).sense }

  def kinds = signals.map { |s| s[:kind] }

  # Every surface stamp is read from a row's `updated_at` (federation is the
  # documented exception — see its context below), so tests set that column
  # directly. update_columns, never update!, or the write would re-stamp the
  # very column under test.
  def stamp!(record, at)
    record.update_columns(updated_at: at)
    record
  end

  def device!(grant: nil, downloaded_at: :unset, **attrs)
    grant ||= create(:sdwan_access_grant, account: account, network: network)
    dev = create(:sdwan_user_device, access_grant: grant, **attrs)
    dev.update_columns(last_downloaded_at: downloaded_at) unless downloaded_at == :unset
    dev
  end

  # A peer is the one surface source that always exists on a real network, so
  # most contexts pin it OLD and move a different source to isolate the cause.
  def old_peer!(at: 30.days.ago)
    stamp!(create(:sdwan_peer, account: account, network: network), at)
  end

  context "with no user devices at all" do
    before { old_peer! }

    it "emits nothing" do
      expect(signals).to eq([])
    end
  end

  # ==========================================================================
  # STATE 1 — never downloaded. nil is NOT infinite staleness.
  # ==========================================================================
  context "a device that has never been downloaded, on a network mutated long after it was created" do
    before do
      old_peer!
      device!(downloaded_at: nil)
      stamp!(create(:sdwan_virtual_ip, network: network, account: account), 2.days.ago)
    end

    it "emits nothing — an unissued config cannot be stale" do
      expect(signals).to eq([])
    end
  end

  # ==========================================================================
  # STATE 2 — downloaded after the last surface change.
  # ==========================================================================
  context "a device downloaded after the most recent surface change" do
    before do
      old_peer!
      stamp!(create(:sdwan_virtual_ip, network: network, account: account), 3.days.ago)
      device!(downloaded_at: 2.days.ago)
    end

    it "emits nothing" do
      expect(signals).to eq([])
    end
  end

  # ==========================================================================
  # STATE 3 — downloaded before a surface change. The signal.
  # ==========================================================================
  context "a device downloaded before a VirtualIp was added" do
    let!(:peer)   { old_peer! }
    let!(:device) { device!(downloaded_at: 10.days.ago) }
    let!(:vip)    { stamp!(create(:sdwan_virtual_ip, network: network, account: account), 2.days.ago) }

    it "emits one per-network staleness signal naming the device" do
      expect(kinds).to eq([ "system.sdwan_user_device_config_stale" ])

      sig = signals.first
      expect(sig[:payload]["network_id"]).to eq(network.id)
      expect(sig[:payload]["stale_device_count"]).to eq(1)
      expect(sig[:payload]["stale_devices"].map { |d| d["device_id"] }).to eq([ device.id ])
      expect(sig[:payload]["surface_changed_at"]).to eq(vip.reload.updated_at.iso8601)
      expect(sig[:payload]["changed_surfaces"]["virtual_ips"]).to eq(vip.updated_at.iso8601)
    end

    it "fingerprints per (network, surface change) so a LATER mutation is a new fact" do
      first = signals.first[:fingerprint]
      expect(first).to eq(
        "sdwan_user_device_config_stale:#{network.id}:#{vip.reload.updated_at.to_i}"
      )

      stamp!(vip, 1.day.ago)
      expect(described_class.new(account: account).sense.first[:fingerprint]).not_to eq(first)
    end

    it "names NO remediation action — there is no applier for a config on a laptop" do
      expect(signals.first[:payload]["remediation_action"]).to be_nil
      expect(signals.first[:payload]["recommended_action"]).to eq("reissue_user_device_config")
    end

    it "is strictly read-side — it writes nothing" do
      before_stamp = device.reload.updated_at
      signals
      expect(device.reload.updated_at).to eq(before_stamp)
      expect(device.reload.last_downloaded_at).to be_present
    end
  end

  # ==========================================================================
  # THE THREE STATES, SIDE BY SIDE, ON ONE SIGNAL.
  # ==========================================================================
  context "one network carrying all three states at once" do
    let!(:peer) { old_peer! }
    let!(:vip)  { stamp!(create(:sdwan_virtual_ip, network: network, account: account), 2.days.ago) }

    # Deliberately UNEQUAL cardinalities (2 / 3 / 1). Equal counts would let
    # the three fields be transposed with every assertion still green, which is
    # exactly the conflation the per-state fields exist to prevent.
    let!(:stale_older) { device!(downloaded_at: 20.days.ago) }
    let!(:stale_newer) { device!(downloaded_at: 10.days.ago) }
    let!(:never_a)     { device!(downloaded_at: nil) }
    let!(:never_b)     { device!(downloaded_at: nil) }
    let!(:never_c)     { device!(downloaded_at: nil) }
    let!(:current)     { device!(downloaded_at: 1.day.ago) }

    it "puts each state in its own observable field, and no state in another's" do
      payload = signals.first[:payload]
      sampled = payload["stale_devices"].map { |d| d["device_id"] }

      # STALE — the signal.
      expect(payload["stale_device_count"]).to eq(2)
      expect(sampled).to contain_exactly(stale_older.id, stale_newer.id)

      # NEVER DOWNLOADED — counted apart, never as stale...
      expect(payload["pending_download_count"]).to eq(3)
      expect(sampled).not_to include(never_a.id, never_b.id, never_c.id)
      # ...and never as current either.
      expect(payload["current_device_count"]).to eq(1)

      # CURRENT — counted, not sampled.
      expect(sampled).not_to include(current.id)

      # The three partitions are disjoint and total over the active set.
      expect(payload["stale_device_count"] +
             payload["pending_download_count"] +
             payload["current_device_count"]).to eq(6)
    end

    it "orders the sample worst-drift-first, with the never-downloaded rows excluded not sorted first" do
      expect(signals.first[:payload]["stale_devices"].map { |d| d["device_id"] })
        .to eq([ stale_older.id, stale_newer.id ])
    end

    it "reports the full count and does not claim truncation it did not do" do
      expect(signals.first[:payload]["stale_devices_truncated"]).to be false
      expect(signals.first[:payload]["stale_devices"].size)
        .to eq(signals.first[:payload]["stale_device_count"])
    end

    it "carries the per-device staleness detail an operator needs to reach the grant holder" do
      entry = signals.first[:payload]["stale_devices"].first
      expect(entry["device_id"]).to eq(stale_older.id)
      expect(entry["label"]).to eq(stale_older.label)
      expect(entry["user_id"]).to eq(stale_older.access_grant.user_id)
      expect(entry["last_downloaded_at"]).to eq(stale_older.reload.last_downloaded_at.iso8601)
      # Measured from the DOWNLOAD to the SURFACE CHANGE — the interval the
      # config was already wrong for — not to now, and not from the download to
      # the download.
      expect(entry["stale_by_seconds"])
        .to be_within(2).of((vip.reload.updated_at - stale_older.reload.last_downloaded_at).to_i)
      expect(entry["stale_by_seconds"]).to be_within(2).of(18.days.to_i)
    end
  end

  # ==========================================================================
  # "ACTIVE" — a device the operator has already cut off makes no noise.
  # ==========================================================================
  context "a revoked device downloaded before a surface change" do
    before do
      old_peer!
      stamp!(create(:sdwan_virtual_ip, network: network, account: account), 2.days.ago)
      device!(downloaded_at: 10.days.ago, revoked_at: 1.day.ago)
    end

    it "emits nothing — a revoked device is cut off from the hub" do
      expect(signals).to eq([])
    end
  end

  context "a device whose access grant is suspended" do
    before do
      old_peer!
      stamp!(create(:sdwan_virtual_ip, network: network, account: account), 2.days.ago)
      grant = create(:sdwan_access_grant, account: account, network: network, status: "suspended")
      device!(grant: grant, downloaded_at: 10.days.ago)
    end

    it "emits nothing — re-issue is exactly what a non-active grant forbids" do
      expect(signals).to eq([])
    end
  end

  context "a device belonging to another account" do
    before do
      other_network = create(:sdwan_network, account: create(:account))
      stamp!(create(:sdwan_peer, account: other_network.account, network: other_network), 30.days.ago)
      stamp!(create(:sdwan_virtual_ip, network: other_network, account: other_network.account), 2.days.ago)
      grant = create(:sdwan_access_grant, account: other_network.account, network: other_network)
      create(:sdwan_user_device, access_grant: grant).update_columns(last_downloaded_at: 10.days.ago)
      # The federation arm is the one scoped by account_id rather than by a
      # network association, so it needs its own cross-account probe: drop
      # that predicate and this peer's prefix would stale OUR devices.
      fed = create(:system_federation_peer, account: other_network.account, status: "accepted",
                   remote_prefix_advertisement: "fd99:8877::/48")
      fed.update_columns(created_at: 2.days.ago, updated_at: 2.days.ago)
    end

    it "emits nothing for this account" do
      expect(signals).to eq([])
    end
  end

  # ==========================================================================
  # THE OTHER TWO SURFACE SOURCES.
  # ==========================================================================
  # NOTE the label: lan_subnets ONLY. A hub KEY rotation reaches this same arm
  # but by a different route (Sdwan::PeerKey's `touch: true`, IMP-8ce5262ee9ec)
  # and has its own context below, because the two can regress independently.
  context "a contributing peer edited after the device was issued (lan_subnets)" do
    before do
      stamp!(create(:sdwan_peer, account: account, network: network, lan_subnets: [ "fd00:1::/64" ]), 2.days.ago)
      device!(downloaded_at: 10.days.ago)
    end

    it "fires, attributing the change to the peer surface" do
      expect(kinds).to eq([ "system.sdwan_user_device_config_stale" ])
      expect(signals.first[:payload]["changed_surfaces"]["peers"]).to be_present
      expect(signals.first[:payload]["changed_surfaces"]["virtual_ips"]).to be_nil
    end
  end

  # ==========================================================================
  # IMP-8ce5262ee9ec — A HUB RE-KEY BREAKS EVERY ISSUED CONFIG OUTRIGHT.
  # ==========================================================================
  # WgConfigRenderer emits one [Peer] section per publicly-reachable hub
  # carrying that hub's CURRENT public key. A node peer re-pulls and converges;
  # a user device is rendered once, at download time, and the bootstrap URL
  # 410s straight after. So after a rotation every previously-issued client
  # holds a key the hub no longer has and its tunnel stops handshaking — worse
  # than the narrowed-AllowedIPs drift the rest of this file is about, on an
  # autonomous lane with no approval gate (system.sdwan_peer_drift →
  # SdwanPeerRemediateExecutor, seeded notify_and_proceed).
  #
  # WHICH PATH THESE EXAMPLES DRIVE, AND WHY IT MATTERS
  # ---------------------------------------------------
  # `Sdwan::KeyDistributor.rotate!` DIRECTLY — never
  # System::Ai::Skills::SdwanPeerRemediateExecutor. That executor calls the
  # same rotate! and THEN does `peer.update_columns(..., updated_at:
  # Time.current)` for its own reconcile reasons, which moves this arm's stamp
  # by coincidence. An oracle written against the executor is green with or
  # without `touch: true` and proves nothing. rotate! on its own writes ONLY
  # PeerKey rows, and is the path that was genuinely blind.
  #
  # AND THE ASSERTION IS THE OUTCOME, NOT THE TIMESTAMP: that the sensor now
  # reports the device stale. `expect { }.to change { peer.updated_at }` would
  # pass against a touch no consumer reads.
  #
  # No key material is read, printed or asserted on anywhere below — only
  # signal payloads and row identity.
  context "a hub re-keyed after the device was issued, rotated via the standalone KeyDistributor path" do
    let!(:hub)    { stamp!(create(:sdwan_peer, :hub, :active, account: account, network: network, lan_subnets: []), 30.days.ago) }
    let!(:device) { device!(downloaded_at: 10.days.ago) }

    before { Sdwan::KeyDistributor.ensure_key_for!(hub) }

    # The control. Without it, an example that fires after rotation cannot
    # distinguish "the rotation was detected" from "this network was already
    # stale for some unrelated reason" — the genesis key write is itself a
    # PeerKey write, so the touch fires here too and has to be pinned back
    # down before the rotation under test.
    it "is quiet before the rotation" do
      stamp!(hub, 30.days.ago)
      expect(signals).to eq([])
    end

    it "reports the previously-issued config stale — the outcome, not the stamp" do
      stamp!(hub, 30.days.ago)

      Sdwan::KeyDistributor.rotate!(peer: hub.reload, reason: "spec_standalone_path")
      # Clear the 15-minute settle window; a rotation stamped at ~now is
      # deliberately not yet drift (DEFAULT_SETTLE_AFTER_SECONDS).
      travel 20.minutes

      expect(kinds).to eq([ "system.sdwan_user_device_config_stale" ])
      payload = signals.first[:payload]
      expect(payload["stale_devices"].map { |d| d["device_id"] }).to eq([ device.id ])
      expect(payload["changed_surfaces"]["peers"]).to be_present
      # Attributed to the peer arm alone — no VIP or federation row exists here,
      # so nothing else could have moved the surface.
      expect(payload["changed_surfaces"]["virtual_ips"]).to be_nil
      expect(payload["changed_surfaces"]["federation_prefixes"]).to be_nil
    end

    # The settle window is not bypassed by the new write path.
    it "stays quiet immediately after the rotation" do
      stamp!(hub, 30.days.ago)
      Sdwan::KeyDistributor.rotate!(peer: hub.reload, reason: "spec_standalone_path")

      expect(signals).to eq([])
    end
  end

  context "an ACTIVE VirtualIp added after the device was issued" do
    before do
      old_peer!
      device!(downloaded_at: 10.days.ago)
      stamp!(create(:sdwan_virtual_ip, network: network, account: account, state: "active"), 2.days.ago)
    end

    # Both halves of RENDERED_VIP_STATES need their own example: the factory
    # defaults to "pending", so without this one the "active" arm could be
    # dropped and diverge from WgConfigRenderer#vip_cidrs undetected.
    it "fires — active is inside the window the renderer folds in" do
      expect(kinds).to eq([ "system.sdwan_user_device_config_stale" ])
    end
  end

  # ==========================================================================
  # ONLY PEERS THAT PUT SOMETHING IN THE CONFIG COUNT.
  # ==========================================================================
  context "a plain spoke enrolled after the device was issued" do
    before do
      old_peer!
      device!(downloaded_at: 10.days.ago)
      stamp!(create(:sdwan_peer, account: account, network: network,
                    lan_subnets: [], publicly_reachable: false), 2.days.ago)
    end

    it "emits nothing — a spoke advertising nothing renders nothing into a client config" do
      expect(signals).to eq([])
    end
  end

  context "a publicly-reachable hub enrolled after the device was issued" do
    before do
      old_peer!
      device!(downloaded_at: 10.days.ago)
      stamp!(create(:sdwan_peer, :hub, account: account, network: network, lan_subnets: []), 2.days.ago)
    end

    it "fires — a hub renders a [Peer] section the issued config does not have" do
      expect(kinds).to eq([ "system.sdwan_user_device_config_stale" ])
    end
  end

  context "a network that is archived" do
    before do
      old_peer!
      device!(downloaded_at: 10.days.ago)
      stamp!(create(:sdwan_virtual_ip, network: network, account: account), 2.days.ago)
      network.update_columns(status: "archived")
    end

    it "emits nothing — nobody will re-issue into a network being torn down" do
      expect(signals).to eq([])
    end
  end

  context "a VirtualIp in a state outside the rendered window" do
    before do
      old_peer!
      device!(downloaded_at: 10.days.ago)
      stamp!(create(:sdwan_virtual_ip, network: network, account: account, state: "unassigned"), 2.days.ago)
    end

    it "emits nothing — the renderer never folded that VIP in, so nothing drifted" do
      expect(signals).to eq([])
    end
  end

  # ==========================================================================
  # FEDERATION — the arm where `updated_at` is a TRAP.
  # ==========================================================================
  # System::FederationPeer#record_heartbeat! is a plain `update!`, so a live
  # platform peer bumps its `updated_at` every 60 seconds forever. Anchoring
  # this arm on `updated_at` would put max(surface) at ~now on every tick, and
  # EVERY downloaded device in every federated account would be permanently
  # "stale" — a false alarm on the whole fleet, which is precisely the
  # operator-ignores-the-lane failure this sensor must not have. The federation
  # arm is therefore anchored on `created_at` of the CONTRIBUTING peers, which
  # is exactly the case the finding names (a federation peer added after
  # download).
  context "a contributing federation peer created after the device was issued" do
    before do
      old_peer!
      device!(downloaded_at: 10.days.ago)
      peer = create(:system_federation_peer, account: account, status: "accepted",
                    remote_prefix_advertisement: "fd11:2233::/48")
      peer.update_columns(created_at: 2.days.ago, updated_at: 2.days.ago)
    end

    it "fires, attributing the change to the federation surface" do
      expect(kinds).to eq([ "system.sdwan_user_device_config_stale" ])
      expect(signals.first[:payload]["changed_surfaces"]["federation_prefixes"]).to be_present
    end
  end

  context "a federation peer that merely HEARTBEAT since the device was issued" do
    before do
      old_peer!
      device!(downloaded_at: 10.days.ago)
      peer = create(:system_federation_peer, :active, account: account,
                    remote_prefix_advertisement: "fd11:2233::/48")
      # Enrolled long before the device downloaded; only its heartbeat is new.
      # This is what record_heartbeat! leaves behind: a fresh updated_at on a
      # row whose advertised prefix has not moved in a month.
      # 1.hour.ago, NOT Time.current, and that is the whole point of this
      # example: a heartbeat stamped inside the 15-minute settle window would
      # be swallowed by the window, so an `updated_at`-anchored sensor would
      # pass this example for the WRONG reason and the created_at decision
      # would be untested. An hour clears the settle window and post-dates the
      # device's 10-day-old download, so anchoring on updated_at FIRES here and
      # anchoring on created_at stays quiet.
      peer.update_columns(created_at: 30.days.ago, updated_at: 1.hour.ago,
                          last_heartbeat_at: Time.current)
    end

    it "emits nothing — a heartbeat is not a change to the routable surface" do
      expect(signals).to eq([])
    end
  end

  context "a federation peer whose status excludes it from the rendered prefixes" do
    before do
      old_peer!
      device!(downloaded_at: 10.days.ago)
      peer = create(:system_federation_peer, account: account, status: "revoked",
                    remote_prefix_advertisement: "fd11:2233::/48")
      peer.update_columns(created_at: 2.days.ago, updated_at: 2.days.ago)
    end

    it "emits nothing — a revoked peer contributes no prefix, so nothing drifted" do
      expect(signals).to eq([])
    end
  end

  # ==========================================================================
  # WINDOWS.
  # ==========================================================================
  context "a surface change younger than the settle window" do
    before do
      old_peer!
      device!(downloaded_at: 10.days.ago)
      stamp!(create(:sdwan_virtual_ip, network: network, account: account), 1.minute.ago)
    end

    it "stays quiet — an operator mid-edit is not yet drift" do
      expect(signals).to eq([])
    end
  end

  context "one arm churning inside the settle window while another has settled" do
    before do
      old_peer!
      device!(downloaded_at: 10.days.ago)
      # Settled, and genuinely stale.
      stamp!(create(:sdwan_virtual_ip, network: network, account: account), 2.days.ago)
      # Churning: a contributing peer whose updated_at was just moved (this is
      # what SdwanPeerRemediateExecutor does on every remediation, and what
      # FederationPeer#record_heartbeat! does every 60s).
      stamp!(create(:sdwan_peer, account: account, network: network,
                    lan_subnets: [ "fd00:9::/64" ]), 5.seconds.ago)
    end

    # If the settle window were applied to the MAX rather than per arm, the
    # churning arm would hold the network inside the window forever and this
    # sensor would go permanently DARK — the silent failure, not a false alarm.
    it "still reports the settled arm" do
      expect(kinds).to eq([ "system.sdwan_user_device_config_stale" ])
      surfaces = signals.first[:payload]["changed_surfaces"]
      expect(surfaces["virtual_ips"]).to be_present
      expect(surfaces["peers"]).to be_nil
    end
  end

  describe "severity" do
    before do
      old_peer!
      device!(downloaded_at: 60.days.ago)
    end

    it "is medium while the drift is young" do
      stamp!(create(:sdwan_virtual_ip, network: network, account: account), 1.hour.ago)
      expect(signals.first[:severity]).to eq(:medium)
    end

    it "escalates to high once the drift has stood past the escalation age" do
      stamp!(create(:sdwan_virtual_ip, network: network, account: account), 3.days.ago)
      expect(signals.first[:severity]).to eq(:high)
    end
  end

  describe "thresholds are DB-driven" do
    before do
      old_peer!
      device!(downloaded_at: 10.days.ago)
      stamp!(create(:sdwan_virtual_ip, network: network, account: account), 10.minutes.ago)
    end

    it "reads the settle window from the account settings before the constant" do
      expect(signals).to eq([]) # default 15-minute settle window swallows it

      account.update!(settings: (account.settings || {}).merge(
        "sdwan_user_device_staleness_settle_after_seconds" => 60
      ))
      expect(described_class.new(account: account).sense.map { |s| s[:kind] })
        .to eq([ "system.sdwan_user_device_config_stale" ])
    end
  end

  # ==========================================================================
  # WIRING — the notify-only exemption, without which this lane manufactures a
  # false fleet.remediation_stuck (the recorded F3-11 failure mode).
  # ==========================================================================
  describe "wiring" do
    it "is registered in the fleet tick" do
      expect(System::Fleet::FleetAutonomyService::SENSORS).to include(described_class)
    end

    it "binds to a notify-only category with no skill" do
      binding = System::Fleet::DecisionEngine::SIGNAL_BINDINGS
                .fetch("system.sdwan_user_device_config_stale")
      expect(binding[:skill]).to be_nil
      expect(binding[:action_category]).to eq("system.sdwan_user_device_config_investigate")
    end

    # THE EXEMPTION. Without this entry the validate arc records a pending
    # RemediationOutcome for a lane that never acted; the fingerprint stands
    # (nobody can re-issue a laptop's config within SETTLE_WINDOW), so it is
    # scored ineffective every window until the F3-11 streak trips a false
    # fleet.remediation_stuck HIGH escalation and forces require_approval on a
    # lane that is doing exactly what it was built to do.
    it "is exempt from the remediation-validate arc" do
      expect(System::Fleet::RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES)
        .to include("system.sdwan_user_device_config_investigate")
    end

    # Without this the category seeds and gates fine but is UN-SAVEABLE in the
    # operator Autonomy modal (System::AutonomyActions#update validates against
    # this registry) — five sensor-gated categories have already shipped in
    # exactly that state.
    it "is registered as a tunable action category" do
      expect(::Ai::InterventionPolicy.category_registered?("system.sdwan_user_device_config_investigate"))
        .to be true
    end

    # Ordinary sensor Signal on the LIVE transport. The metric.* FleetEvent →
    # Slo::TelemetryAdapter → ScoreEvaluator lane is dormant by operator
    # decision; this sensor must stay out of it.
    it "stays out of the dormant SLO telemetry lane" do
      expect(kinds.grep(/\Ametric\./)).to be_empty
      expect(System::Fleet::DecisionEngine::SIGNAL_BINDINGS
               .fetch("system.sdwan_user_device_config_stale")[:skill]).to be_nil
    end
  end
end
