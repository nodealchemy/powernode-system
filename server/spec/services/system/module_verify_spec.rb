# frozen_string_literal: true

require "rails_helper"

# IMP-3855ff9908f2 — the declaration half of the `verify:` probe primitive.
#
# The two claims this file pins hardest are the two the settled design
# (readiness map §2) names, because each one is a way for the feature to LOOK
# implemented while being incapable of catching the incident it exists for:
#
#   1. A probe with no `resolves_to` is an EXISTENCE check, and an existence
#      check is exactly what passed while the VM-9000 binary was shadowed.
#      It is not a weaker probe; it is the bug. Never parsed, never imported.
#   2. `shells` is not a manifest field at all. The login/non-login divergence
#      IS the bug class, so "which shells" cannot be a per-module choice.
RSpec.describe System::ModuleVerify do
  def mod_with(config)
    instance_double("System::NodeModule", config: config)
  end

  def probe_block(*probes)
    { "verify" => { "probes" => probes } }
  end

  let(:good) { { "name" => "gh-binary", "command" => "gh", "resolves_to" => "/usr/local/bin/gh" } }

  describe ".probes" do
    it "parses a well-formed declaration" do
      probes = described_class.probes(mod_with(probe_block(good)))
      expect(probes.size).to eq(1)
      expect(probes.first.name).to eq("gh-binary")
      expect(probes.first.command).to eq("gh")
      expect(probes.first.resolves_to).to eq("/usr/local/bin/gh")
    end

    it "returns [] for a module that declares nothing" do
      expect(described_class.probes(mod_with({}))).to eq([])
      expect(described_class.probes(mod_with(nil))).to eq([])
      expect(described_class.probes(nil)).to eq([])
    end

    # THE load-bearing drop.
    it "DROPS a probe with no resolves_to rather than running an existence check" do
      probes = described_class.probes(mod_with(probe_block(good.except("resolves_to"))))
      expect(probes).to be_empty
    end

    it "DROPS a probe whose resolves_to is not absolute" do
      expect(described_class.probes(mod_with(probe_block(good.merge("resolves_to" => "bin/gh"))))).to be_empty
    end

    it "DROPS a probe whose resolves_to is non-canonical" do
      expect(described_class.probes(mod_with(probe_block(
        good.merge("resolves_to" => "/usr/local/../bin/gh")
      )))).to be_empty
    end

    # A command naming a path resolves that path; it never exercises the PATH
    # lookup, so it is structurally incapable of seeing a shadow.
    it "DROPS a probe whose command is a path rather than a bare name" do
      expect(described_class.probes(mod_with(probe_block(
        good.merge("command" => "/usr/local/bin/gh")
      )))).to be_empty
    end

    it "DROPS a probe whose command carries shell metacharacters" do
      %w[gh;id gh|id gh$(id) gh\ id].each do |cmd|
        expect(described_class.probes(mod_with(probe_block(good.merge("command" => cmd)))))
          .to be_empty, "expected #{cmd.inspect} to be rejected"
      end
    end

    it "collapses duplicate probe names, keeping the first" do
      probes = described_class.probes(mod_with(probe_block(
        good, good.merge("resolves_to" => "/usr/bin/gh")
      )))
      expect(probes.map(&:resolves_to)).to eq([ "/usr/local/bin/gh" ])
    end

    it "caps the probe count" do
      many = Array.new(described_class::MAX_PROBES + 5) do |i|
        good.merge("name" => "probe-#{i}")
      end
      expect(described_class.probes(mod_with(probe_block(*many))).size)
        .to eq(described_class::MAX_PROBES)
    end
  end

  describe ".declared?" do
    it "is true only when at least one probe survives parsing" do
      expect(described_class.declared?(mod_with(probe_block(good)))).to be(true)
      expect(described_class.declared?(mod_with(probe_block(good.except("resolves_to"))))).to be(false)
      expect(described_class.declared?(mod_with({}))).to be(false)
    end
  end

  describe "the both-shells rule" do
    # There is no manifest key for this, and there must not be one: a module
    # that could opt into a single shell would reproduce the VM-9000 bug
    # rather than catch it.
    it "declares both shells as a constant, not a manifest field" do
      expect(described_class::REQUIRED_SHELLS).to contain_exactly("login", "non_login")
      expect(described_class::PROBE_KNOWN_KEYS).not_to include("shells")
    end
  end
end
