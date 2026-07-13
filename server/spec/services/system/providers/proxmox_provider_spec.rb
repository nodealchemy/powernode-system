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

  describe "#apply_protection! (options override)" do
    let(:cfg_path) { "/api2/json/nodes/dna/qemu/100/config" }

    it "protects by default when no flag is given (durable VMs)" do
      expect(client).to receive(:put).with(cfg_path, { "protection" => 1 })
      provider.send(:apply_protection!, client, node: "dna", vmid: 100, params: {})
    end

    it "skips protection when opted out via nested options (the MCP path)" do
      expect(client).not_to receive(:put)
      provider.send(:apply_protection!, client, node: "dna", vmid: 100, params: { options: { protection: false } })
    end

    it "skips protection when opted out top-level" do
      expect(client).not_to receive(:put)
      provider.send(:apply_protection!, client, node: "dna", vmid: 100, params: { protection: false })
    end

    it "still protects when options explicitly request it" do
      expect(client).to receive(:put).with(cfg_path, { "protection" => 1 })
      provider.send(:apply_protection!, client, node: "dna", vmid: 100, params: { options: { protection: true } })
    end
  end

  describe "#create_instance (uefi_disk boot mode)" do
    # Increment 12a — UKI pivot-boot rehearsal. uefi_disk boots a VM from a
    # pre-built, signed UEFI/UKI disk image imported via the PVE storage API
    # (token-friendly), never the `args` escape hatch (root@pam-only).
    let(:base_params) do
      {
        name: "uefi-vm",
        instance_type: "pve.vm.small",
        boot_mode: "uefi_disk",
        node: "dna",
        storage: "dna-data",
        start: false
      }
    end

    before do
      allow(client).to receive(:get).with("/api2/json/cluster/nextid").and_return("200")
      allow(client).to receive(:post)
        .with("/api2/json/nodes/dna/qemu", anything)
        .and_return("UPID:dna:001:001:001:qmcreate:200:user!tok:")
      allow(client).to receive(:wait_task).and_return("status" => "stopped", "exitstatus" => "OK")
      allow(client).to receive(:put).and_return(nil)
    end

    context "with an explicit params[:image_id] (already-imported PVE volid)" do
      let(:params) { base_params.merge(image_id: "dna-data:import/uefi-uki.img") }

      it "skips disk import and creates the VM with bios=ovmf + the given volid" do
        result = provider.create_instance(params)
        expect(result[:success]).to be true

        expect(client).not_to have_received(:post).with(
          "/api2/json/nodes/dna/storage/dna-data/download-url", anything
        )
        expect(client).to have_received(:post).with(
          "/api2/json/nodes/dna/qemu",
          hash_including(
            "bios"  => "ovmf",
            "scsi0" => a_string_including("import-from=dna-data:import/uefi-uki.img")
          )
        )
      end

      it "never sets the `args` config key — no fw-cfg escape hatch, no root@pam requirement" do
        provider.create_instance(params)
        expect(client).to have_received(:post).with(
          "/api2/json/nodes/dna/qemu",
          hash_excluding("args")
        )
      end

      it "defaults vga to serial0 — no getty@tty1 recovery path exists for these minimal pivot-boot images, so diagnosis depends on capturing everything (including pre-kernel firmware output) via the serial0 socket" do
        provider.create_instance(params)
        expect(client).to have_received(:post).with(
          "/api2/json/nodes/dna/qemu",
          hash_including("vga" => "serial0", "serial0" => "socket")
        )
      end

      it "still honors an explicit params[:vga] override" do
        provider.create_instance(params.merge(vga: "std"))
        expect(client).to have_received(:post).with(
          "/api2/json/nodes/dna/qemu",
          hash_including("vga" => "std")
        )
      end
    end

    # PVE only materializes the cloud-init NoCloud (CIDATA) drive from cicustom
    # on a full power cycle — the first boot and a graceful reboot both come up
    # with an empty seed, so a cicustom-carrying uefi_disk VM's on-node agent
    # loops on identity-not-found until a stop+start. reload_cloudinit_seed!
    # is that power cycle.
    describe "#reload_cloudinit_seed! (cloud-init seed power cycle)" do
      it "issues a full stop+start (never a graceful reboot) so PVE reloads the CIDATA seed" do
        allow(client).to receive(:post).with("/api2/json/nodes/dna/qemu/200/status/stop").and_return("UPID:stop")
        allow(client).to receive(:post).with("/api2/json/nodes/dna/qemu/200/status/start").and_return("UPID:start")

        provider.send(:reload_cloudinit_seed!, client, node: "dna", kind: "qemu", vmid: 200)

        expect(client).to have_received(:post).with("/api2/json/nodes/dna/qemu/200/status/stop")
        expect(client).to have_received(:post).with("/api2/json/nodes/dna/qemu/200/status/start")
        expect(client).not_to have_received(:post).with(a_string_matching(%r{status/reboot}))
      end
    end

    context "when no explicit storage is given, prefers the operator-configured default_storage" do
      # The uefi_disk path imports the boot image into `storage` — that storage
      # must support `import` content, which an `images`-only auto-pick can miss.
      # Honoring the provider's default_storage avoids landing on the wrong pool.
      let(:proxmox_provider) { instance_double("System::Provider", config: { "default_storage" => "dna-data" }) }
      let(:connection) do
        instance_double("System::ProviderConnection",
          access_key: "root@pam!powernode",
          secret_key: "00000000-0000-0000-0000-000000000000",
          endpoint_url: "https://pve.example:8006",
          config: { "verify_ssl" => "false" },
          account: nil,
          provider: proxmox_provider)
      end
      let(:params) { base_params.except(:storage).merge(image_id: "dna-data:import/uefi-uki.raw") }

      before { allow(System::ProviderCredential).to receive(:for).and_return(nil) }

      it "creates the boot disk on default_storage and never auto-picks by content" do
        result = provider.create_instance(params)
        expect(result[:success]).to be true

        expect(client).not_to have_received(:get).with("/api2/json/nodes/dna/storage")
        expect(client).to have_received(:post).with(
          "/api2/json/nodes/dna/qemu",
          hash_including("scsi0" => a_string_including("dna-data:0,import-from=dna-data:import/uefi-uki.raw"))
        )
      end
    end

    context "when params[:node] isn't a PVE node string, places on the region node (not first-online)" do
      # region.region_code is "dna" (a 16-core node); first-online could be a
      # smaller node, which is where an 8-vcpu VM would fail to start.
      let(:params) { base_params.except(:node).merge(image_id: "dna-data:import/uefi-uki.raw") }

      before do
        allow(client).to receive(:get).with("/api2/json/nodes").and_return(
          [ { "node" => "lna", "status" => "online" }, { "node" => "dna", "status" => "online" } ]
        )
      end

      it "creates the VM on the region node (dna), not the first-online node (lna)" do
        provider.create_instance(params)
        expect(client).to have_received(:post).with("/api2/json/nodes/dna/qemu", anything)
        expect(client).not_to have_received(:post).with("/api2/json/nodes/lna/qemu", anything)
      end
    end

    context "resolving the default disk image from the node's NodePlatform" do
      let(:node_platform) do
        instance_double("System::NodePlatform",
          name: "ubuntu-24.04-amd64-uefi",
          disk_image_file_object_id: "0199aaaa-0000-7000-8000-000000000000",
          disk_image_sha256: "a" * 64,
          disk_image_git_sha: "af4e84d",
          account: instance_double("Account"))
      end
      let(:node_record) { instance_double("System::Node", node_platform: node_platform) }
      let(:params) { base_params.merge(node: node_record) }
      let(:file_object) { instance_double("FileManagement::Object") }
      let(:storage_service) { instance_double(FileStorageService) }
      let(:expected_filename) { "ubuntu-24.04-amd64-uefi-af4e84d.raw" }
      let(:expected_volid) { "dna-data:import/#{expected_filename}" }

      before do
        # params[:node] is the System::Node AR record here (not a string), so
        # pve_node_name filters it out and the cluster-picker fallback fires.
        allow(client).to receive(:get).with("/api2/json/nodes").and_return(
          [ { "node" => "dna", "status" => "online" } ]
        )
        allow(::FileManagement::Object).to receive(:find_by).with(id: node_platform.disk_image_file_object_id)
                                                            .and_return(file_object)
        allow(FileStorageService).to receive(:new).with(node_platform.account).and_return(storage_service)
        allow(storage_service).to receive(:file_url)
          .with(file_object, download: true, expires_in: 1.hour)
          .and_return("https://ops.example/files/uefi-uki-signed-download")
      end

      context "when the volid isn't already imported on the target storage" do
        before do
          allow(client).to receive(:get).with("/api2/json/nodes/dna/storage/dna-data/content").and_return([])
          allow(client).to receive(:post)
            .with("/api2/json/nodes/dna/storage/dna-data/download-url", anything)
            .and_return("UPID:dna:001:001:001:imgdl:200:user!tok:")
        end

        it "imports the disk image via the PVE storage download-url task, then creates the VM" do
          result = provider.create_instance(params)
          expect(result[:success]).to be true

          expect(client).to have_received(:post).with(
            "/api2/json/nodes/dna/storage/dna-data/download-url",
            hash_including(
              "content"  => "import",
              "filename" => expected_filename,
              "url"      => "https://ops.example/files/uefi-uki-signed-download",
              "checksum" => "a" * 64,
              "checksum-algorithm" => "sha256"
            )
          )
          expect(client).to have_received(:post).with(
            "/api2/json/nodes/dna/qemu",
            hash_including("scsi0" => a_string_including("import-from=#{expected_volid}"))
          )
        end
      end

      context "when the volid is already imported (idempotent re-provision)" do
        before do
          allow(client).to receive(:get).with("/api2/json/nodes/dna/storage/dna-data/content").and_return(
            [ { "volid" => expected_volid } ]
          )
        end

        it "skips the download-url import and reuses the existing volid" do
          provider.create_instance(params)
          expect(client).not_to have_received(:post).with(
            "/api2/json/nodes/dna/storage/dna-data/download-url", anything
          )
          expect(client).to have_received(:post).with(
            "/api2/json/nodes/dna/qemu",
            hash_including("scsi0" => a_string_including("import-from=#{expected_volid}"))
          )
        end
      end
    end

    context "when the platform's disk image lives in a storage backend that yields a non-fetchable URL (e.g. local storage)" do
      # LocalStorage#download_url returns a host-less relative path
      # (/api/v1/files/:id/download) that PVE's download-url task cannot GET.
      # In that case we stream the bytes straight into PVE's multipart upload
      # endpoint (content=import) — the same dev->PVE push direction the API
      # token already uses — instead of asking PVE to fetch an unfetchable URL.
      let(:node_platform) do
        instance_double("System::NodePlatform",
          name: "ubuntu-24.04-amd64-uefi",
          disk_image_file_object_id: "0199aaaa-0000-7000-8000-000000000000",
          disk_image_sha256: "b" * 64,
          disk_image_git_sha: "af4e84d",
          account: instance_double("Account"))
      end
      let(:node_record) { instance_double("System::Node", node_platform: node_platform) }
      let(:params) { base_params.merge(node: node_record) }
      let(:file_object) { instance_double("FileManagement::Object") }
      let(:storage_service) { instance_double(FileStorageService) }
      let(:expected_filename) { "ubuntu-24.04-amd64-uefi-af4e84d.raw" }
      let(:expected_volid) { "dna-data:import/#{expected_filename}" }

      before do
        allow(client).to receive(:get).with("/api2/json/nodes").and_return(
          [ { "node" => "dna", "status" => "online" } ]
        )
        allow(client).to receive(:get).with("/api2/json/nodes/dna/storage/dna-data/content").and_return([])
        allow(::FileManagement::Object).to receive(:find_by).with(id: node_platform.disk_image_file_object_id)
                                                            .and_return(file_object)
        allow(FileStorageService).to receive(:new).with(node_platform.account).and_return(storage_service)
        allow(storage_service).to receive(:file_url)
          .with(file_object, download: true, expires_in: 1.hour)
          .and_return("/api/v1/files/0199aaaa-0000-7000-8000-000000000000/download")
        allow(storage_service).to receive(:stream_file).with(file_object).and_yield("uki-bytes")
        allow(client).to receive(:upload_file)
          .and_return("UPID:dna:001:001:001:imgcopy:200:user!tok:")
      end

      it "streams the local bytes into PVE's multipart upload (content=import) instead of download-url, then creates the VM" do
        result = provider.create_instance(params)
        expect(result[:success]).to be true

        expect(client).not_to have_received(:post).with(
          "/api2/json/nodes/dna/storage/dna-data/download-url", anything
        )
        expect(client).to have_received(:upload_file).with(
          node: "dna",
          storage: "dna-data",
          filename: expected_filename,
          io: anything,
          content: "import",
          checksum: "b" * 64,
          checksum_algorithm: "sha256"
        )
        expect(client).to have_received(:post).with(
          "/api2/json/nodes/dna/qemu",
          hash_including("scsi0" => a_string_including("import-from=#{expected_volid}"))
        )
      end
    end

    context "with no image_id and no NodePlatform default image configured" do
      let(:node_platform) { instance_double("System::NodePlatform", disk_image_file_object_id: nil) }
      let(:node_record) { instance_double("System::Node", node_platform: node_platform) }
      let(:params) { base_params.merge(node: node_record) }

      before do
        # Node resolution (params[:node] is an AR-shaped double, not a
        # string) runs before image resolution — same ordering as the
        # cloud_init path's `params.fetch(:image_id)`.
        allow(client).to receive(:get).with("/api2/json/nodes").and_return(
          [ { "node" => "dna", "status" => "online" } ]
        )
      end

      it "raises a ProviderError with an actionable message" do
        expect { provider.create_instance(params) }.to raise_error(
          System::Providers::BaseProvider::ProviderError, /uefi_disk boot_mode requires a boot image/
        )
      end
    end
  end

  # Federation payload delivery differs by boot_mode. The UKI pivot-boot image
  # (uefi_disk) has NO cloud-init, so the cicustom user-data can't be a
  # #cloud-config — the initramfs powernode-cidata-payload.service copies it
  # VERBATIM to /etc/powernode/federation-payload.json. It must therefore be
  # the RAW spawn_payload JSON. The cloud_init path is unchanged (full
  # #cloud-config that cloud-init processes). (IMP-019f3831)
  describe "#create_instance federation payload render (boot_mode-specific)" do
    let(:acceptance_token) { "SINGLE-USE-FEDERATION-ACCEPTANCE-TOKEN-render" }
    let(:spawn_payload) do
      {
        "parent_url"       => "https://parent.powernode.internal",
        "acceptance_token" => acceptance_token,
        "spawn_mode"       => "managed_child",
        "parent_peer_id"   => "peerabcd1234",
        "contract_version" => "v1"
      }
    end
    # Captures every File.write so we can inspect the cicustom snippet content
    # without touching the real shared NFS snippets export.
    let(:written_files) { {} }

    before do
      allow(client).to receive(:wait_task).and_return("status" => "stopped", "exitstatus" => "OK")
      allow(client).to receive(:put).and_return(nil)
      allow(FileUtils).to receive(:mkdir_p)
      allow(File).to receive(:write) do |path, content, **_opts|
        written_files[path] = content
        content.to_s.bytesize
      end
    end

    def written_user_data
      key = written_files.keys.find { |k| k.end_with?("-user.yml") }
      key && written_files[key]
    end

    context "boot_mode: uefi_disk (UKI pivot-boot, no cloud-init)" do
      let(:params) do
        {
          name: "uefi-fed-vm",
          instance_type: "pve.vm.small",
          boot_mode: "uefi_disk",
          image_id: "dna-data:import/uefi-uki.raw",
          node: "dna",
          storage: "dna-data",
          start: false,
          options: { spawn_payload: spawn_payload }
        }
      end

      before do
        allow(client).to receive(:get).with("/api2/json/cluster/nextid").and_return("200")
        allow(client).to receive(:post)
          .with("/api2/json/nodes/dna/qemu", anything)
          .and_return("UPID:dna:001:001:001:qmcreate:200:user!tok:")
      end

      it "delivers the cicustom user-data as the RAW spawn_payload JSON (no #cloud-config wrapper)" do
        provider.create_instance(params)

        body = written_user_data
        expect(body).to be_present
        # Airtight bare-JSON assertion: a #cloud-config YAML document could not
        # parse back to exactly the payload hash.
        expect(JSON.parse(body)).to eq(spawn_payload)
        expect(body).not_to start_with("#cloud-config")
        # None of CloudSeed's cloud-init machinery leaks in.
        expect(body).not_to match(/packages|runcmd|write_files|pnadmin|netplan/)
      end

      it "byte-matches what CloudSeed embeds as the federation-payload.json fallback (agent file-fallback parity)" do
        provider.create_instance(params)
        # Same JSON the cloud_init path buries in its write_files entry, and
        # exactly what the agent's LoadConfig file fallback parses.
        expect(written_user_data).to eq(JSON.dump(spawn_payload))
      end

      it "still never sets the `args` config key (no fw-cfg escape hatch)" do
        provider.create_instance(params)
        expect(client).to have_received(:post).with(
          "/api2/json/nodes/dna/qemu", hash_excluding("args")
        )
      end
    end

    context "boot_mode: cloud_init (full cloud image — regression: unchanged)" do
      let(:params) do
        {
          name: "cloud-fed-vm",
          instance_type: "pve.vm.small",
          image_id: "dna-data:import/noble.qcow2",
          node: "dna",
          storage: "dna-data",
          start: false,
          options: { spawn_payload: spawn_payload }
        }
      end

      before do
        allow(client).to receive(:get).with("/api2/json/cluster/nextid").and_return("300")
        allow(client).to receive(:post)
          .with("/api2/json/nodes/dna/qemu", anything)
          .and_return("UPID:dna:001:001:001:qmcreate:300:user!tok:")
      end

      it "still renders the full #cloud-config, byte-identical to CloudSeed.render" do
        provider.create_instance(params)

        body = written_user_data
        expect(body).to be_present
        expect(body).to start_with("#cloud-config")
        expect(body).to eq(
          System::Providers::Proxmox::CloudSeed.render(
            spawn_payload: spawn_payload,
            hostname: "cloud-fed-vm"
          )
        )
      end
    end
  end

  describe "#create_instance boot_mode dispatch" do
    it "raises on an unknown boot_mode instead of silently defaulting" do
      params = {
        name: "bad-boot-mode-vm",
        instance_type: "pve.vm.small",
        image_id: "dna-data:import/noble.qcow2",
        node: "dna",
        storage: "dna-data",
        boot_mode: "not-a-real-mode"
      }

      expect { provider.create_instance(params) }.to raise_error(
        System::Providers::BaseProvider::ProviderError, /Unknown boot_mode/
      )
    end
  end

  # Security regression: the QEMU fw_cfg entries staged on the cluster-shared
  # NFS snippets export embed the single-use federation acceptance_token in
  # cleartext (fw_cfg["opt/com.powernode/acceptance_token"]). They MUST be
  # written 0o600 — world-readable 0o644 would expose the token to anything
  # that can read the shared export. (IMP-8671c221f23e)
  describe "fw-cfg staging perms (federation acceptance_token must not be world-readable)" do
    let(:acceptance_token) { "SINGLE-USE-FEDERATION-ACCEPTANCE-TOKEN-xyz" }
    let(:params) do
      {
        name: "fed-vm",
        instance_type: "pve.vm.small",
        image_id: "dna-data:import/noble.qcow2",
        node: "dna",
        storage: "dna-data",
        start: false,
        options: {
          spawn_payload: {
            "parent_url"       => "https://parent.powernode.internal",
            "acceptance_token" => acceptance_token,
            "spawn_mode"       => "managed_child",
            "parent_peer_id"   => "peerabcd1234",
            "contract_version" => "v1"
          }
        }
      }
    end

    around do |example|
      prev = ENV["POWERNODE_PVE_USE_FWCFG"]
      ENV["POWERNODE_PVE_USE_FWCFG"] = "1"
      example.run
    ensure
      if prev.nil?
        ENV.delete("POWERNODE_PVE_USE_FWCFG")
      else
        ENV["POWERNODE_PVE_USE_FWCFG"] = prev
      end
    end

    before do
      allow(client).to receive(:get).with("/api2/json/cluster/nextid").and_return("100")
      allow(client).to receive(:post)
        .with("/api2/json/nodes/dna/qemu", hash_including("vmid" => 100, "name" => "fed-vm"))
        .and_return("UPID:dna:001:001:001:qmcreate:100:user!tok:")
      allow(client).to receive(:wait_task).and_return("status" => "stopped", "exitstatus" => "OK")
      allow(client).to receive(:put).and_return(nil)

      # Do NOT touch the real shared snippets export — spy on the filesystem.
      allow(FileUtils).to receive(:mkdir_p)
      allow(File).to receive(:write)
    end

    it "writes the fw-cfg entry files with perm 0o600 (never world-readable 0o644)" do
      provider.create_instance(params)

      # The fw-cfg entry write (path under the "<vmid>-fwcfg/" subdir) must be 0o600.
      expect(File).to have_received(:write).with(
        a_string_including("-fwcfg/"),
        anything,
        mode: "w", perm: 0o600
      ).at_least(:once)

      # ...and never world-readable.
      expect(File).not_to have_received(:write).with(
        a_string_including("-fwcfg/"),
        anything,
        mode: "w", perm: 0o644
      )
    end

    it "never writes the cleartext acceptance_token to a world-readable (0o644) file" do
      provider.create_instance(params)

      expect(File).not_to have_received(:write).with(
        anything,
        a_string_including(acceptance_token),
        mode: "w", perm: 0o644
      )
    end
  end

  # Root cause A fix — pool-provisioned uefi_disk builders previously booted
  # with NO enrollment identity at all (create_uefi_disk_vm_instance never
  # staged fw-cfg). System::Providers::Proxmox::EnrollmentSeed now supplies
  # it, wired in behind the SAME POWERNODE_PVE_USE_FWCFG=1 opt-in the
  # cloud_init path already requires (PVE's `args` field is root@pam-only —
  # see the "never sets `args`" pinned specs above/below, which must keep
  # passing unchanged: this wiring must never regress API-token PVE users).
  describe "#create_instance (uefi_disk enrollment-identity fw-cfg wiring)" do
    let(:node_instance) { instance_double("System::NodeInstance", id: "0199aaaa-0000-7000-8000-000000000001") }
    let(:seed_entries) do
      {
        "opt/com.powernode/instance_uuid"   => node_instance.id,
        "opt/com.powernode/instance_name"   => "uefi-pool-vm",
        "opt/com.powernode/bootstrap_token" => "plaintext-token-abc",
        "opt/com.powernode/ca_pem"          => "-----BEGIN CERTIFICATE-----\nFAKE\n-----END CERTIFICATE-----",
        "opt/com.powernode/platform_url"    => "https://dev.ipnode.us"
      }
    end
    let(:params) do
      {
        name: "uefi-pool-vm",
        instance_type: "pve.vm.small",
        boot_mode: "uefi_disk",
        image_id: "dna-data:import/uefi-uki.raw",
        node: "dna",
        storage: "dna-data",
        start: false,
        instance: node_instance
      }
    end

    before do
      allow(client).to receive(:get).with("/api2/json/cluster/nextid").and_return("400")
      allow(client).to receive(:post)
        .with("/api2/json/nodes/dna/qemu", anything)
        .and_return("UPID:dna:001:001:001:qmcreate:400:user!tok:")
      allow(client).to receive(:wait_task).and_return("status" => "stopped", "exitstatus" => "OK")
      allow(client).to receive(:put).and_return(nil)
      allow(FileUtils).to receive(:mkdir_p)
      allow(File).to receive(:write)
    end

    around do |example|
      prev = ENV["POWERNODE_PVE_USE_FWCFG"]
      example.run
    ensure
      if prev.nil?
        ENV.delete("POWERNODE_PVE_USE_FWCFG")
      else
        ENV["POWERNODE_PVE_USE_FWCFG"] = prev
      end
    end

    context "when POWERNODE_PVE_USE_FWCFG=1 and EnrollmentSeed resolves identity" do
      before do
        ENV["POWERNODE_PVE_USE_FWCFG"] = "1"
        allow(System::Providers::Proxmox::EnrollmentSeed).to receive(:build)
          .with(instance: node_instance)
          .and_return(fw_cfg_entries: seed_entries, bootstrap_token_id: "tok-id-1")
      end

      it "stages the fw-cfg entries at perm 0o600 and appends -fw_cfg args to the VM create body" do
        provider.create_instance(params)

        expect(File).to have_received(:write).with(
          a_string_including("-fwcfg/"), "plaintext-token-abc", mode: "w", perm: 0o600
        )
        expect(client).to have_received(:post).with(
          "/api2/json/nodes/dna/qemu",
          hash_including("args" => a_string_including("-fw_cfg name=opt/com.powernode/platform_url"))
        )
      end
    end

    context "when POWERNODE_PVE_USE_FWCFG is unset (default) even though identity WOULD resolve" do
      before do
        allow(System::Providers::Proxmox::EnrollmentSeed).to receive(:build).and_return(
          fw_cfg_entries: seed_entries, bootstrap_token_id: "tok-id-1"
        )
      end

      it "never calls EnrollmentSeed and never sets `args` — no regression for root@pam-less (API-token) PVE connections" do
        provider.create_instance(params)

        expect(System::Providers::Proxmox::EnrollmentSeed).not_to have_received(:build)
        expect(client).to have_received(:post).with(
          "/api2/json/nodes/dna/qemu", hash_excluding("args")
        )
      end
    end

    context "when the flag is on but params[:instance] is absent (no NodeInstance threaded through)" do
      before { ENV["POWERNODE_PVE_USE_FWCFG"] = "1" }

      let(:params) do
        {
          name: "uefi-pool-vm",
          instance_type: "pve.vm.small",
          boot_mode: "uefi_disk",
          image_id: "dna-data:import/uefi-uki.raw",
          node: "dna",
          storage: "dna-data",
          start: false
        }
      end

      it "never calls EnrollmentSeed and never sets `args`" do
        expect(System::Providers::Proxmox::EnrollmentSeed).not_to receive(:build)

        provider.create_instance(params)

        expect(client).to have_received(:post).with(
          "/api2/json/nodes/dna/qemu", hash_excluding("args")
        )
      end
    end

    context "when the flag is on + instance present but EnrollmentSeed returns nil (identity not configured)" do
      before do
        ENV["POWERNODE_PVE_USE_FWCFG"] = "1"
        allow(System::Providers::Proxmox::EnrollmentSeed).to receive(:build)
          .with(instance: node_instance).and_return(nil)
      end

      it "never sets `args`" do
        provider.create_instance(params)

        expect(client).to have_received(:post).with(
          "/api2/json/nodes/dna/qemu", hash_excluding("args")
        )
      end
    end
  end

  # Option 3 — enrollment identity via the cicustom (NoCloud) channel, the
  # API-token-safe DEFAULT counterpart to the fw-cfg wiring tested above.
  # System::Providers::Proxmox::EnrollmentSeed#render_cicustom supplies the
  # identity; ProxmoxProvider threads it into params[:user_data] /
  # params[:meta_data] so the existing stage_cicustom helper writes it as a
  # normal 0600 snippet and sets `cicustom` — no `args`, no root@pam
  # requirement.
  describe "#create_instance (uefi_disk enrollment-identity cicustom wiring — Option 3)" do
    let(:node_instance) { instance_double("System::NodeInstance", id: "0199aaaa-0000-7000-8000-000000000002") }
    let(:enrollment_seed) { instance_double(System::Providers::Proxmox::EnrollmentSeed) }
    let(:cicustom_seed) do
      {
        user_data: "ID=#{node_instance.id}\nKEY=plaintext-cicustom-token\n" \
                   "SERVER=https://dev.ipnode.us\nCA_PEM_FILE=/run/powernode/enroll-ca.pem\n",
        meta_data: "-----BEGIN CERTIFICATE-----\nFAKE\n-----END CERTIFICATE-----"
      }
    end
    let(:params) do
      {
        name: "uefi-pool-vm-cicustom",
        instance_type: "pve.vm.small",
        boot_mode: "uefi_disk",
        image_id: "dna-data:import/uefi-uki.raw",
        node: "dna",
        storage: "dna-data",
        start: false,
        instance: node_instance
      }
    end
    let(:written_files) { {} }

    before do
      allow(client).to receive(:get).with("/api2/json/cluster/nextid").and_return("500")
      allow(client).to receive(:post)
        .with("/api2/json/nodes/dna/qemu", anything)
        .and_return("UPID:dna:001:001:001:qmcreate:500:user!tok:")
      allow(client).to receive(:wait_task).and_return("status" => "stopped", "exitstatus" => "OK")
      allow(client).to receive(:put).and_return(nil)
      allow(FileUtils).to receive(:mkdir_p)
      allow(File).to receive(:write) do |path, content, **_opts|
        written_files[path] = content
        content.to_s.bytesize
      end
      allow(System::Providers::Proxmox::EnrollmentSeed).to receive(:new).and_return(enrollment_seed)
      # The fw-cfg opt-in context below (POWERNODE_PVE_USE_FWCFG=1) exercises
      # the OTHER call path (.build, a class method wrapping .new.build) —
      # give the instance_double a harmless default so that context doesn't
      # also have to know about #build's contract.
      allow(enrollment_seed).to receive(:build).and_return(nil)
    end

    def written_user_data
      key = written_files.keys.find { |k| k.end_with?("-user.yml") }
      key && written_files[key]
    end

    def written_meta_data
      key = written_files.keys.find { |k| k.end_with?("-meta.yml") }
      key && written_files[key]
    end

    around do |example|
      prev = ENV["POWERNODE_PVE_USE_FWCFG"]
      example.run
    ensure
      if prev.nil?
        ENV.delete("POWERNODE_PVE_USE_FWCFG")
      else
        ENV["POWERNODE_PVE_USE_FWCFG"] = prev
      end
    end

    context "when POWERNODE_PVE_USE_FWCFG is unset (default) and EnrollmentSeed resolves identity" do
      before do
        allow(enrollment_seed).to receive(:render_cicustom).with(instance: node_instance).and_return(cicustom_seed)
      end

      it "stages the identity.cfg user_data + CA meta_data as cicustom snippets and sets `cicustom`, never `args`" do
        provider.create_instance(params)

        expect(written_user_data).to eq(cicustom_seed[:user_data])
        expect(written_meta_data).to eq(cicustom_seed[:meta_data])
        expect(client).to have_received(:post).with(
          "/api2/json/nodes/dna/qemu",
          hash_including("cicustom" => a_string_including("user=").and(a_string_including("meta=")))
        )
        expect(client).to have_received(:post).with(
          "/api2/json/nodes/dna/qemu", hash_excluding("args")
        )
      end
    end

    context "when params[:user_data] is already present (federation payload owns the snippet slot)" do
      let(:params) do
        super().merge(user_data: JSON.dump("parent_url" => "https://parent.powernode.internal"))
      end

      it "never calls EnrollmentSeed#render_cicustom (mutual exclusion with federation)" do
        expect(enrollment_seed).not_to receive(:render_cicustom)
        provider.create_instance(params)
      end
    end

    context "when POWERNODE_PVE_USE_FWCFG=1 (operator opted into the fw-cfg transport instead)" do
      before { ENV["POWERNODE_PVE_USE_FWCFG"] = "1" }

      it "never calls EnrollmentSeed#render_cicustom" do
        expect(enrollment_seed).not_to receive(:render_cicustom)
        provider.create_instance(params)
      end
    end

    context "when params[:instance] is absent" do
      let(:params) { super().except(:instance) }

      it "never calls EnrollmentSeed#render_cicustom" do
        expect(enrollment_seed).not_to receive(:render_cicustom)
        provider.create_instance(params)
      end
    end

    context "when EnrollmentSeed#render_cicustom returns nil (identity not configured)" do
      before do
        allow(enrollment_seed).to receive(:render_cicustom).with(instance: node_instance).and_return(nil)
      end

      it "never sets `cicustom` and never raises" do
        expect { provider.create_instance(params) }.not_to raise_error
        expect(client).to have_received(:post).with(
          "/api2/json/nodes/dna/qemu", hash_excluding("cicustom")
        )
      end
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
