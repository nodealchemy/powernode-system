# frozen_string_literal: true

require "rails_helper"

# Covers the no-root NoCloud-ISO enrollment transport: an API-token PVE
# connection whose control plane can't mount the NFS snippets storage delivers
# the seed as an ISO uploaded via the storage API + attached as a CD-ROM. DEV's
# default cicustom/NFS path must stay the default + untouched.
RSpec.describe System::Providers::ProxmoxProvider do
  let(:region) { instance_double("System::ProviderRegion", region_code: "dna") }
  let(:client) { instance_double(System::Providers::Proxmox::Client) }

  def provider_with(config)
    conn = instance_double("System::ProviderConnection",
                           config: config, access_key: "user@pve!tok", secret_key: "s3cr3t")
    allow(System::Providers::Proxmox::Client).to receive(:new).and_return(client)
    described_class.new(conn, region: region)
  end

  let(:params) do
    { user_data: "ID=uuid\nKEY=tok\nSERVER=https://ops-hub.ipnode.us\nCA_PEM_FILE=/run/powernode/enroll-ca.pem\n",
      meta_data: "-----BEGIN CERTIFICATE-----\nMIItest\n-----END CERTIFICATE-----\n" }
  end

  describe "#cidata_iso_transport?" do
    it "is true only when the connection opts into iso transport" do
      expect(provider_with("cidata_transport" => "iso").send(:cidata_iso_transport?)).to be true
    end

    it "defaults to false so DEV's cicustom/NFS path stays the default" do
      expect(provider_with({}).send(:cidata_iso_transport?)).to be false
      expect(provider_with("cidata_transport" => "nfs").send(:cidata_iso_transport?)).to be false
    end
  end

  describe "#stage_cidata_iso" do
    subject(:provider) { provider_with("cidata_transport" => "iso") }

    it "builds a CIDATA ISO, uploads it (content=iso), attaches it as ide2 cdrom, and uses no cicustom" do
      captured = {}
      allow(client).to receive(:upload_file) do |node:, storage:, filename:, io:, content:|
        captured = { node:, storage:, filename:, content:, bytes: io.read.b }
        "UPID:upload"
      end
      allow(client).to receive(:wait_task)

      body = { "ide2" => "dna-data:cloudinit,media=cdrom" }
      provider.send(:stage_cidata_iso, client, body, params, vmid: 777, node: "dna", storage: "dna-data")

      expect(captured[:content]).to eq("iso")
      # Instance-keyed name (F1): "cidata-<vmid>-<discriminator>.iso" — a bare
      # vmid key was last-writer-wins on shared storage under a vmid race.
      expect(captured[:filename]).to match(/\Acidata-777-\h{12}\.iso\z/)
      expect(captured[:storage]).to eq("dna-data")
      expect(captured[:node]).to eq("dna")
      # the uploaded bytes are a real iso9660 carrying the CIDATA volume label
      expect(captured[:bytes].byteslice(16 * 2048 + 40, 32).strip).to eq("CIDATA".b)
      # attached as the CD-ROM (replacing the cloudinit drive); cicustom unused
      expect(body["ide2"]).to eq("dna-data:iso/#{captured[:filename]},media=cdrom")
      expect(body).not_to have_key("cicustom")
      expect(client).to have_received(:wait_task).with(node: "dna", upid: "UPID:upload")
    end

    it "honors a config-overridden iso storage" do
      prov = provider_with("cidata_transport" => "iso", "cidata_iso_storage" => "local")
      allow(client).to receive(:upload_file).and_return("UPID:x")
      allow(client).to receive(:wait_task)

      body = {}
      prov.send(:stage_cidata_iso, client, body, params, vmid: 5, node: "dna", storage: "dna-data")

      expect(body["ide2"]).to match(%r{\Alocal:iso/cidata-5-\h{12}\.iso,media=cdrom\z})
      expect(client).to have_received(:upload_file).with(hash_including(storage: "local", content: "iso"))
    end

    it "no-ops when there is no identity payload" do
      allow(client).to receive(:upload_file)
      body = {}
      provider.send(:stage_cidata_iso, client, body, {}, vmid: 1, node: "dna", storage: "dna-data")

      expect(body).not_to have_key("ide2")
      expect(client).not_to have_received(:upload_file)
    end
  end
end
