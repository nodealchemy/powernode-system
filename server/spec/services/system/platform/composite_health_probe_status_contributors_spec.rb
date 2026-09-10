# frozen_string_literal: true

require "rails_helper"

# B1 review fix 2 — a swallowed status-contributor registration failure was
# invisible.
#
# The engine's to_prepare rescues, deliberately: an unguarded raise there turns
# a promote skew into a boot crash-loop on the very host that would have to fix
# it, and this deployment has hit that. But the rescue's consequence — an EMPTY
# status plane — was surfaced nowhere. The registry has one consumer, nothing
# compares its kinds against an expected set, and the sweep returns normally
# with a shorter summary and zero errors. That is indistinguishable from a fleet
# with no system components.
#
# This makes the silence a red tile.
RSpec.describe System::Platform::CompositeHealthProbe, "status_contributors subsystem" do
  let(:account) { create(:account) }
  let(:probe)   { described_class.new(account: account, source: "spec") }

  after { System::Status::Contributors.reset_last_result! }

  def entry
    probe.send(:measure, :status_contributors)
  end

  it "is one of the subsystems every payload carries" do
    expect(described_class::SUBSYSTEMS).to include(:status_contributors)
  end

  describe "when registration succeeded" do
    it "is ok and names the kinds that reached the registry" do
      System::Status::Contributors.register_all!

      result = entry

      expect(result[:status]).to eq(described_class::OK)
      expect(result[:registered_kinds]).to include("platform_subsystem")
      expect(result[:registered_kind_count]).to eq(System::Status::Contributors.kinds.size)
    end
  end

  describe "when registration failed" do
    # The failure the rescue produces, reproduced through the real call rather
    # than by writing last_result by hand.
    def fail_registration!(error)
      allow(System::Status::Contributors).to receive(:contributor_classes).and_raise(error)
      System::Status::Contributors.register_all!
    rescue StandardError
      nil
    end

    it "is down with reason RegistrationFailed and carries the error class" do
      fail_registration!(RuntimeError.new("contributor blew up"))

      result = entry

      expect(result[:status]).to eq(described_class::DOWN)
      expect(result[:reason]).to eq("RegistrationFailed")
      expect(result[:error]).to include("contributor blew up")
      expect(result[:error_class]).to eq("RuntimeError")
      expect(result[:deploy_defect]).to be(false)
    end

    it "distinguishes a promote skew as a deploy defect, not a runtime condition" do
      # A new extension against a core without increment A1. An operator rolls
      # that back; they do not retry it.
      fail_registration!(NameError.new("uninitialized constant Platform::Status::Registry"))

      result = entry

      expect(result[:status]).to eq(described_class::DOWN)
      expect(result[:reason]).to eq("RegistrationFailed (deploy defect)")
      expect(result[:deploy_defect]).to be(true)
    end

    it "drags the whole composite off ok, so an operator sees it" do
      fail_registration!(RuntimeError.new("contributor blew up"))
      allow(probe).to receive(:measure).and_call_original
      (described_class::SUBSYSTEMS - [ :status_contributors ]).each do |name|
        allow(probe).to receive(:"probe_#{name}").and_return({ status: described_class::OK })
      end

      result = probe.call

      expect(result[:overall]).to eq(described_class::DOWN)
      expect(result[:down]).to eq([ :status_contributors ])
    end
  end

  describe "when registration has not run in this process" do
    it "is not_measured, which is neither of the other two answers" do
      System::Status::Contributors.reset_last_result!

      result = entry

      expect(result[:status]).to eq(described_class::NOT_MEASURED)
      expect(result[:reason]).to match(/has not run/)
    end
  end

  describe "the status plane renders it" do
    it "turns a failed registration into a down platform_subsystem row" do
      allow(System::Status::Contributors).to receive(:contributor_classes)
        .and_raise(RuntimeError.new("contributor blew up"))
      begin
        System::Status::Contributors.register_all!
      rescue StandardError
        nil
      end

      System::PlatformHealthSnapshot.create!(
        account: account, overall: "down", captured_at: Time.current, source: "spec",
        subsystems: { "status_contributors" => probe.send(:measure, :status_contributors)
                                                    .transform_keys(&:to_s) }
      )

      contributor = System::Status::Contributors::PlatformSubsystemContributor.new
      record = nil
      contributor.each_component(account) { |r| record = r if r.key == "status_contributors" }
      conditions = contributor.conditions_for(record)

      expect(Platform::Status::Condition.verdict_for_set(conditions))
        .to eq(Platform::ComponentStatus::DOWN)
      expect(conditions.find { |c| c["type"] == "Healthy" }["message"])
        .to include("contributor blew up")
    end
  end
end
