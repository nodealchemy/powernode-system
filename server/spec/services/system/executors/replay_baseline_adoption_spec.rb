# frozen_string_literal: true

require "rails_helper"

# IMP-391525770512 — adoption hygiene for the replay-baseline guard.
#
# The guard is deliberately OPT-IN: verify_replay_baseline! no-ops when the
# parked operation carries no stamp, which is what keeps already-parked
# operations and non-fingerprinting executors working. The cost of that choice
# is that a NEW gating surface which forgets to stamp fails open in silence —
# the executor cannot tell "this request touched nothing declared" from "this
# surface never adopted the stamp", and nothing at runtime complains.
#
# VIP update already has two surfaces (REST + MCP) parking one executor, so
# this is not hypothetical: guarding one and missing the other would leave a
# silent-revert path reachable by a different noun. This spec is the standing
# check that both ends stay wired, and it is what a third surface will trip.
#
# Scope: source-level, and only over this extension's own app tree. It cannot
# see a surface in another extension, and it does not prove the stamp reads
# PERSISTED state — that is pinned behaviourally per surface.
RSpec.describe "replay-baseline stamp adoption" do
  # <extension>/server/app
  APP_ROOT = Pathname.new(File.expand_path("../../../../app", __dir__))

  before(:all) { Rails.application.eager_load! }

  def ruby_sources
    @ruby_sources ||= Dir.glob(APP_ROOT.join("**", "*.rb")).sort
  end

  it "has an app tree to scan" do
    # Guards the whole spec against a path change quietly turning every
    # assertion below into a vacuous pass over zero files.
    expect(ruby_sources.size).to be > 100, "the source scan found nothing — APP_ROOT is wrong, not the code clean"
  end

  it "declares at least one fingerprinting executor" do
    expect(fingerprinting_executors).not_to be_empty,
                                            "nothing declares replay_baseline_attributes — the adoption check below cannot fail"
  end

  it "stamps a baseline at every surface that parks a fingerprinting executor" do
    offenders = fingerprinting_executors.flat_map do |klass|
      ruby_sources.filter_map do |path|
        source = File.read(path)
        next unless source.include?(%(executor_class: "#{klass.name}"))
        next if source.include?("#{klass.name}.replay_baseline(")

        "#{path.delete_prefix(APP_ROOT.to_s)} parks #{klass.name} " \
          "(declares #{klass.replay_baseline_attributes.join(', ')}) without stamping replay_baseline"
      end
    end

    expect(offenders).to be_empty, <<~MSG
      A gating surface parks an executor that fingerprints attributes, but never
      stamps the request-time baseline — so the replay guard silently cannot fire
      there. Add `replay_baseline: <Executor>.replay_baseline(record, attrs)` to
      the parked params, reading the record in its PERSISTED state.

      #{offenders.join("\n")}
    MSG
  end

  def fingerprinting_executors
    @fingerprinting_executors ||= ::System::Executors::Base.descendants.select do |klass|
      klass.replay_baseline_attributes.any?
    end
  end
end
