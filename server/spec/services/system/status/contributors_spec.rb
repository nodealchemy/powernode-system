# frozen_string_literal: true

require "rails_helper"

# Campaign 01a08c9b increment B1 — the extension's one registration call, and
# the sweep it feeds.
RSpec.describe System::Status::Contributors do
  let(:account) { create(:account) }

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

    it "raises rather than shrugging when a contributor file cannot be resolved" do
      # No compat shim: a contributor that will not load is a deploy defect and
      # must not present as an empty, healthy-looking status plane.
      allow(Dir).to receive(:glob).with(described_class::CONTRIBUTOR_GLOB)
                                  .and_return([ "/nowhere/ghost_contributor.rb" ])

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
      expect(postgres.links.first["path"]).to eq("/app/system/compute/platform/health")
      expect(postgres.actions).to eq([])
      expect(postgres.conditions.map { |c| c["type"] }).to match_array(%w[Healthy Fresh])
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
