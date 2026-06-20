# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Providers::Proxmox::CloudSeed do
  let(:spawn_payload) do
    {
      "parent_url"       => "https://ops.ipnode.us",
      "acceptance_token" => "test-token",
      "spawn_mode"       => "managed_child",
      "parent_peer_id"   => "abc12345-1234-1234-1234-abcdef012345",
      "contract_version" => "v1"
    }
  end

  let(:rendered) do
    described_class.render(
      spawn_payload: spawn_payload,
      hostname:      "ops2.ipnode.us",
      ssh_authorized_keys: [ "ssh-ed25519 AAAA test@dev" ]
    )
  end

  let(:payload) do
    # Strip the #cloud-config header line, parse the rest as YAML
    YAML.safe_load(rendered.sub(/\A#cloud-config\n/, ""), permitted_classes: [ Symbol ])
  end

  it "renders with a #cloud-config header on the first line (cloud-init requirement)" do
    expect(rendered).to start_with("#cloud-config\n")
  end

  it "installs wireguard-tools at first boot so the agent's WG applier has `wg` on PATH" do
    expect(payload["packages"]).to include("wireguard-tools")
    expect(payload["package_update"]).to be true
  end

  it "writes a netplan dropin that matches en*/eth* interfaces and sends the configured hostname in DHCPREQUEST" do
    netplan = payload["write_files"].find { |f| f["path"] == "/etc/netplan/99-powernode-dhcp.yaml" }
    expect(netplan).to be_present
    expect(netplan["content"]).to include("send-hostname: true")
    expect(netplan["content"]).to include("hostname: ops2.ipnode.us")
    # NIC name is image-dependent (eth0 on biosdevname-disabled images,
    # enp0s18/ens18 on Ubuntu cloud images) — match by glob so netplan
    # apply doesn't silently no-op when eth0 is absent.
    expect(netplan["content"]).to include("en*")
    expect(netplan["content"]).to include("eth*")
  end

  it "applies netplan + reloads networkd BEFORE downloading the agent (so DHCP renewal carries the right hostname)" do
    runcmd = payload["runcmd"]
    netplan_idx = runcmd.index { |c| c.to_s.include?("netplan apply") }
    reload_idx  = runcmd.index { |c| c.to_s.include?("networkctl reload") }
    agent_idx   = runcmd.index { |c| c.to_s.include?("powernode-agent") }
    expect(netplan_idx).not_to be_nil
    expect(reload_idx).not_to be_nil
    expect(agent_idx).not_to be_nil
    expect(netplan_idx).to be < agent_idx
    expect(reload_idx).to  be < agent_idx
  end

  it "writes the federation-payload.json fallback for fw-cfg-less PVE token-auth spawns" do
    fed = payload["write_files"].find { |f| f["path"] == "/etc/powernode/federation-payload.json" }
    expect(fed).to be_present
    expect(JSON.parse(fed["content"])).to include("parent_url" => "https://ops.ipnode.us")
  end

  it "writes the pnadmin sudoers grant for break-glass access from first boot" do
    sudoers = payload["write_files"].find { |f| f["path"] == "/etc/sudoers.d/91-pnadmin-cloudinit" }
    expect(sudoers).to be_present
    expect(sudoers["content"]).to include("pnadmin ALL=(ALL) NOPASSWD: ALL")
  end
end
