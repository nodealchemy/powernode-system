# frozen_string_literal: true

require "rails_helper"

# F1 from dryrun run 20260809a (IMP 019fe4c4-b373): two provisioning steps ran
# concurrently in one process, both allocated vmid 9002 from /cluster/nextid
# (which reserves nothing), and three defects compounded:
#
#   1. The rna step's cidata seed — named `cidata-9002.iso` on SHARED storage —
#      OVERWROTE the dna step's seed. VM 9002 booted holding the rna
#      instance's enrollment identity (identity cross-contamination).
#   2. The rna qemu create then failed HTTP 500 ("VM 9002 already exists") and
#      was never retried; the run lost its rna placement.
#   3. VM 9002's heartbeats — authenticated as the rna instance — self-healed
#      the rna row from :error to :running via mark_running, manufacturing a
#      "running" instance with NO cloud_instance_id that live PVE has never
#      seen (the phantom).
#
# Fixes under test: instance-unique seed names (both transports), a
# process-local vmid reservation ledger, a bounded re-allocate-and-retry on
# vmid-conflict create failures, and an AASM guard so a cloud/dynamic instance
# without provider identity can never be marked running by a heartbeat.
RSpec.describe System::Providers::ProxmoxProvider, "provisioning races" do
  let(:proxmox_provider_record) { instance_double("System::Provider", config: {}) }
  let(:connection) do
    instance_double("System::ProviderConnection",
                    access_key: "root@pam!powernode",
                    secret_key: "00000000-0000-0000-0000-000000000000",
                    endpoint_url: "https://pve.example:8006",
                    config: { "cidata_transport" => "iso", "verify_ssl" => "false" },
                    provider: proxmox_provider_record)
  end
  let(:region) { instance_double("System::ProviderRegion", region_code: "dna") }
  let(:client) { instance_double(System::Providers::Proxmox::Client) }

  subject(:provider) { described_class.new(connection, region: region) }

  before do
    allow(System::Providers::Proxmox::Client).to receive(:new).and_return(client)
    allow(client).to receive(:get).with(%r{\A/api2/json/nodes/[^/]+/storage\z}).and_return(
      [ { "storage" => "dna-data", "type" => "nfs", "active" => 1, "shared" => 1,
          "content" => "import,rootdir,vztmpl,iso,images,snippets" } ]
    )
    described_class.reset_vmid_reservations!
  end

  let(:seed_params) do
    { user_data: "ID=uuid\nKEY=tok\n", meta_data: "meta" }
  end

  def fake_instance(id)
    instance_double("System::NodeInstance", id: id)
  end

  describe "seed naming is instance-unique (no last-writer-wins on shared storage)" do
    before do
      allow(client).to receive(:upload_file).and_return("UPID:upload")
      allow(client).to receive(:wait_task)
    end

    it "keys the cidata ISO on the instance identity, not just the vmid" do
      names = %w[019fe4b5-2d80-71f4-b8c9-45d4162e21b3 019fe4b5-2e5e-772b-a75e-5899465eb615].map do |uuid|
        captured = nil
        allow(client).to receive(:upload_file) do |filename:, **|
          captured = filename
          "UPID:upload"
        end
        body = {}
        provider.send(:stage_cidata_iso, client, body,
                      seed_params.merge(instance: fake_instance(uuid)),
                      vmid: 9002, node: "dna", storage: "dna-data")
        expect(body["ide2"]).to include(captured)
        captured
      end
      expect(names.uniq.size).to eq(2), "two instances at the same vmid produced colliding seed names: #{names.inspect}"
    end

    it "never emits the bare vmid-keyed name even without an instance record" do
      captured = nil
      allow(client).to receive(:upload_file) do |filename:, **|
        captured = filename
        "UPID:upload"
      end
      provider.send(:stage_cidata_iso, client, {}, seed_params, vmid: 9002, node: "dna", storage: "dna-data")
      expect(captured).not_to eq("cidata-9002.iso")
    end

    it "keys cicustom snippets on the instance identity too (shared NFS export)" do
      written = []
      allow(File).to receive(:directory?).and_return(true)
      allow(File).to receive(:writable?).and_return(true)
      allow(File).to receive(:write) { |path, *_| written << path; 1 }

      %w[aaaa1111-0000-7000-8000-000000000001 bbbb2222-0000-7000-8000-000000000002].each do |uuid|
        provider.send(:stage_cicustom, {}, seed_params.merge(instance: fake_instance(uuid)), vmid: 9002)
      end
      user_snippets = written.select { |p| p.end_with?("-user.yml") }
      expect(user_snippets.uniq.size).to eq(2),
                                         "two instances at the same vmid wrote the same snippet path: #{user_snippets.inspect}"
    end
  end

  describe "#allocate_next_vmid! process-local reservation" do
    it "never hands the same vmid to two consecutive allocations in one process" do
      allow(client).to receive(:get).with("/api2/json/cluster/nextid").and_return("9002")
      first  = provider.send(:allocate_next_vmid!, client)
      second = provider.send(:allocate_next_vmid!, client)
      expect(first).to eq(9002)
      expect(second).not_to eq(first)
    end

    it "reservations are shared across adapter instances (the run used one per step)" do
      allow(client).to receive(:get).with("/api2/json/cluster/nextid").and_return("9002")
      other = described_class.new(connection, region: region)
      first  = provider.send(:allocate_next_vmid!, client)
      second = other.send(:allocate_next_vmid!, client)
      expect(second).not_to eq(first)
    end
  end

  describe "create retries on a vmid-conflict 500" do
    let(:params) do
      {
        name: "uefi-vm",
        instance_type: "pve.vm.small",
        boot_mode: "uefi_disk",
        image_id: "dna-data:import/uefi-uki.img",
        node: "dna",
        storage: "dna-data",
        start: false
      }
    end

    before do
      allow(client).to receive(:get).with("/api2/json/cluster/nextid").and_return("9002")
      allow(client).to receive(:wait_task).and_return("status" => "stopped", "exitstatus" => "OK")
      allow(client).to receive(:put).and_return(nil)
    end

    it "re-allocates a fresh vmid and succeeds when PVE says the vmid already exists" do
      attempts = []
      allow(client).to receive(:post).with("/api2/json/nodes/dna/qemu", anything) do |_url, body|
        attempts << body["vmid"]
        raise System::Providers::Proxmox::Client::Error, "unable to create VM 9002 - VM 9002 already exists on node 'dna'" if attempts.size == 1

        "UPID:dna:001:001:001:qmcreate:#{body['vmid']}:user!tok:"
      end

      result = provider.create_instance(params)

      expect(result[:success]).to be true
      expect(attempts.size).to eq(2)
      expect(attempts.last).not_to eq(attempts.first)
    end

    it "does not retry a non-conflict PVE error" do
      calls = 0
      allow(client).to receive(:post).with("/api2/json/nodes/dna/qemu", anything) do
        calls += 1
        raise System::Providers::Proxmox::Client::Error, "storage 'dna-data' does not support vm images"
      end

      result = provider.create_instance(params)
      expect(result[:success]).to be false
      expect(calls).to eq(1)
    end

    it "gives up after bounded retries instead of looping" do
      calls = 0
      allow(client).to receive(:post).with("/api2/json/nodes/dna/qemu", anything) do
        calls += 1
        raise System::Providers::Proxmox::Client::Error, "unable to create VM - already exists"
      end

      result = provider.create_instance(params)
      expect(result[:success]).to be false
      expect(calls).to be <= 3
    end
  end
end

RSpec.describe System::NodeInstance, "heartbeat self-heal guard" do
  let(:account) { create(:account) }
  let(:node) { create(:system_node, account: account) }

  def build_instance(variety:, cloud_instance_id:, status:)
    described_class.create!(
      name: "guard-spec-#{SecureRandom.hex(4)}",
      node: node,
      variety: variety,
      status: status,
      cloud_instance_id: cloud_instance_id
    )
  end

  it "refuses to mark a cloud instance running when it has no provider identity" do
    # The phantom's exact shape: provisioning failed (:error), no
    # cloud_instance_id — a heartbeat from a seed-contaminated VM must not
    # manufacture a running instance PVE has never seen.
    phantom = build_instance(variety: "cloud", cloud_instance_id: nil, status: "error")
    expect(phantom.may_mark_running?).to be false
  end

  it "still self-heals an errored cloud instance that HAS provider identity" do
    real = build_instance(variety: "cloud", cloud_instance_id: "dna/qemu/9002", status: "error")
    expect(real.may_mark_running?).to be true
    real.mark_running!
    expect(real.status).to eq("running")
  end

  it "leaves physical instances self-healable — no cloud id exists for them (IMP-42cf03360656)" do
    physical = build_instance(variety: "physical", cloud_instance_id: nil, status: "error")
    expect(physical.may_mark_running?).to be true
  end
end
