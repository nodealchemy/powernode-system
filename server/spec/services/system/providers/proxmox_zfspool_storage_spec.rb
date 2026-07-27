# frozen_string_literal: true

require "rails_helper"

# Covers provisioning onto BLOCK-BACKED storage (zfspool/LVM/RBD), which had
# never been exercised: every uefi_disk provision to date targeted NFS or dir
# storage, and those carry both the `import` content type and qcow2. A zfspool
# target carries neither, so two independent hardcodes failed it.
#
# The storage fixtures below are the REAL `pvesh get /nodes/rna/storage` shapes
# measured on rna 2026-07-26, not invented ones — `local-data` genuinely lists
# only `images,rootdir`, and `local` is the only node-local storage there that
# can stage an import.
RSpec.describe System::Providers::ProxmoxProvider do
  let(:region) { instance_double("System::ProviderRegion", region_code: "rna") }
  let(:client) { instance_double(System::Providers::Proxmox::Client) }

  subject(:provider) do
    conn = instance_double("System::ProviderConnection",
                           config: {}, access_key: "user@pve!tok", secret_key: "s3cr3t")
    allow(System::Providers::Proxmox::Client).to receive(:new).and_return(client)
    described_class.new(conn, region: region)
  end

  # As reported by PVE for node rna.
  let(:rna_storages) do
    [
      { "storage" => "local-data", "type" => "zfspool", "content" => "images,rootdir", "active" => 1, "shared" => 0 },
      { "storage" => "local",      "type" => "dir",
        "content" => "snippets,images,iso,import,rootdir,vztmpl", "active" => 1, "shared" => 0 },
      { "storage" => "dna-data",   "type" => "nfs",
        "content" => "import,rootdir,vztmpl,iso,images,snippets", "active" => 1, "shared" => 1 },
      { "storage" => "local-lvm",  "type" => "lvmthin", "content" => "rootdir,images", "active" => 1, "shared" => 0 }
    ]
  end

  before { allow(client).to receive(:get).with("/api2/json/nodes/rna/storage").and_return(rna_storages) }

  describe "#pve_disk_format_for" do
    it "is raw on block-backed storage, where a qcow2 file cannot exist" do
      expect(provider.send(:pve_disk_format_for, client, node: "rna", storage: "local-data")).to eq("raw")
      expect(provider.send(:pve_disk_format_for, client, node: "rna", storage: "local-lvm")).to eq("raw")
    end

    it "stays qcow2 on file-backed storage — PVE quirk #5, snapshots need all-qcow2" do
      expect(provider.send(:pve_disk_format_for, client, node: "rna", storage: "local")).to eq("qcow2")
      expect(provider.send(:pve_disk_format_for, client, node: "rna", storage: "dna-data")).to eq("qcow2")
    end

    it "falls back to qcow2 for unknown storage so a lookup miss cannot change existing behaviour" do
      expect(provider.send(:pve_disk_format_for, client, node: "rna", storage: "nope")).to eq("qcow2")
    end
  end

  describe "#resolve_import_storage!" do
    it "uses the boot storage when it can carry an import — the NFS/dir path is untouched" do
      got = provider.send(:resolve_import_storage!, client, node: "rna", storage: "dna-data")
      expect(got).to eq("dna-data")
    end

    it "picks an import-capable storage when the boot storage cannot carry one" do
      # THE regression case: local-data is zfspool, so "local-data:import/..."
      # is refused outright and the provision dies before the VM is created.
      got = provider.send(:resolve_import_storage!, client, node: "rna", storage: "local-data")
      expect(got).to eq("local")
    end

    it "prefers node-local staging over the shared NFS export" do
      # dna-data (shared) also carries `import` and would win a shared-first
      # search. It must not: a member rebuild is the recovery path for a lost
      # node, and routing it through the NFS export would re-couple provisioning
      # to the storage INV-6 moved these disks off in the first place.
      got = provider.send(:resolve_import_storage!, client, node: "rna", storage: "local-data")
      expect(got).to eq("local")
      expect(got).not_to eq("dna-data")
    end

    it "still falls back to shared storage rather than failing when nothing local can stage" do
      allow(client).to receive(:get).with("/api2/json/nodes/rna/storage")
                                    .and_return(rna_storages.reject { |s| s["storage"] == "local" })
      got = provider.send(:resolve_import_storage!, client, node: "rna", storage: "local-data")
      expect(got).to eq("dna-data")
    end

    it "honours an explicit override even when the boot storage could have carried it" do
      got = provider.send(:resolve_import_storage!, client, node: "rna", storage: "dna-data",
                                                    params: { import_storage: "local" })
      expect(got).to eq("local")
    end

    it "raises rather than guessing when nothing on the node can stage an import" do
      allow(client).to receive(:get).with("/api2/json/nodes/rna/storage")
                                    .and_return([rna_storages.first]) # zfspool only
      expect {
        provider.send(:resolve_import_storage!, client, node: "rna", storage: "local-data")
      }.to raise_error(System::Providers::BaseProvider::ProviderError, /content type import/)
    end
  end

  describe "#build_qemu_vm_body" do
    let(:preset) { { vcpus: 4, memory_mb: 16_384 } }

    def body_for(disk_format: nil)
      args = { preset: preset, vmid: 9100, storage: "local-data", bridge: "vmbr0",
               ip_config: "ip=dhcp", image_volid: "local:import/img.raw" }
      args[:disk_format] = disk_format if disk_format
      provider.send(:build_qemu_vm_body, { name: "ops-hub-b" }, **args)
    end

    it "emits raw efidisk0 when told the storage is block-backed" do
      expect(body_for(disk_format: "raw")["efidisk0"]).to eq("local-data:0,efitype=4m,format=raw")
    end

    it "defaults to qcow2 so an un-updated caller keeps the previous behaviour" do
      expect(body_for["efidisk0"]).to eq("local-data:0,efitype=4m,format=qcow2")
    end

    it "leaves scsi0's import-from untouched — it carries no format and never needed one" do
      expect(body_for(disk_format: "raw")["scsi0"]).to include("import-from=local:import/img.raw")
      expect(body_for(disk_format: "raw")["scsi0"]).not_to include("format=")
    end
  end

  describe "#resolve_uefi_disk_image!" do
    let(:platform) { instance_double("System::NodePlatform", disk_image_file_object_id: "obj-1") }
    let(:params) { { node: double(node_platform: platform) } }

    before do
      allow(provider).to receive(:uefi_disk_image_filename).and_return("ubuntu-24.04.raw")
      allow(provider).to receive(:pve_storage_volid_exists?).and_return(false)
    end

    it "stages into the import-capable storage, not the zfspool the disks land on" do
      expect(provider).to receive(:import_uefi_disk_image!)
        .with(client, node: "rna", storage: "local", platform: platform, filename: "ubuntu-24.04.raw")

      volid = provider.send(:resolve_uefi_disk_image!, client, params, node: "rna", storage: "local-data")
      expect(volid).to eq("local:import/ubuntu-24.04.raw")
    end

    it "short-circuits on an explicit image_id without touching storage at all" do
      expect(provider).not_to receive(:import_uefi_disk_image!)
      volid = provider.send(:resolve_uefi_disk_image!, client, params.merge(image_id: "local:import/x.raw"),
                            node: "rna", storage: "local-data")
      expect(volid).to eq("local:import/x.raw")
    end
  end
end
