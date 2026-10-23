# frozen_string_literal: true

require "rails_helper"

# IMP-b7683fab758c: orphaned cidata-<vmid>-<key>.iso reaper. The adapter is a
# double; no Proxmox is ever called. Dry run by default; selects by (vmid, key)
# against live instances; never touches a live instance's current ISO.
RSpec.describe System::Providers::Proxmox::SeedIsoReaper do
  let(:connection) { create(:system_provider_connection) }
  let(:adapter) { double("proxmox adapter") }
  let(:now) { Time.zone.parse("2026-10-23 12:00:00 UTC") }
  let(:old) { (now - 3.days).to_i }
  let(:apply) { false }

  def disc(record) = record.id.delete("-").first(12)

  def live_instance(vmid, status: "running")
    rec = create(:system_node_instance, status: status)
    rec.merge_config!("cloud_instance_id" => "pve1/qemu/#{vmid}")
    rec
  end

  def entry(name, ctime: old, node: "pve1")
    { node: node, filename: name, ctime: ctime }
  end

  def reap(**opts)
    described_class.new(provider: adapter, connection: connection, apply: apply, now: now, **opts).call
  end

  let(:live) { live_instance(9000) }
  let(:live_iso) { "cidata-9000-#{disc(live)}.iso" }
  let(:old_key_iso) { "cidata-9000-aaaaaaaaaaaa.iso" }       # reused vmid, older key
  let(:orphan_iso) { "cidata-9002-bbbbbbbbbbbb.iso" }         # vmid of nobody live

  before do
    live
    allow(adapter).to receive(:list_cidata_isos).and_return([ entry(live_iso), entry(old_key_iso), entry(orphan_iso) ])
    allow(adapter).to receive(:delete_cidata_iso_file)
  end

  it "dry run changes nothing and reports the orphans" do
    result = reap

    expect(adapter).not_to have_received(:delete_cidata_iso_file)
    expect(AuditLog.where(action: "system.enrollment_seed.cleanup")).to be_empty
    expect(result.orphans.map { |e| e[:filename] }).to contain_exactly(old_key_iso, orphan_iso)
    expect(result.deleted).to be_empty
  end

  it "treats a reused vmid's older-key file as an orphan but never the live instance's current ISO" do
    names = reap.orphans.map { |e| e[:filename] }
    expect(names).to include(old_key_iso)
    expect(names).not_to include(live_iso)
  end

  context "with APPLY" do
    let(:apply) { true }

    it "deletes only the selected files, one at a time, each audited" do
      result = reap

      expect(adapter).to have_received(:delete_cidata_iso_file).with(node: "pve1", filename: old_key_iso).once
      expect(adapter).to have_received(:delete_cidata_iso_file).with(node: "pve1", filename: orphan_iso).once
      expect(adapter).not_to have_received(:delete_cidata_iso_file).with(hash_including(filename: live_iso))
      expect(result.deleted.size).to eq(2)
      audits = AuditLog.where(action: "system.enrollment_seed.cleanup", resource_id: connection.id)
      expect(audits.count).to eq(2)
      expect(audits.map { |a| a.metadata.to_s }.join).not_to match(/KEY=|user-data/)
    end

    it "keeps going and counts a failed delete without raising" do
      allow(adapter).to receive(:delete_cidata_iso_file).with(hash_including(filename: old_key_iso)).and_raise(StandardError, "boom")
      result = reap
      expect(result.failed.size).to eq(1)
      expect(result.deleted.map { |e| e[:filename] }).to eq([ orphan_iso ])
    end
  end

  it "keeps files newer than the grace window" do
    allow(adapter).to receive(:list_cidata_isos).and_return([ entry(orphan_iso, ctime: (now - 5.minutes).to_i) ])
    expect(reap.orphans).to be_empty
  end

  it "keeps the ISO of a not-yet-placed live instance (no cloud id yet) whatever its vmid" do
    pending_inst = create(:system_node_instance, status: "provisioning")
    pending_inst.update_columns(config: {})
    name = "cidata-9005-#{disc(pending_inst)}.iso"
    allow(adapter).to receive(:list_cidata_isos).and_return([ entry(name) ])
    expect(reap.orphans).to be_empty
  end

  it "keeps the current ISO of a live instance in ANOTHER account" do
    other = create(:system_node_instance, status: "running")
    other.merge_config!("cloud_instance_id" => "pve1/qemu/9004")
    expect(other.account_id).not_to eq(connection.account_id)
    name = "cidata-9004-#{disc(other)}.iso"
    allow(adapter).to receive(:list_cidata_isos).and_return([ entry(name) ])
    expect(reap.orphans).to be_empty
    expect(reap.kept_live).to eq(1)
  end

  it "treats the ISO of a terminated instance as an orphan" do
    dead = live_instance(9003, status: "terminated")
    name = "cidata-9003-#{disc(dead)}.iso"
    allow(adapter).to receive(:list_cidata_isos).and_return([ entry(name) ])
    expect(reap.orphans.map { |e| e[:filename] }).to eq([ name ])
  end

  it "leaves files it does not recognise alone" do
    allow(adapter).to receive(:list_cidata_isos).and_return([ entry("cidata-9000.iso"), entry("debian-12.iso") ])
    result = reap
    expect(result.orphans).to be_empty
    expect(result.unrecognised).to eq(2)
  end
end
