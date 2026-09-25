# frozen_string_literal: true

require "rails_helper"

# Campaign 01a08c9b increment B1 — the extension's one registration call, and
# the sweep it feeds.
RSpec.describe System::Status::Contributors do
  let(:account) { create(:account) }

  # Narrowly scoped: Rails itself calls Dir.glob constantly, so only this one
  # pattern is replaced and everything else still hits the filesystem.
  def stub_glob(paths)
    allow(Dir).to receive(:glob).and_call_original
    allow(Dir).to receive(:glob).with(described_class::CONTRIBUTOR_GLOB).and_return(paths)
  end

  # The registry is process-global and the engine's to_prepare has already
  # populated it. Snapshot and restore so an example that unregisters a kind
  # cannot leak into the next file.
  around do |example|
    saved = Platform::Status::Registry.contributors
    example.run
  ensure
    Platform::Status::Registry.reset!
    saved.each { |kind, contributor| Platform::Status::Registry.register(kind, contributor) }
  end

  describe ".register_all!" do
    it "registers every contributor file under its own KIND" do
      Platform::Status::Registry.reset!

      registered = described_class.register_all!

      expect(registered).to include("platform_subsystem")
      expect(registered).to match_array(described_class.kinds)
      expect(Platform::Status::Registry.fetch("platform_subsystem"))
        .to be_a(System::Status::Contributors::PlatformSubsystemContributor)
    end

    it "derives the set from the files on disk, not from a list" do
      on_disk = Dir.glob(described_class::CONTRIBUTOR_GLOB).map { |p| File.basename(p, ".rb") }

      expect(on_disk).to include("platform_subsystem_contributor")
      expect(described_class.contributor_classes.size).to eq(on_disk.size)
    end

    it "is idempotent — a second call replaces rather than accumulates" do
      Platform::Status::Registry.reset!

      described_class.register_all!
      after_first = Platform::Status::Registry.contributors

      described_class.register_all!
      after_second = Platform::Status::Registry.contributors

      expect(after_second.size).to eq(after_first.size)
      expect(after_second.keys.count("platform_subsystem")).to eq(1)
      # Last-write-wins: the instance is replaced, which is what makes a
      # dev-mode reload serve the fresh class.
      expect(after_second["platform_subsystem"]).not_to equal(after_first["platform_subsystem"])
    end

    it "skips a helper file that resolves to something which is not a contributor" do
      # Core's contributors directory already holds two KIND-less helpers, and
      # this directory is due nine more contributors. Without the filter the
      # first shared helper dropped here would raise on ::KIND, the engine would
      # rescue it, and the registry would hold ZERO extension kinds — one
      # unrelated file removing every system kind from the plane.
      stub_const("System::Status::Contributors::EnumConditions", Module.new)
      stub_glob([ "/x/enum_conditions.rb", "/x/platform_subsystem_contributor.rb" ])

      expect(described_class.contributor_classes)
        .to eq([ System::Status::Contributors::PlatformSubsystemContributor ])
    end

    it "skips a subclass that has no KIND of its own, rather than letting it steal its parent's" do
      variant = Class.new(System::Status::Contributors::PlatformSubsystemContributor)
      stub_const("System::Status::Contributors::VariantContributor", variant)
      stub_glob([ "/x/variant_contributor.rb" ])

      # The hazard, stated: the subclass DOES answer ::KIND, inherited, and
      # Registry.register is last-write-wins — so without const_defined?(.., false)
      # it would silently overwrite its parent under the parent's key.
      expect(variant::KIND).to eq("platform_subsystem")
      expect(described_class.contributor_classes).to eq([])
    end

    it "still registers a real contributor alongside a skipped file" do
      stub_const("System::Status::Contributors::EnumConditions", Module.new)
      stub_glob([ "/x/enum_conditions.rb", "/x/platform_subsystem_contributor.rb" ])
      Platform::Status::Registry.reset!

      expect(described_class.register_all!).to eq([ "platform_subsystem" ])
    end

    it "raises rather than shrugging when a contributor file cannot be resolved" do
      # No compat shim: a contributor that will not load is a deploy defect and
      # must not present as an empty, healthy-looking status plane.
      stub_glob([ "/nowhere/ghost_contributor.rb" ])

      expect { described_class.register_all! }.to raise_error(NameError)
    end
  end

  describe "end to end through the sweep" do
    before do
      Platform::Status::Registry.reset!
      described_class.register_all!
    end

    it "writes one row per subsystem with no snapshot present" do
      result = Platform::Status::SweepService.run_once!(account)

      rows = Platform::ComponentStatus.where(account_id: account.id,
                                             component_kind: "platform_subsystem")

      expect(rows.count).to eq(System::Platform::CompositeHealthProbe::SUBSYSTEMS.size)
      expect(rows.pluck(:verdict).uniq).to eq([ Platform::ComponentStatus::NOT_MEASURED ])
      expect(result[:kinds]["platform_subsystem"][:errors]).to eq(0)
    end

    it "writes the verdict, links and presentation a page can render without knowing the kind" do
      System::PlatformHealthSnapshot.create!(
        account: account, overall: "down", captured_at: Time.current, source: "spec",
        subsystems: System::Platform::CompositeHealthProbe::SUBSYSTEMS.index_with { |name|
          name == :postgres ? { "status" => "down", "error" => "refused" } : { "status" => "ok" }
        }
      )

      Platform::Status::SweepService.run_once!(account)

      postgres = Platform::ComponentStatus.find_by(account_id: account.id,
                                                   component_kind: "platform_subsystem",
                                                   component_ref: "postgres")
      rails_row = Platform::ComponentStatus.find_by(account_id: account.id,
                                                    component_kind: "platform_subsystem",
                                                    component_ref: "rails")

      expect(postgres.verdict).to eq(Platform::ComponentStatus::DOWN)
      expect(rails_row.verdict).to eq(Platform::ComponentStatus::OK)
      expect(postgres.display_name).to eq("Postgres")
      expect(postgres.presentation["icon"]).to eq("Activity")
      expect(postgres.links.first["path"]).to eq("/app/system/compute/platform")
      expect(postgres.actions).to eq([])
      expect(postgres.conditions.map { |c| c["type"] }).to match_array(%w[Healthy Fresh])
    end

    it "moves observed_generation when a new snapshot is captured, and holds it when none is" do
      subsystems = System::Platform::CompositeHealthProbe::SUBSYSTEMS.index_with { { "status" => "ok" } }
      first_snapshot = System::PlatformHealthSnapshot.create!(
        account: account, overall: "ok", captured_at: 1.minute.ago,
        source: "spec", subsystems: subsystems
      )

      Platform::Status::SweepService.run_once!(account)
      row = Platform::ComponentStatus.find_by(account_id: account.id,
                                              component_kind: "platform_subsystem",
                                              component_ref: "rails")
      expect(row.observed_generation).to eq(first_snapshot.id)

      # Re-swept against the SAME snapshot: nothing new was observed, so the
      # generation must not move.
      Platform::Status::SweepService.run_once!(account)
      expect(row.reload.observed_generation).to eq(first_snapshot.id)

      second_snapshot = System::PlatformHealthSnapshot.create!(
        account: account, overall: "ok", captured_at: Time.current,
        source: "spec", subsystems: subsystems
      )

      Platform::Status::SweepService.run_once!(account)
      expect(row.reload.observed_generation).to eq(second_snapshot.id)
      expect(second_snapshot.id).not_to eq(first_snapshot.id)
    end

    # Increment B2 — the three fleet kinds, through the same sweep, with no
    # edit to the registrar or the engine.
    describe "the B2 fleet kinds" do
      let(:node) { create(:system_node, account: account) }

      # Design §5.4 ruling: a fleet kind already has an escalation path with its
      # own claim (SignalState.claim_notification!, keyed by fleet fingerprint
      # and invisible to core), so core's A7 escalation must stay OFF for it or
      # one outage pages twice, claimed in two places, neither aware of the
      # other.
      it "opts every fleet kind out of core escalation, and leaves platform_subsystem in" do
        fleet_kinds = described_class.kinds - [ "platform_subsystem" ]
        expect(fleet_kinds).to include("node", "node_instance", "instance_pool")

        fleet_kinds.each do |kind|
          expect(Platform::Status::Registry.fetch(kind).escalates?)
            .to be(false), "#{kind} would double-notify"
        end

        # The other arm: platform_subsystem has NO fleet lane of its own, so
        # core is the only thing that would ever page for it.
        expect(Platform::Status::Registry.fetch("platform_subsystem").escalates?).to be(true)
      end

      it "registers all three without the registrar naming any of them" do
        expect(described_class.kinds)
          .to include("node", "node_instance", "instance_pool", "platform_subsystem")
      end

      it "writes a row per node, instance and pool, with their edges" do
        template = create(:system_node_template, account: account)
        pool = System::InstancePool.create!(account: account, node_template: template,
                                            name: "b2-pool", target_size: 1)
        instance = create(:system_node_instance, account: account, node: node,
                                                 status: "running", last_heartbeat_at: Time.current,
                                                 instance_pool_id: pool.id, pool_state: "ready")

        Platform::Status::SweepService.run_once!(account)

        rows = Platform::ComponentStatus.where(account_id: account.id)
                                        .index_by { |row| [ row.component_kind, row.component_ref ] }

        node_row = rows[[ "node", node.id.to_s ]]
        instance_row = rows[[ "node_instance", instance.id.to_s ]]
        pool_row = rows[[ "instance_pool", pool.id.to_s ]]

        expect(node_row).to be_present
        expect(pool_row).to be_present
        expect(instance_row.verdict).to eq(Platform::ComponentStatus::OK)
        expect(instance_row.dependencies).to eq([
          { "kind" => "node", "ref" => node.id.to_s, "relation" => "hosts" },
          { "kind" => "instance_pool", "ref" => pool.id.to_s, "relation" => "backs" }
        ])
        expect(instance_row.actions.map { |a| a["key"] })
          .to include("reboot", "terminate")
      end

      it "reverse-walks those edges into the node's impact" do
        instance = create(:system_node_instance, account: account, node: node,
                                                 status: "running", last_heartbeat_at: Time.current)
        Platform::Status::SweepService.run_once!(account)

        node_row = Platform::ComponentStatus.find_by(account_id: account.id,
                                                     component_kind: "node",
                                                     component_ref: node.id.to_s)

        impact = Platform::Status::Rollup.impact(node_row)

        # The direction check: the instance declares `hosts` toward the node, so
        # the node's impact contains the instance and not the other way round.
        expect(impact[:components].map(&:component_ref)).to include(instance.id.to_s)
      end

      it "reaps a terminated instance's row rather than leaving a permanent down" do
        instance = create(:system_node_instance, account: account, node: node, status: "running",
                                                 last_heartbeat_at: Time.current)
        Platform::Status::SweepService.run_once!(account)
        expect(Platform::ComponentStatus.where(component_kind: "node_instance",
                                               component_ref: instance.id.to_s)).to exist

        instance.update_column(:status, "terminated")
        # Past the reap window: the contributor stops yielding it and the sweep
        # ages the row out.
        Platform::Status::SweepService.run_once!(
          account, now: Time.current + Platform::Status::SweepService.reap_after_seconds + 60
        )

        expect(Platform::ComponentStatus.where(component_kind: "node_instance",
                                               component_ref: instance.id.to_s)).not_to exist
      end
    end

    it "keeps last_transition_at across a sweep whose verdict did not change" do
      System::PlatformHealthSnapshot.create!(
        account: account, overall: "ok", captured_at: Time.current, source: "spec",
        subsystems: System::Platform::CompositeHealthProbe::SUBSYSTEMS
                      .index_with { { "status" => "ok" } }
      )

      Platform::Status::SweepService.run_once!(account)
      first = Platform::ComponentStatus.find_by(account_id: account.id,
                                                component_kind: "platform_subsystem",
                                                component_ref: "rails")
      first_transition = first.conditions.find { |c| c["type"] == "Healthy" }["last_transition_at"]

      Platform::Status::SweepService.run_once!(account, now: 2.minutes.from_now)
      second = first.reload.conditions.find { |c| c["type"] == "Healthy" }["last_transition_at"]

      expect(second).to eq(first_transition)
    end
  end
end
