# frozen_string_literal: true

require "rails_helper"
require_relative "shared_examples"

RSpec.describe System::Providers::ProxmoxProvider do
  # Parent Provider record — pve_credential consults `connection.provider.config`
  # as a fallback so operators can set endpoint/verify_ssl/default_* on the
  # Provider via the ProviderFormModal and have every ProviderConnection
  # inherit them. Tests stub this with an empty config so the fallback is a
  # no-op unless a specific test exercises inheritance.
  let(:proxmox_provider) { instance_double("System::Provider", config: {}) }
  let(:connection) do
    instance_double("System::ProviderConnection",
      access_key: "root@pam!powernode",
      secret_key: "00000000-0000-0000-0000-000000000000",
      endpoint_url: "https://pve.example:8006",
      config: { "verify_ssl" => "false" },
      provider: proxmox_provider
    )
  end
  let(:region) { instance_double("System::ProviderRegion", region_code: "dna") }
  let(:client) { instance_double(System::Providers::Proxmox::Client) }

  subject(:provider) { described_class.new(connection, region: region) }

  before do
    allow(System::Providers::Proxmox::Client).to receive(:new).and_return(client)
  end

  # The shared_examples expects the standard BaseProvider interface;
  # ProxmoxProvider conforms.
  it_behaves_like "a cloud provider"

  describe "#provider_type" do
    it "returns 'proxmox'" do
      expect(provider.provider_type).to eq("proxmox")
    end
  end

  describe "#authenticate?" do
    context "when credentials authenticate and the token has ACL grants" do
      before do
        allow(client).to receive(:get).with("/api2/json/version").and_return("version" => "9.1.5", "release" => "9.1")
        allow(client).to receive(:has_any_grants?).and_return(true)
      end

      it "returns true" do
        expect(provider.authenticate?).to be true
      end
    end

    context "when the token authenticates but has NO ACL grants (silent-empty trap)" do
      before do
        allow(client).to receive(:get).with("/api2/json/version").and_return("version" => "9.1.5")
        allow(client).to receive(:has_any_grants?).and_return(false)
      end

      it "returns false and sets a clear error explaining the privilege-separation gotcha" do
        expect(provider.authenticate?).to be false
        expect(provider.last_authentication_error).to include("ACL grants").and include("Privilege Separation")
      end
    end

    context "when the token is invalid" do
      before do
        allow(client).to receive(:get)
          .with("/api2/json/version")
          .and_raise(System::Providers::Proxmox::Client::AuthError, "401")
      end

      it "returns false and records the auth error" do
        expect(provider.authenticate?).to be false
        expect(provider.last_authentication_error).to include("PVE auth failed")
      end
    end

    context "when credentials are missing entirely" do
      let(:connection) do
        instance_double("System::ProviderConnection",
          access_key: nil, secret_key: nil, endpoint_url: nil, config: {},
          # account is reached by BaseProvider#pve_credential's BYOC fallback
          # (System::ProviderCredential.for(account:, provider:)) before
          # raising missing-credentials; nil is the correct unconfigured state.
          account: nil,
          provider: proxmox_provider)
      end

      it "returns false without making any API calls" do
        expect(System::Providers::Proxmox::Client).not_to receive(:new)
        expect(provider.authenticate?).to be false
        expect(provider.last_authentication_error).to include("Missing Proxmox credentials")
      end
    end
  end

  describe "#test_connection" do
    it "returns a structured success payload with cluster info" do
      allow(client).to receive(:get).with("/api2/json/version").and_return(
        "version" => "9.1.5", "release" => "9.1"
      )
      allow(client).to receive(:get).with("/api2/json/nodes").and_return(
        [ { "node" => "dna", "status" => "online" }, { "node" => "rna", "status" => "online" } ]
      )

      result = provider.test_connection
      expect(result[:success]).to be true
      expect(result[:pve_version]).to eq("9.1.5")
      expect(result[:node_count]).to eq(2)
      expect(result[:nodes].map { |n| n[:name] }).to contain_exactly("dna", "rna")
    end

    it "returns a failure payload on transport errors" do
      allow(client).to receive(:get)
        .and_raise(System::Providers::Proxmox::Client::Error, "connection refused")

      result = provider.test_connection
      expect(result[:success]).to be false
      expect(result[:error]).to include("connection refused")
    end
  end

  describe "#create_instance (VM mode)" do
    let(:params) do
      {
        name: "test-vm",
        instance_type: "pve.vm.small",
        image_id: "dna-data:import/noble.qcow2",
        node: "dna",
        storage: "dna-data",
        ssh_keys: [ "ssh-ed25519 AAAA test@example" ],
        # start: false keeps the spec scoped to the create+config flow.
        # The auto-start default is covered separately by #start_instance
        # specs below; here we only assert the create-time POST shape.
        start: false
      }
    end

    before do
      # PVE returns nextid as a string; the adapter converts to Integer before posting.
      allow(client).to receive(:get).with("/api2/json/cluster/nextid").and_return("100")
      allow(client).to receive(:post)
        .with("/api2/json/nodes/dna/qemu", hash_including("vmid" => 100, "name" => "test-vm"))
        .and_return("UPID:dna:001:001:001:qmcreate:100:user!tok:")
      allow(client).to receive(:wait_task).and_return("status" => "stopped", "exitstatus" => "OK")
      allow(client).to receive(:put)
        .with("/api2/json/nodes/dna/qemu/100/resize", hash_including("disk" => "scsi0", "size" => "20G"))
        .and_return(nil)
      allow(client).to receive(:put)
        .with("/api2/json/nodes/dna/qemu/100/config", hash_including("sshkeys"))
        .and_return(nil)
      allow(client).to receive(:put)
        .with("/api2/json/nodes/dna/qemu/100/config", hash_including("protection" => 1))
        .and_return(nil)
    end

    it "returns a successful instance response with the composite cloud_id" do
      result = provider.create_instance(params)
      expect(result[:success]).to be true
      expect(result[:cloud_instance_id]).to eq("dna/qemu/100")
    end

    it "sends import-from with size=0 in the scsi0 spec (PVE quirk)" do
      provider.create_instance(params)
      expect(client).to have_received(:post).with(
        "/api2/json/nodes/dna/qemu",
        hash_including(
          "scsi0" => match(/dna-data:0,import-from=dna-data:import\/noble\.qcow2/)
        )
      )
    end

    it "creates the efidisk as qcow2 (PVE quirk: required for snapshots)" do
      provider.create_instance(params)
      expect(client).to have_received(:post).with(
        "/api2/json/nodes/dna/qemu",
        hash_including("efidisk0" => a_string_including("format=qcow2"))
      )
    end

    it "URL-encodes the sshkeys when setting them via config PUT" do
      provider.create_instance(params)
      expect(client).to have_received(:put).with(
        "/api2/json/nodes/dna/qemu/100/config",
        hash_including("sshkeys" => match(/ssh-ed25519[%+]/))
      )
    end

    it "auto-starts the VM by default (Federation::SpawnProvisioner relies on this)" do
      # Mock the start POST that the auto-start path will fire (no body).
      allow(client).to receive(:post)
        .with("/api2/json/nodes/dna/qemu/100/status/start")
        .and_return("UPID:dna:001:001:001:qmstart:100:user!tok:")
      # And the status GET that start_instance does to build the response.
      allow(client).to receive(:get)
        .with("/api2/json/nodes/dna/qemu/100/status/current")
        .and_return({ "status" => "running", "name" => "test-vm" })

      result = provider.create_instance(params.except(:start))
      expect(result[:success]).to be true
      expect(client).to have_received(:post).with(
        "/api2/json/nodes/dna/qemu/100/status/start"
      )
    end
  end

  describe "#create_instance (LXC mode)" do
    let(:params) do
      {
        name: "test-lxc",
        instance_type: "pve.lxc.small",
        image_id: "dna-data:vztmpl/ubuntu-24.04-standard.tar.zst",
        node: "dna",
        storage: "dna-data",
        ssh_keys: [ "ssh-ed25519 AAAA test@example" ],
        # See VM-mode let(:params) — scope the spec to the create flow.
        start: false
      }
    end

    before do
      allow(client).to receive(:get).with("/api2/json/cluster/nextid").and_return("101")
      allow(client).to receive(:post)
        .with("/api2/json/nodes/dna/lxc", hash_including("vmid" => 101, "hostname" => "test-lxc"))
        .and_return("UPID:dna:001:001:001:vzcreate:101:user!tok:")
      allow(client).to receive(:wait_task).and_return("status" => "stopped", "exitstatus" => "OK")
      allow(client).to receive(:put).and_return(nil)
    end

    it "uses /lxc endpoint with hostname, ostemplate, rootfs, and net0 in LXC format" do
      provider.create_instance(params)
      expect(client).to have_received(:post).with(
        "/api2/json/nodes/dna/lxc",
        hash_including(
          "hostname"   => "test-lxc",
          "ostemplate" => "dna-data:vztmpl/ubuntu-24.04-standard.tar.zst",
          "rootfs"     => a_string_including("dna-data:"),
          "net0"       => a_string_including("name=eth0,bridge=vmbr0,ip=dhcp")
        )
      )
    end

    it "sends ssh-public-keys (hyphenated) URL-encoded" do
      provider.create_instance(params)
      expect(client).to have_received(:post).with(
        "/api2/json/nodes/dna/lxc",
        hash_including("ssh-public-keys" => match(/ssh-ed25519[%+]/))
      )
    end
  end

  describe "#start_instance" do
    it "POSTs to the qemu status/start endpoint, waits for the task, and returns the current status" do
      allow(client).to receive(:post).with("/api2/json/nodes/dna/qemu/100/status/start")
                                       .and_return("UPID:dna:start")
      allow(client).to receive(:wait_task)
      allow(client).to receive(:get).with("/api2/json/nodes/dna/qemu/100/status/current")
                                       .and_return("status" => "running", "agent" => 0, "uptime" => 5)

      result = provider.start_instance("dna/qemu/100")
      expect(result[:success]).to be true
      expect(result[:status]).to eq("running")
    end
  end

  describe "#terminate_instance" do
    it "issues stop best-effort, then DELETEs with purge + destroy-unreferenced-disks" do
      allow(client).to receive(:post).and_return("UPID:dna:stop")
      allow(client).to receive(:wait_task)
      allow(client).to receive(:delete).with(
        "/api2/json/nodes/dna/qemu/100",
        hash_including("purge" => 1, "destroy-unreferenced-disks" => 1)
      ).and_return("UPID:dna:destroy")

      result = provider.terminate_instance("dna/qemu/100")
      expect(result[:success]).to be true
      expect(result[:status]).to eq("terminated")
    end

    it "treats an already-gone instance as success" do
      allow(client).to receive(:post).and_return("UPID:dna:stop")
      allow(client).to receive(:wait_task)
      allow(client).to receive(:delete).and_raise(System::Providers::Proxmox::Client::NotFoundError, "404")

      result = provider.terminate_instance("dna/qemu/999")
      expect(result[:success]).to be true
      expect(result[:status]).to eq("terminated")
    end
  end

  describe "#list_instances" do
    it "queries cluster/resources and synthesizes composite cloud_instance_ids" do
      allow(client).to receive(:get).with("/api2/json/cluster/resources", {}).and_return([
        { "type" => "qemu", "vmid" => 100, "node" => "dna", "name" => "ops", "status" => "running",
          "maxcpu" => 4, "maxmem" => 8_589_934_592 },
        { "type" => "lxc", "vmid" => 200, "node" => "rna", "name" => "test", "status" => "stopped",
          "maxcpu" => 2, "maxmem" => 2_147_483_648 },
        { "type" => "storage", "storage" => "dna-data" } # should be filtered out
      ])

      result = provider.list_instances
      ids = result[:instances].map { |i| i[:cloud_instance_id] }
      expect(ids).to contain_exactly("dna/qemu/100", "rna/lxc/200")
    end
  end

  describe "#list_regions" do
    it "treats PVE nodes as regions" do
      allow(client).to receive(:get).with("/api2/json/nodes").and_return([
        { "node" => "dna", "status" => "online", "maxcpu" => 16, "maxmem" => 270_000_000_000 },
        { "node" => "rna", "status" => "online", "maxcpu" => 20, "maxmem" => 270_000_000_000 }
      ])

      result = provider.list_regions
      expect(result.map { |r| r[:cloud_id] }).to contain_exactly("dna", "rna")
    end
  end

  describe "#list_instance_types" do
    it "returns the synthesized preset table with VM + LXC modes" do
      result = provider.list_instance_types
      codes = result.map { |t| t[:cloud_id] }
      expect(codes).to include("pve.vm.small", "pve.vm.medium", "pve.lxc.small", "pve.lxc.medium")

      vm_medium = result.find { |t| t[:cloud_id] == "pve.vm.medium" }
      expect(vm_medium[:vcpus]).to eq(4)
      expect(vm_medium[:memory_mb]).to eq(8_192)
      expect(vm_medium[:metadata]).to eq("mode" => "vm")
    end
  end

  describe "#list_volume_types" do
    it "returns the visible storage pools on the target node" do
      allow(client).to receive(:get).with("/api2/json/nodes/dna/storage").and_return([
        { "storage" => "dna-data", "plugintype" => "nfs", "shared" => 1, "content" => "images,rootdir",
          "total" => 4_000_000_000_000, "avail" => 3_500_000_000_000 },
        { "storage" => "local-lvm", "plugintype" => "lvmthin", "shared" => 0, "content" => "rootdir,images",
          "total" => 200_000_000_000, "avail" => 200_000_000_000 }
      ])

      result = provider.list_volume_types("dna")
      shared_dna_data = result.find { |v| v[:cloud_id] == "dna-data" }
      expect(shared_dna_data[:shared]).to be true
      expect(shared_dna_data[:plugin_type]).to eq("nfs")
      expect(shared_dna_data[:content_types]).to include("images")
    end
  end

  describe "instance_id parsing" do
    it "rejects malformed instance_ids early with ResourceNotFoundError" do
      expect { provider.start_instance("not-a-valid-id") }
        .to raise_error(System::Providers::BaseProvider::ResourceNotFoundError)
    end

    it "rejects unknown kinds (only qemu + lxc are valid)" do
      expect { provider.start_instance("dna/container/100") }
        .to raise_error(System::Providers::BaseProvider::ResourceNotFoundError)
    end
  end
end
