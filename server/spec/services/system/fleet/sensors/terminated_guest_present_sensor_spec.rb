# frozen_string_literal: true

require "rails_helper"

# IMP-ff6d46f2c3e1 — the CONSUMER half of gap (1) of IMP-8225624f46b1.
#
# CloudSyncService#sync_region_instances has computed "a terminated row whose
# own guest the provider still lists" on every hourly tick since
# IMP-8225624f46b1, and reported it through a warn log and a response field
# the worker job never read. This sensor is the first thing that ever ASKS —
# by reading the FleetEvent check trail the service now writes on every tick,
# never a live provider listing of its own.
#
# Two claims this file pins hardest:
#
#   1. ABSENCE HAS A MODE. A clean tick still writes a check event, with an
#      EMPTY terminated_guest_present array — never no event at all. A region
#      with no recent check event (sync stalled, or never ran) must not be
#      read the same as a region with a recent CLEAN check — the sensor must
#      emit for the found case, emit nothing for the clean case, and emit
#      nothing for the never-measured case, and those last two must be
#      reachable by different fixtures, not collapsed into one "returns []".
#   2. THE LANE REACHES A PERSON, WITH NO APPLIER. A sensor emitting a kind
#      with no DecisionEngine::SIGNAL_BINDINGS entry terminates as
#      `decision: skipped`. Nothing can safely retry or confirm a provider
#      destroy automatically, so the category is notify-only AND declared
#      non-remediating, or its standing fingerprint manufactures a false
#      fleet.remediation_stuck.
RSpec.describe System::Fleet::Sensors::TerminatedGuestPresentSensor do
  let(:account) { create(:account) }
  let(:region)  { create(:system_provider_region, account: account) }
  let(:node)    { create(:system_node, account: account) }

  subject(:signals) { described_class.new(account: account).sense }

  def terminated_instance!(cloud_instance_id: "pve1/qemu/9301", guest_name: "web-t")
    create(:system_node_instance, node: node, status: "terminated",
                                  cloud_instance_id: cloud_instance_id, provider_guest_name: guest_name)
  end

  def check_event!(instance_ids:, region: self.region, emitted_at: Time.current)
    System::FleetEvent.create!(
      account: account,
      kind: System::CloudSyncService::TERMINATED_GUEST_CHECK_EVENT_KIND,
      severity: instance_ids.any? ? "high" : "low",
      source: "cloud_sync_service",
      emitted_at: emitted_at,
      payload: {
        "provider_region_id" => region.id,
        "checked_at" => emitted_at.utc.iso8601,
        "terminated_guest_present" => instance_ids
      }
    )
  end

  it "emits a signal for a terminated instance the latest check named" do
    instance = terminated_instance!
    check_event!(instance_ids: [ instance.id ])

    expect(signals.size).to eq(1)
    signal = signals.first
    expect(signal.kind).to eq("system.cloud_sync_terminated_guest_present")
    expect(signal.severity).to eq(:high)
    expect(signal.payload["instance_id"]).to eq(instance.id)
    expect(signal.payload["cloud_instance_id"]).to eq(instance.cloud_instance_id)
    expect(signal.fingerprint).to eq("cloud_sync_terminated_guest_present:#{instance.id}")
  end

  # The MEASURED-ZERO arm: a check event exists, names nothing — this must NOT
  # be confused with "no check ran at all" below.
  it "emits nothing when the latest check found no terminated guest present" do
    terminated_instance!
    check_event!(instance_ids: [])

    expect(signals).to eq([])
  end

  # The NEVER-MEASURED arm: no check event in the lookback window at all — a
  # DIFFERENT fixture from the clean-tick case above, and this sensor must
  # answer identically (emit nothing) WITHOUT being able to tell the two
  # apart, which is by design (staleness is a different signal's job).
  it "emits nothing when no check event exists in the lookback window" do
    terminated_instance!

    expect(signals).to eq([])
  end

  it "does not resurrect a check naming an instance that is no longer terminated" do
    instance = terminated_instance!
    check_event!(instance_ids: [ instance.id ])
    instance.update_columns(status: "running")

    expect(signals).to eq([])
  end

  # D1 (review): a stale check must not be resurrected as a PRESENCE signal —
  # but the region's own staleness is now a signal in its own right, added
  # after review caught that the first version of this sensor covered the
  # presence half only and stayed silent about a dead measurement path.
  it "does not resurrect a stale check as presence, but raises staleness for the region instead" do
    instance = terminated_instance!
    check_event!(instance_ids: [ instance.id ], emitted_at: 4.hours.ago)

    expect(signals.size).to eq(1)
    signal = signals.first
    expect(signal.kind).to eq("system.cloud_sync_check_stale")
    expect(signal.severity).to eq(:high)
    expect(signal.payload["provider_region_id"]).to eq(region.id)
    expect(signal.payload["last_checked_at"]).to be_present
    expect(signal.fingerprint).to eq("cloud_sync_check_stale:#{region.id}")
  end

  describe "the staleness arm" do
    it "does not alarm a region whose latest check is within the lookback window" do
      check_event!(instance_ids: [], emitted_at: 10.minutes.ago)

      expect(signals).to eq([])
    end

    # THE NEVER-SYNCED-AT-ALL CASE, MADE EXPLICIT rather than an accidental
    # side effect of an empty query: a region (or account) with ZERO
    # check-event history has no baseline to go stale FROM, and this sensor
    # declines to cover it by design (see the sensor's own class doc) rather
    # than by omission. `region` here is never referenced by any check_event!
    # call, so it carries no history at all — distinct from the "healthy
    # clean tick" and "stale" fixtures above, which both start from a region
    # that HAS synced at least once.
    it "does not alarm a region with no check-event history at all" do
      terminated_instance!

      expect(signals).to eq([])
    end

    it "finds a region's true last check even when it falls outside any recent window" do
      old_check_at = 120.days.ago
      check_event!(instance_ids: [], emitted_at: old_check_at)

      expect(signals.size).to eq(1)
      expect(signals.first.kind).to eq("system.cloud_sync_check_stale")
      expect(Time.zone.parse(signals.first.payload["last_checked_at"])).to be_within(1.second).of(old_check_at)
    end

    # A region deliberately disabled (or deleted) after its last check will
    # never check in again BY DESIGN — alarming on it forever would be a
    # permanent false positive with no way to self-clear.
    it "does not alarm a region that was disabled after going stale" do
      check_event!(instance_ids: [], emitted_at: 5.hours.ago)
      region.update!(enabled: false)

      expect(signals).to eq([])
    end

    it "does not cross accounts" do
      other_account = create(:account)
      other_region  = create(:system_provider_region, account: other_account)
      System::FleetEvent.create!(
        account: other_account, kind: System::CloudSyncService::TERMINATED_GUEST_CHECK_EVENT_KIND,
        severity: "low", source: "cloud_sync_service", emitted_at: 5.hours.ago,
        payload: { "provider_region_id" => other_region.id, "terminated_guest_present" => [] }
      )

      expect(signals).to eq([])
    end

    # F2 (review): the region-liveness lookup is account-scoped, the same
    # column CloudSyncController#sync_account filters on — not merely safe by
    # construction because today's region ids happen to come from this
    # account's own events. Provable directly: a check event naming a region
    # id that resolves to a DIFFERENT account's (enabled) row must not be
    # treated as live.
    it "does not treat a region belonging to a different account as live" do
      foreign_account = create(:account)
      foreign_region = create(:system_provider_region, account: foreign_account, enabled: true)
      check_event!(instance_ids: [], region: foreign_region, emitted_at: 5.hours.ago)

      expect(signals).to eq([])
    end

    it "is tunable per account via system_update_sensor_config, same threshold as presence" do
      check_event!(instance_ids: [], emitted_at: 4.hours.ago)

      System::Fleet::SensorConfig.upsert_for(
        account: account, sensor: "terminated_guest_present", config: { "lookback_seconds" => 5.hours.to_i }
      )

      expect(signals).to eq([])
    end
  end

  describe "per-tick budgets" do
    it "bounds presence signals via max_per_tick" do
      instance_a = terminated_instance!(cloud_instance_id: "pve1/qemu/9310")
      instance_b = terminated_instance!(cloud_instance_id: "pve1/qemu/9311")
      check_event!(instance_ids: [ instance_a.id, instance_b.id ])

      System::Fleet::SensorConfig.upsert_for(
        account: account, sensor: "terminated_guest_present", config: { "max_per_tick" => 1 }
      )

      expect(signals.size).to eq(1)
      expect(signals.first.kind).to eq("system.cloud_sync_terminated_guest_present")
    end

    it "bounds staleness signals via its OWN max_stale_per_tick, independent of max_per_tick" do
      region_a = create(:system_provider_region, account: account)
      region_b = create(:system_provider_region, account: account)
      check_event!(instance_ids: [], region: region_a, emitted_at: 5.hours.ago)
      check_event!(instance_ids: [], region: region_b, emitted_at: 5.hours.ago)

      System::Fleet::SensorConfig.upsert_for(
        account: account, sensor: "terminated_guest_present", config: { "max_stale_per_tick" => 1 }
      )

      expect(signals.size).to eq(1)
      expect(signals.first.kind).to eq("system.cloud_sync_check_stale")
    end

    # THE F1 REGRESSION TEST: a presence burst at (or past) its own budget
    # must NOT crowd staleness out of a shared cap. Before this fix,
    # concatenating both arms and taking one combined `.first(max_per_tick)`
    # meant a presence burst of exactly max_per_tick silently dropped every
    # staleness signal — "there are leaked instances" starving "the detector
    # that finds them may be dead", which this whole round exists to prevent.
    it "still emits staleness when presence alone already fills its own budget" do
      instances = Array.new(3) { |i| terminated_instance!(cloud_instance_id: "pve1/qemu/93#{20 + i}") }
      check_event!(instance_ids: instances.map(&:id))

      stale_region = create(:system_provider_region, account: account)
      check_event!(instance_ids: [], region: stale_region, emitted_at: 5.hours.ago)

      System::Fleet::SensorConfig.upsert_for(
        account: account, sensor: "terminated_guest_present", config: { "max_per_tick" => 3 }
      )

      kinds = signals.map(&:kind)
      expect(kinds).to include("system.cloud_sync_terminated_guest_present")
      expect(kinds).to include("system.cloud_sync_check_stale")
    end
  end

  it "uses only the LATEST check per region, dropping a superseded find" do
    instance = terminated_instance!
    check_event!(instance_ids: [ instance.id ], emitted_at: 2.hours.ago)
    check_event!(instance_ids: [], emitted_at: 1.hour.ago)

    expect(signals).to eq([])
  end

  it "does not cross accounts" do
    other_account = create(:account)
    other_region  = create(:system_provider_region, account: other_account)
    other_node    = create(:system_node, account: other_account)
    other = create(:system_node_instance, node: other_node, status: "terminated",
                                          cloud_instance_id: "pve1/qemu/9302", provider_guest_name: "web-other")
    System::FleetEvent.create!(
      account: other_account, kind: System::CloudSyncService::TERMINATED_GUEST_CHECK_EVENT_KIND,
      severity: "high", source: "cloud_sync_service",
      payload: { "provider_region_id" => other_region.id, "terminated_guest_present" => [ other.id ] }
    )

    expect(signals).to eq([])
  end

  describe "lookback threshold" do
    it "is tunable per account via system_update_sensor_config" do
      instance = terminated_instance!
      check_event!(instance_ids: [ instance.id ], emitted_at: 4.hours.ago)

      System::Fleet::SensorConfig.upsert_for(
        account: account, sensor: "terminated_guest_present", config: { "lookback_seconds" => 5.hours.to_i }
      )

      expect(signals.size).to eq(1)
    end
  end

  describe "wiring" do
    it "routes through a notify-only, applier-less DecisionEngine binding" do
      binding = System::Fleet::DecisionEngine::SIGNAL_BINDINGS.fetch("system.cloud_sync_terminated_guest_present")

      expect(binding[:skill]).to be_nil
      expect(System::Fleet::DecisionEngine::REMEDIATION_APPLIERS).not_to have_key("system.cloud_sync_terminated_guest_present")
      expect(binding[:action_category]).to eq("system.cloud_sync_terminated_guest_investigate")
    end

    it "declares the action category non-remediating so a standing case cannot fake a stuck remediation" do
      expect(System::Fleet::RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES)
        .to include("system.cloud_sync_terminated_guest_investigate")
    end

    it "routes the staleness kind through its OWN notify-only, applier-less binding" do
      binding = System::Fleet::DecisionEngine::SIGNAL_BINDINGS.fetch("system.cloud_sync_check_stale")

      expect(binding[:skill]).to be_nil
      expect(System::Fleet::DecisionEngine::REMEDIATION_APPLIERS).not_to have_key("system.cloud_sync_check_stale")
      expect(binding[:action_category]).to eq("system.cloud_sync_check_stale_investigate")
      # DISTINCT from the presence category — the two must stay separable so
      # an operator resolving one cannot dismiss the other by association.
      expect(binding[:action_category]).not_to eq(
        System::Fleet::DecisionEngine::SIGNAL_BINDINGS.fetch("system.cloud_sync_terminated_guest_present")[:action_category]
      )
    end

    it "declares the staleness category non-remediating too" do
      expect(System::Fleet::RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES)
        .to include("system.cloud_sync_check_stale_investigate")
    end

    it "seeds both categories notify_and_proceed on Fleet Autonomy" do
      expect(System::Governance::PolicyDeclarations::FLEET_AUTONOMY_POLICIES["system.cloud_sync_terminated_guest_investigate"])
        .to eq("notify_and_proceed")
      expect(System::Governance::PolicyDeclarations::FLEET_AUTONOMY_POLICIES["system.cloud_sync_check_stale_investigate"])
        .to eq("notify_and_proceed")
    end

    it "is registered in the live sensor tick" do
      expect(System::Fleet::FleetAutonomyService::SENSORS).to include(described_class)
    end
  end
end
