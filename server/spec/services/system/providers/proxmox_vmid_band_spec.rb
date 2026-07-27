# frozen_string_literal: true

require "rails_helper"

# VMID band allocation on a SHARED PVE cluster. Two Powernode control planes
# (dev and ops-hub) drive the same `ipnode` cluster, so each needs its own band —
# `cluster/nextid` has no per-tenant notion and would hand one plane an id the
# other already owns.
#
# A floor alone was never a reservation: the search walked upward without limit,
# so any band "reserved" above a floored connection is reached the moment that
# connection's own range fills. These cover the ceiling that makes a reservation
# real, and pin the unfenced behaviour so existing connections are untouched.
RSpec.describe System::Providers::ProxmoxProvider do
  let(:region) { instance_double("System::ProviderRegion", region_code: "dna") }
  let(:client) { instance_double(System::Providers::Proxmox::Client) }

  def provider_with(config)
    conn = instance_double("System::ProviderConnection",
                           config: config, access_key: "user@pve!tok", secret_key: "s3cr3t")
    allow(System::Providers::Proxmox::Client).to receive(:new).and_return(client)
    described_class.new(conn, region: region)
  end

  def stub_cluster(nextid:, used: [])
    allow(client).to receive(:get).with("/api2/json/cluster/nextid").and_return(nextid.to_s)
    allow(client).to receive(:get).with("/api2/json/cluster/resources", { "type" => "vm" })
                                  .and_return(used.map { |v| { "vmid" => v } })
  end

  describe "unfenced connection (no band configured)" do
    it "returns PVE's nextid unchanged" do
      stub_cluster(nextid: 102)
      expect(provider_with({}).send(:allocate_next_vmid!, client)).to eq(102)
    end
  end

  describe "floor only (today's live ipnode-pve-conn: vmid_min 500, no max)" do
    it "floors a below-band nextid into the band" do
      stub_cluster(nextid: 102, used: [ 500, 502, 503, 504 ])
      expect(provider_with("vmid_min" => 500).send(:allocate_next_vmid!, client)).to eq(501)
    end

    it "takes nextid as-is when it is already at or above the floor" do
      stub_cluster(nextid: 505)
      expect(provider_with("vmid_min" => 500).send(:allocate_next_vmid!, client)).to eq(505)
    end

    # THE reason vmid_max exists. With 500-599 full, a floor-only connection
    # walks straight into 600 — the band the control-plane pair now occupies.
    # This is not hypothetical drift; it is what the allocator is written to do.
    it "walks past a conventionally-reserved band once its own range fills" do
      full = (500..599).to_a
      stub_cluster(nextid: 102, used: full)
      expect(provider_with("vmid_min" => 500).send(:allocate_next_vmid!, client)).to eq(600)
    end
  end

  describe "fenced connection (vmid_min + vmid_max)" do
    it "allocates inside the band" do
      stub_cluster(nextid: 102, used: [ 500, 501 ])
      got = provider_with("vmid_min" => 500, "vmid_max" => 599).send(:allocate_next_vmid!, client)
      expect(got).to eq(502)
    end

    it "refuses to leave the band when it is exhausted, rather than spilling upward" do
      full = (500..599).to_a
      stub_cluster(nextid: 102, used: full)
      provider = provider_with("vmid_min" => 500, "vmid_max" => 599)
      expect { provider.send(:allocate_next_vmid!, client) }
        .to raise_error(System::Providers::BaseProvider::ProviderError, /band 500-599 is exhausted/)
    end

    it "never hands out an id in the control-plane band even under exhaustion" do
      full = (500..599).to_a
      stub_cluster(nextid: 102, used: full)
      provider = provider_with("vmid_min" => 500, "vmid_max" => 599)
      begin
        got = provider.send(:allocate_next_vmid!, client)
      rescue System::Providers::BaseProvider::ProviderError
        got = nil
      end
      expect(got).to be_nil, "allocator produced #{got.inspect}, which may land on ops-hub-A (600) or -B (601)"
    end

    it "ignores a nextid above the ceiling and allocates within the band" do
      stub_cluster(nextid: 9500, used: [ 500 ])
      got = provider_with("vmid_min" => 500, "vmid_max" => 599).send(:allocate_next_vmid!, client)
      expect(got).to eq(501)
    end

    it "accepts a nextid that already falls inside the band" do
      stub_cluster(nextid: 550)
      got = provider_with("vmid_min" => 500, "vmid_max" => 599).send(:allocate_next_vmid!, client)
      expect(got).to eq(550)
    end

    it "rejects an inverted band rather than allocating from a nonsense range" do
      stub_cluster(nextid: 102)
      provider = provider_with("vmid_min" => 600, "vmid_max" => 500)
      expect { provider.send(:allocate_next_vmid!, client) }
        .to raise_error(System::Providers::BaseProvider::ProviderError, /below vmid_min/)
    end
  end

  describe "the ops-hub plane's band (vmid_min 9000)" do
    it "cannot reach the control-plane band, since it only ever walks upward from its floor" do
      stub_cluster(nextid: 102, used: [ 9000, 9001, 9002, 9003, 9004 ])
      got = provider_with("vmid_min" => 9000, "vmid_max" => 9099).send(:allocate_next_vmid!, client)
      expect(got).to eq(9005)
      expect(got).to be > 609
    end
  end
end
