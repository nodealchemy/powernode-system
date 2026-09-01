# frozen_string_literal: true

require "rails_helper"

# RCP v2 (campaign 019f9250, increment p0c) — fleet-wide scan for CURRENT
# INV-1/2/6 violations. Reuses the same predicate logic the provisioning-
# time gates use (System::Autonomy::{SelfManagementFence,
# BootPathInvariantCheck, StorageLocalityCheck}).
#
# Fixtures deliberately create a real System::ProviderConnection (not just
# a System::Provider) — the scanner resolves each instance's live adapter
# via Providers::Registry.for_instance (a pure DB read, no network call)
# and reads config off `adapter.connection`, exactly mirroring where
# ProxmoxProvider itself reads cidata_transport (connection-only, no
# provider fallback) and default_storage (connection, falling back to
# provider). A Provider with no matching "connected" ProviderConnection
# would make the adapter unresolvable and every check a no-op — see
# "when the instance's provider connection cannot be resolved" below.
RSpec.describe System::Compliance::RcpInvariantScanner do
  let(:account) { create(:account) }

  # `boot_mode:` declares it on the TEMPLATE; `instance_boot_mode:` stamps it
  # on the instance row itself, the way ProvisioningService does at spawn
  # (merge_config!, never update!(config:) — see spec/lint/
  # node_instance_config_write_seam_spec.rb). Passing both is what makes the
  # two disagree, which is the only fixture shape that can tell a per-instance
  # verdict apart from a per-template one.
  def instance_on(connection_config:, provider_config: {}, boot_mode: nil, instance_boot_mode: nil, status: "running")
    provider = create(:system_provider, account: account, provider_type: "proxmox", config: provider_config)
    create(:system_provider_connection, account: account, provider: provider, status: "connected", config: connection_config)
    region = create(:system_provider_region, account: account, provider: provider)
    template_config = boot_mode ? { "boot_mode" => boot_mode } : {}
    template = create(:system_node_template, account: account, config: template_config)
    node = create(:system_node, account: account, node_template: template)
    instance = create(:system_node_instance, node: node, provider_region: region,
                      provider_instance_type: create(:system_provider_instance_type, account: account), status: status)
    instance.merge_config!("boot_mode" => instance_boot_mode) if instance_boot_mode
    instance
  end

  describe "#scan (static, live: false)" do
    it "returns an empty, clean result for a fleet with no cloud instances" do
      result = described_class.scan(account: account)
      expect(result.clean?).to be true
      expect(result.live).to be false
    end

    describe "INV-1" do
      it "is empty when self_hosting_node_id is unconfigured (the default on every plane today)" do
        instance = instance_on(connection_config: {})
        result = described_class.scan(account: account)
        expect(result.inv1).to be_empty
        expect(instance).to be_present # keep the instance referenced/created
      end

      it "flags the running instance on the configured self-hosting node" do
        instance = instance_on(connection_config: {})
        SiteSetting.set("self_hosting_node_id", instance.node_id)

        result = described_class.scan(account: account)
        expect(result.inv1.size).to eq(1)
        expect(result.inv1.first).to include(invariant: "INV-1", node_id: instance.node_id, instance_id: instance.id)
      end
    end

    describe "INV-2" do
      it "does not flag the cloud_init boot_mode (not a pivot-boot mode)" do
        instance_on(connection_config: {}, boot_mode: "cloud_init")
        result = described_class.scan(account: account)
        expect(result.inv2).to be_empty
      end

      it "flags a uefi_disk instance whose connection has no cidata_transport iso opt-in" do
        instance = instance_on(connection_config: {}, boot_mode: "uefi_disk")
        result = described_class.scan(account: account)
        expect(result.inv2.size).to eq(1)
        expect(result.inv2.first).to include(invariant: "INV-2", node_id: instance.node_id)
      end

      it "does not flag a uefi_disk instance once the CONNECTION opts into the ISO transport" do
        instance_on(connection_config: { "cidata_transport" => "iso" }, boot_mode: "uefi_disk")
        result = described_class.scan(account: account)
        expect(result.inv2).to be_empty
      end

      # IMP-b2e745dbdbbb ORACLE. INV-2 is a per-INSTANCE verdict, but the
      # scanner resolved the boot mode from the node's TEMPLATE alone — so an
      # instance provisioned with an explicit options[:boot_mode] against a
      # template declaring a different one was scored for a boot mode it was
      # never provisioned with. Both directions are asserted deliberately: a
      # fixture whose instance and template AGREE is green against the defect
      # and proves nothing.
      it "flags an instance whose OWN recorded boot_mode is a pivot mode, on a cloud_init template" do
        instance = instance_on(connection_config: {}, boot_mode: "cloud_init", instance_boot_mode: "uefi_disk")
        result = described_class.scan(account: account)
        expect(result.inv2.size).to eq(1)
        expect(result.inv2.first).to include(invariant: "INV-2", node_id: instance.node_id, boot_mode: "uefi_disk")
      end

      # The other direction, and the mutant-killer for a "consult both, take
      # whichever is pivot" implementation: an instance spawned cloud_init on a
      # uefi_disk template did not pivot-boot and must not be flagged.
      it "does NOT flag an instance whose own recorded boot_mode is cloud_init, on a uefi_disk template" do
        instance_on(connection_config: {}, boot_mode: "uefi_disk", instance_boot_mode: "cloud_init")
        result = described_class.scan(account: account)
        expect(result.inv2).to be_empty
      end

      # The template lookup is the PERMANENT fallback, not a transitional one:
      # rows that never went through ProvisioningService (the bare-metal claim
      # seed, a direct POST to NodeInstancesController#create) never receive a
      # stamp at all, and must keep the template's answer.
      it "falls back to the template's boot_mode for an instance carrying no stamp" do
        instance = instance_on(connection_config: {}, boot_mode: "direct_kernel")
        expect(instance.reload.config).not_to have_key("boot_mode")

        result = described_class.scan(account: account)
        expect(result.inv2.size).to eq(1)
        expect(result.inv2.first).to include(invariant: "INV-2", boot_mode: "direct_kernel")
      end

      it "does NOT inherit cidata_transport from the parent Provider's config (connection-only, matches ProxmoxProvider#cidata_iso_transport?)" do
        instance_on(connection_config: {}, provider_config: { "cidata_transport" => "iso" }, boot_mode: "uefi_disk")
        result = described_class.scan(account: account)
        expect(result.inv2.size).to eq(1)
      end
    end

    describe "INV-6" do
      it "does not flag the known-local dna-data storage backend" do
        instance_on(connection_config: { "default_storage" => "dna-data" })
        result = described_class.scan(account: account)
        expect(result.inv6).to be_empty
      end

      it "flags an unverified (non-dna-data) default_storage backend as needing confirmation, not a confirmed violation" do
        instance = instance_on(connection_config: { "default_storage" => "some-other-storage" })
        result = described_class.scan(account: account)
        expect(result.inv6.size).to eq(1)
        finding = result.inv6.first
        expect(finding).to include(invariant: "INV-6", node_id: instance.node_id, verified: false)
      end

      it "reports nothing when neither the connection nor the provider has a default_storage configured" do
        instance_on(connection_config: {})
        result = described_class.scan(account: account)
        expect(result.inv6).to be_empty
      end

      it "falls back to the parent Provider's default_storage when the connection doesn't set one (mirrors pve_credential)" do
        instance_on(connection_config: {}, provider_config: { "default_storage" => "dna-data" })
        result = described_class.scan(account: account)
        expect(result.inv6).to be_empty
      end
    end

    it "skips instances whose provider connection cannot be resolved (no 'connected' ProviderConnection row)" do
      provider = create(:system_provider, account: account, provider_type: "proxmox", config: {})
      region = create(:system_provider_region, account: account, provider: provider)
      node = create(:system_node, account: account)
      create(:system_node_instance, node: node, provider_region: region,
             provider_instance_type: create(:system_provider_instance_type, account: account), status: "running")

      expect { described_class.scan(account: account) }.not_to raise_error
      result = described_class.scan(account: account)
      expect(result.inv2).to be_empty
      expect(result.inv6).to be_empty
    end
  end

  describe "#scan (live: true)" do
    it "upgrades an INV-6 finding to a confirmed violation when the live adapter reports NFS" do
      instance = instance_on(connection_config: { "default_storage" => "dsm-data" })
      allow_any_instance_of(System::Providers::ProxmoxProvider).to receive(:list_volume_types).and_return([
        { cloud_id: "dsm-data", name: "dsm-data", plugin_type: "nfs", shared: true }
      ])

      result = described_class.scan(account: account, live: true)
      expect(result.inv6.size).to eq(1)
      expect(result.inv6.first).to include(invariant: "INV-6", verified: true, instance_id: instance.id)
    end

    it "clears an INV-6 finding when the live adapter confirms the storage is local" do
      instance_on(connection_config: { "default_storage" => "some-other-storage" })
      allow_any_instance_of(System::Providers::ProxmoxProvider).to receive(:list_volume_types).and_return([
        { cloud_id: "some-other-storage", name: "some-other-storage", plugin_type: "zfspool", shared: false }
      ])

      result = described_class.scan(account: account, live: true)
      expect(result.inv6).to be_empty
    end
  end

  describe "#scan argument validation" do
    it "raises without an account" do
      expect { described_class.scan(account: nil) }.to raise_error(ArgumentError, /account required/)
    end
  end
end
