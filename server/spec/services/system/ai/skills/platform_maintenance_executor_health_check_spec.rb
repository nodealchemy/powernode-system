# frozen_string_literal: true

require "rails_helper"

# Offer 01a07024-d980 — three verbs disagreed about platform health and the
# disagreement reached an operator.
#
# Live 2026-09-05 04:48Z: `platform_maintenance action=health_check` returned
# overall "ok" in the same minute `platform_resilience op=failover_check`
# returned 11 (now 12) NodeInstances in status "error". health_check could not
# see them: it built four subsystem entries (rails, postgres, acme,
# federation) and `rails_health` was the literal `{ status: "ok" }` — a
# constant that can never be anything else.
#
# The oracles that matter here are therefore the NEGATIVE ones. A composite
# that reports "ok" is indistinguishable from the constant it replaces, so
# every example below asserts that some real condition STOPS overall being
# "ok", and the `not_measured` examples assert that a subsystem nobody could
# observe never counts as healthy.
RSpec.describe System::Ai::Skills::PlatformMaintenanceExecutor do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:executor) { described_class.new(account: account, user: user) }

  # Every probe is stubbed "ok" by default so each example isolates ONE
  # subsystem. Without this the ambient environment (no worker, no proxy)
  # decides `overall` and the example proves nothing about its own subject.
  def stub_all_probes_ok(except: [])
    System::Platform::CompositeHealthProbe::SUBSYSTEMS.each do |name|
      next if Array(except).include?(name)

      allow_any_instance_of(System::Platform::CompositeHealthProbe)
        .to receive(:"probe_#{name}").and_return({ status: "ok", stubbed: true })
    end
  end

  def health_check
    executor.execute(action: "health_check")
  end

  def data(result)
    result[:data][:data]
  end

  def subsystem(result, name)
    data(result)[:subsystems][name]
  end

  def overall(result)
    data(result)[:overall]
  end

  describe "coverage" do
    it "reports every declared subsystem as its own entry with its own status" do
      stub_all_probes_ok
      result = health_check

      expected = System::Platform::CompositeHealthProbe::SUBSYSTEMS
      expect(data(result)[:subsystems].keys).to match_array(expected)
      expect(data(result)[:subsystems].values).to all(include(:status))
    end
  end

  describe "fleet instance state" do
    # THE acceptance case: the Concierge told an operator "there are no node
    # instances in error status" while 12 were.
    it "reports instances in error and refuses to call overall ok" do
      stub_all_probes_ok(except: [ :fleet_instances ])
      node = create(:system_node, account: account)
      3.times { create(:system_node_instance, node: node, status: "error") }
      create(:system_node_instance, :running, node: node, last_heartbeat_at: 1.minute.ago)

      result = health_check
      entry = subsystem(result, :fleet_instances)

      expect(entry[:error_count]).to eq(3)
      expect(entry[:total]).to eq(4)
      expect(entry[:status]).to eq("degraded")
      expect(overall(result)).not_to eq("ok")
    end

    it "reports ok only when no instance is in error and none is silent" do
      stub_all_probes_ok(except: [ :fleet_instances ])
      node = create(:system_node, account: account)
      create(:system_node_instance, :running, node: node, last_heartbeat_at: 1.minute.ago)

      entry = subsystem(health_check, :fleet_instances)

      expect(entry[:error_count]).to eq(0)
      expect(entry[:status]).to eq("ok")
    end
  end

  describe "worker-web" do
    it "reports down and drops overall off ok when worker-web refuses the connection" do
      stub_all_probes_ok(except: [ :worker_web ])
      transport = instance_double(WorkerTransport)
      allow(WorkerTransport).to receive(:new).and_return(transport)
      allow(transport).to receive(:get).with("/health")
        .and_raise(WorkerTransport::ConnectionError, "Connection refused")

      result = health_check

      expect(subsystem(result, :worker_web)[:status]).to eq("down")
      expect(overall(result)).not_to eq("ok")
      expect(overall(result)).to eq("down")
    end
  end

  describe "oracle discipline: not_measured is never healthy" do
    it "reports not_measured when a probe raises, and overall is not ok" do
      stub_all_probes_ok(except: [ :redis ])
      allow(Powernode::Redis).to receive(:new_client).and_raise(NameError, "boom")

      result = health_check

      expect(subsystem(result, :redis)[:status]).to eq("not_measured")
      expect(overall(result)).not_to eq("ok")
    end

    it "makes not_measured visibly distinct from ok and from degraded in the payload" do
      stub_all_probes_ok(except: [ :redis ])
      allow(Powernode::Redis).to receive(:new_client).and_raise(NameError, "boom")

      result = health_check

      expect(data(result)[:not_measured]).to include(:redis)
      expect(data(result)[:degraded]).to be_empty
      expect(data(result)[:down]).to be_empty
    end

    it "never reports a constant ok for rails — the entry carries how it was observed" do
      stub_all_probes_ok(except: [ :rails ])

      entry = subsystem(health_check, :rails)

      expect(entry[:observed_via]).to be_present
    end

    it "ranks an observed down above an unobservable subsystem" do
      stub_all_probes_ok(except: [ :redis, :worker_web ])
      allow(Powernode::Redis).to receive(:new_client).and_raise(NameError, "boom")
      transport = instance_double(WorkerTransport)
      allow(WorkerTransport).to receive(:new).and_return(transport)
      allow(transport).to receive(:get).and_raise(WorkerTransport::ConnectionError, "refused")

      expect(overall(health_check)).to eq("down")
    end
  end

  describe "persistence" do
    it "writes one snapshot row per run carrying the overall and the subsystems" do
      stub_all_probes_ok(except: [ :fleet_instances ])
      node = create(:system_node, account: account)
      2.times { create(:system_node_instance, node: node, status: "error") }

      expect { health_check }.to change { System::PlatformHealthSnapshot.count }.by(1)

      snapshot = System::PlatformHealthSnapshot.order(:captured_at).last
      expect(snapshot.account_id).to eq(account.id)
      expect(snapshot.overall).not_to eq("ok")
      expect(snapshot.subsystems.keys).to include("fleet_instances")
      expect(snapshot.captured_at).to be_present
    end

    it "supports reading health over a window" do
      stub_all_probes_ok
      health_check

      expect(System::PlatformHealthSnapshot.for_account(account).since(1.hour.ago).count).to eq(1)
      expect(System::PlatformHealthSnapshot.for_account(account).since(1.minute.from_now).count).to eq(0)
    end
  end

  describe "DB-driven thresholds" do
    it "reads the tick staleness window from SiteSetting rather than a literal" do
      stub_all_probes_ok(except: [ :fleet_tick ])
      System::Fleet::EventBroadcaster.emit!(
        account: account, kind: "fleet.tick_complete", severity: :low,
        payload: {}, source: "spec"
      )
      System::FleetEvent.where(account: account).update_all(emitted_at: 20.minutes.ago)

      SiteSetting.set("system.platform_health.tick_staleness_seconds", 3600, setting_type: "integer")
      expect(subsystem(health_check, :fleet_tick)[:status]).to eq("ok")

      SiteSetting.set("system.platform_health.tick_staleness_seconds", 60, setting_type: "integer")
      expect(subsystem(health_check, :fleet_tick)[:status]).to eq("degraded")
    end

    it "reports fleet tick liveness as not_measured when no tick has ever landed" do
      stub_all_probes_ok(except: [ :fleet_tick ])

      expect(subsystem(health_check, :fleet_tick)[:status]).to eq("not_measured")
    end

    it "reports an unconfigured reverse-proxy probe as not_measured, never ok" do
      stub_all_probes_ok(except: [ :reverse_proxy ])

      entry = subsystem(health_check, :reverse_proxy)
      expect(entry[:status]).to eq("not_measured")
    end
  end

  describe "the false citation is gone" do
    # The old comment said health_check "mirrors PlatformHealthController".
    # No class of that name exists in either repository. It was pointing,
    # inexactly, at Api::V1::System::Platform::HealthController — a real and
    # SEPARATE surface. The defect is the claim of authority, not the mention:
    # a comment that names the class in order to correct the record is the
    # fix, so this asserts on the CLAIM.
    let(:source) do
      File.read(
        Rails.root.join("..", "extensions", "system", "server", "app", "services",
                        "system", "ai", "skills", "platform_maintenance_executor.rb")
      )
    end

    it "no longer claims to mirror a class that does not exist" do
      expect(source).not_to match(/mirrors PlatformHealthController/)
    end

    it "says plainly that no class of that name exists" do
      expect(source).to match(/No class of that name exists/)
    end
  end

  describe "the composite covers everything the surfaces it replaces covered" do
    # A producer that measures LESS than what it supersedes cannot be the
    # single truth. acme, sdwan and federation come from the old four-entry
    # health_check and from Api::V1::System::Platform::HealthController.
    it "declares the carried-over subsystems" do
      expect(System::Platform::CompositeHealthProbe::SUBSYSTEMS)
        .to include(:acme, :sdwan, :federation)
    end

    it "still surfaces expiring certificates" do
      stub_all_probes_ok(except: [ :acme ])

      entry = subsystem(health_check, :acme)
      expect(entry).to include(:expiring_within_7d, :expiring_within_30d)
    end
  end
end
