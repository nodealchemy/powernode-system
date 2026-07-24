# frozen_string_literal: true

require "rails_helper"

# RCP v2 (campaign 019f9250, increment p0c) — INV-2: no boot-time network
# dependency. Exercises the pure predicate against the SAME class-level
# predicate ProxmoxProvider itself uses (cidata_iso_transport_for?) so
# there is no drift between "what the provider does" and "what this check
# thinks the provider does".
RSpec.describe System::Autonomy::BootPathInvariantCheck do
  describe ".network_dependent_boot?" do
    it "is false for the cloud_init boot_mode (not a pivot-boot mode)" do
      expect(
        described_class.network_dependent_boot?(
          provider_type: "proxmox", boot_mode: "cloud_init", provider_config: {}, payload_present: true
        )
      ).to be false
    end

    it "is false for a non-proxmox provider" do
      expect(
        described_class.network_dependent_boot?(
          provider_type: "aws", boot_mode: "uefi_disk", provider_config: {}, payload_present: true
        )
      ).to be false
    end

    it "is false when there is no payload to deliver" do
      expect(
        described_class.network_dependent_boot?(
          provider_type: "proxmox", boot_mode: "uefi_disk", provider_config: {}, payload_present: false
        )
      ).to be false
    end

    it "is true for uefi_disk on proxmox with a payload and no cidata_transport opt-in (today's default connection shape)" do
      expect(
        described_class.network_dependent_boot?(
          provider_type: "proxmox", boot_mode: "uefi_disk", provider_config: {}, payload_present: true
        )
      ).to be true
    end

    it "is true for direct_kernel the same way" do
      expect(
        described_class.network_dependent_boot?(
          provider_type: "proxmox", boot_mode: "direct_kernel", provider_config: {}, payload_present: true
        )
      ).to be true
    end

    it "is false once the connection opts into the ISO transport" do
      expect(
        described_class.network_dependent_boot?(
          provider_type: "proxmox", boot_mode: "uefi_disk",
          provider_config: { "cidata_transport" => "iso" }, payload_present: true
        )
      ).to be false
    end

    it "delegates to ProxmoxProvider's own class method (no duplicated logic)" do
      expect(System::Providers::ProxmoxProvider).to receive(:cidata_iso_transport_for?).and_call_original
      described_class.network_dependent_boot?(
        provider_type: "proxmox", boot_mode: "uefi_disk", provider_config: {}, payload_present: true
      )
    end
  end

  describe ".violation_for" do
    let(:node) { create(:system_node, account: create(:account)) }

    it "returns nil when compliant" do
      expect(
        described_class.violation_for(
          provider_type: "proxmox", boot_mode: "cloud_init", provider_config: {}, payload_present: true, node: node
        )
      ).to be_nil
    end

    it "returns an INV-2 descriptor when violated" do
      violation = described_class.violation_for(
        provider_type: "proxmox", boot_mode: "uefi_disk", provider_config: {}, payload_present: true, node: node
      )
      expect(violation).to include(invariant: "INV-2", severity: :high, node_id: node.id)
      expect(violation[:detail]).to match(/NFS/)
    end
  end

  describe ".assert_local_boot!" do
    it "does not raise when strict: false, even when violated" do
      expect {
        described_class.assert_local_boot!(
          provider_type: "proxmox", boot_mode: "uefi_disk", provider_config: {}, payload_present: true, strict: false
        )
      }.not_to raise_error
    end

    it "does not raise when compliant, even when strict: true" do
      expect {
        described_class.assert_local_boot!(
          provider_type: "proxmox", boot_mode: "cloud_init", provider_config: {}, payload_present: true, strict: true
        )
      }.not_to raise_error
    end

    it "raises BootPathViolation when strict: true and violated" do
      expect {
        described_class.assert_local_boot!(
          provider_type: "proxmox", boot_mode: "uefi_disk", provider_config: {}, payload_present: true, strict: true
        )
      }.to raise_error(System::Autonomy::BootPathInvariantCheck::BootPathViolation, /uefi_disk/)
    end
  end
end
