# frozen_string_literal: true

require "rails_helper"

# AI/MCP workload substrate L0 — isolation tier seam.
RSpec.describe System::IsolationTier do
  describe ".names / .valid?" do
    it "exposes the five tiers" do
      expect(described_class.names).to contain_exactly("native", "gvisor", "kata", "firecracker", "vm")
    end

    it "validates membership" do
      expect(described_class.valid?("gvisor")).to be true
      expect(described_class.valid?("nope")).to be false
    end
  end

  describe ".normalize" do
    it "defaults blank to native" do
      expect(described_class.normalize(nil)).to eq("native")
      expect(described_class.normalize("")).to eq("native")
    end

    it "raises on an unknown tier" do
      expect { described_class.normalize("nope") }.to raise_error(ArgumentError, /unknown isolation_tier/)
    end
  end

  describe ".docker_runtime / .k8s_runtime_class / .profile" do
    it "maps native -> runc (no k8s class)" do
      expect(described_class.docker_runtime("native")).to eq("runc")
      expect(described_class.k8s_runtime_class("native")).to be_nil
    end

    it "maps gvisor -> runsc + gvisor RuntimeClass" do
      expect(described_class.docker_runtime("gvisor")).to eq("runsc")
      expect(described_class.k8s_runtime_class("gvisor")).to eq("gvisor")
    end

    it "returns a string-keyed profile recording tier + runtime + strength" do
      p = described_class.profile("firecracker")
      expect(p["tier"]).to eq("firecracker")
      expect(p["docker_runtime"]).to eq("kata-fc")
      expect(p["strength"]).to eq("microvm")
    end
  end

  describe ".catalog" do
    it "lists every tier with mapping, requirements, and the default flag" do
      cat = described_class.catalog
      expect(cat.size).to eq(5)

      native = cat.find { |t| t["tier"] == "native" }
      expect(native["default"]).to be true
      expect(native["requires"]).to eq([])

      gvisor = cat.find { |t| t["tier"] == "gvisor" }
      expect(gvisor["requires"]).to include("runsc")
      expect(gvisor["default"]).to be false
    end
  end

  describe ".requires_runtime? / .required_runtimes_for" do
    it "is true for gvisor/kata/firecracker, false for native/vm" do
      expect(described_class.requires_runtime?("gvisor")).to be true
      expect(described_class.requires_runtime?("kata")).to be true
      expect(described_class.requires_runtime?("firecracker")).to be true
      expect(described_class.requires_runtime?("native")).to be false
      expect(described_class.requires_runtime?("vm")).to be false
    end

    it "derives the required runtimes from an instance's isolation config" do
      gvisor_inst = double(config: { "isolation" => { "tier" => "gvisor", "docker_runtime" => "runsc" } })
      expect(described_class.required_runtimes_for(gvisor_inst)).to eq(%w[gvisor])

      native_inst = double(config: { "isolation" => { "tier" => "native" } })
      expect(described_class.required_runtimes_for(native_inst)).to eq([])

      bare_inst = double(config: {})
      expect(described_class.required_runtimes_for(bare_inst)).to eq([])
    end
  end
end
