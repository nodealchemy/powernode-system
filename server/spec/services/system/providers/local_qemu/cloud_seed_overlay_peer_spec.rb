# frozen_string_literal: true

require "rails_helper"

# IMP-c6ba8920a51a — which peer's overlay identity gets baked into the seed.
#
# Resolving "this NodeInstance's SDWAN overlay attachment" happens at nine sites
# in this extension. Eight take the OLDEST peer — either `order(:created_at)` or
# an unordered `.first`, which ActiveRecord resolves to `ORDER BY id ASC` over
# UUIDv7 ids, i.e. also oldest-first — and all eight now route through
# Sdwan::OverlayAddressResolver. This one took the NEWEST
# (`order(created_at: :desc)`).
#
# Multi-homing is schema-permitted: system_sdwan_peers is UNIQUE on
# (sdwan_network_id, node_instance_id), not on node_instance_id alone, so an
# instance peered into two networks legally has two peers. On a single-homed
# host every site agrees, which is why this never surfaced.
#
# SEVERITY, established by reading the consumer rather than assuming one: the
# three sdwan_* fw-cfg keys this block writes are read by NOTHING. The agent
# reads exactly ten fw-cfg names (acceptance_token, bootstrap_token, ca_pem,
# contract_version, instance_name, instance_uuid, parent_peer_id, parent_url,
# platform_url, spawn_mode) and no sdwan_* key is among them; `sdwan_overlay_ip`
# has exactly one reference in the whole repository — the write below. So this
# is a latent inconsistency being closed before a consumer arrives, not a live
# mis-addressing, and nothing depended on the newest-peer choice.
RSpec.describe System::Providers::LocalQemu::CloudSeed, "overlay peer selection" do
  before { skip "sdwan not loaded" unless defined?(::Sdwan::Peer) }

  let(:account)  { create(:account) }
  let(:node)     { create(:system_node, account: account) }
  let(:instance) { create(:system_node_instance, node: node) }

  let(:net_a) { create(:sdwan_network, account: account) }
  let(:net_b) { create(:sdwan_network, account: account) }

  # Two peers, two networks, distinguishable addresses. created_at is set
  # explicitly so the ordering under test is the one being asserted, not an
  # accident of insertion speed.
  let!(:oldest) do
    create(:sdwan_peer, account: account, network: net_a, node_instance: instance,
                        assigned_address: "fd00:abcd:1::a", created_at: 2.days.ago)
  end
  let!(:newest) do
    create(:sdwan_peer, account: account, network: net_b, node_instance: instance,
                        assigned_address: "fd00:abcd:2::b", created_at: 1.hour.ago)
  end

  let(:seed_dir) { Dir.mktmpdir("cloud-seed-spec-") }

  around do |example|
    saved = ENV["POWERNODE_FWCFG_DIR"]
    ENV["POWERNODE_FWCFG_DIR"] = seed_dir
    example.run
  ensure
    ENV["POWERNODE_FWCFG_DIR"] = saved
    FileUtils.remove_entry(seed_dir) if Dir.exist?(seed_dir)
  end

  # #build returns a plain Hash — the CloudSeed::Result struct is declared but
  # unused by this path, so the entries come out under a key, not a reader.
  def entries
    described_class.build(instance: instance, options: { skip_fwcfg_stage: true })[:fw_cfg_entries]
  end

  it "bakes the OLDEST peer's overlay address, matching the other eight sites" do
    expect(entries["opt/com.powernode/sdwan_overlay_ip"]).to eq(oldest.assigned_address.to_s)
  end

  # The three keys must describe ONE peer. A resolver that returned only an
  # address would let the id and network drift to a different row — the seed
  # would name peer X on network Y with peer Z's address.
  it "keeps the peer id, network id and address on the same peer" do
    e = entries

    expect(e["opt/com.powernode/sdwan_peer_id"]).to eq(oldest.id)
    expect(e["opt/com.powernode/sdwan_network_id"]).to eq(oldest.sdwan_network_id)
    expect(e["opt/com.powernode/sdwan_overlay_ip"]).to eq(oldest.assigned_address.to_s)
  end

  # Agreement with the shared seam itself, rather than with a rule restated
  # here — if the oldest-peer rule ever changes, this moves with it.
  it "agrees with Sdwan::OverlayAddressResolver" do
    resolved = ::Sdwan::OverlayAddressResolver.addressed_peer_for(instance)

    expect(entries["opt/com.powernode/sdwan_peer_id"]).to eq(resolved.id)
  end

  it "omits the sdwan keys entirely when the instance has no peer" do
    ::Sdwan::Peer.where(node_instance_id: instance.id).destroy_all

    expect(entries).not_to have_key("opt/com.powernode/sdwan_peer_id")
  end
end
