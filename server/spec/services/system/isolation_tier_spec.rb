# frozen_string_literal: true

require "rails_helper"

# AI/MCP workload substrate L0 — isolation tier seam.
RSpec.describe System::IsolationTier do
  describe ".names / .valid?" do
    it "exposes the seven tiers" do
      expect(described_class.names).to contain_exactly(
        "native", "gvisor", "kata", "firecracker", "sev", "tdx", "vm"
      )
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
      # tier_strength is the capability if enforced; strength is the honest claim.
      expect(p["tier_strength"]).to eq("microvm")
    end

    it "maps the confidential tiers to TEE-enabled Kata runtimes" do
      expect(described_class.docker_runtime("sev")).to eq("kata-qemu-snp")
      expect(described_class.docker_runtime("tdx")).to eq("kata-qemu-tdx")
      expect(described_class.profile("sev")["tier_strength"]).to eq("confidential-vm")
    end

    # Audit 2026-06-09 F2-01: recording a tier is a REQUEST, not proof of
    # enforcement. Until a workload-level mechanism applies the runtime and
    # (for confidential tiers) attestation verifies it, the reported strength
    # must be degraded so nothing trusts unproven isolation.
    describe "honest enforcement reporting" do
      it "degrades unenforced non-native tiers to a 'requested, unverified' strength" do
        p = described_class.profile("sev")
        expect(p["enforced"]).to be(false)
        expect(p["strength"]).to eq("confidential-vm (requested, unverified)")
        expect(p["tier_strength"]).to eq("confidential-vm")
      end

      it "reports the full strength only when enforcement is confirmed" do
        p = described_class.profile("sev", enforced: true)
        expect(p["enforced"]).to be(true)
        expect(p["strength"]).to eq("confidential-vm")
      end

      it "never over-promises for the native tier (genuine process isolation)" do
        p = described_class.profile("native")
        expect(p["strength"]).to eq("process")
        expect(p["enforced"]).to be(false)
      end
    end
  end

  describe ".catalog" do
    it "lists every tier with mapping, requirements, and the default flag" do
      cat = described_class.catalog
      expect(cat.size).to eq(7)

      native = cat.find { |t| t["tier"] == "native" }
      expect(native["default"]).to be true
      expect(native["requires"]).to eq([])

      gvisor = cat.find { |t| t["tier"] == "gvisor" }
      expect(gvisor["requires"]).to include("runsc")
      expect(gvisor["default"]).to be false
    end
  end

  describe ".requires_runtime? / .required_runtimes_for" do
    it "is true for gvisor/kata/firecracker/sev/tdx, false for native/vm" do
      expect(described_class.requires_runtime?("gvisor")).to be true
      expect(described_class.requires_runtime?("kata")).to be true
      expect(described_class.requires_runtime?("firecracker")).to be true
      expect(described_class.requires_runtime?("sev")).to be true
      expect(described_class.requires_runtime?("tdx")).to be true
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
