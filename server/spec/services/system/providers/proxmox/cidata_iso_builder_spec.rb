# frozen_string_literal: true

require "rails_helper"

# Validates the pure-Ruby NoCloud ISO builder by PARSING the emitted image back
# (PVD → root directory → per-file extent + Rock Ridge NM name) and asserting a
# byte-exact round-trip. The companion integration proof is a real
# `mount -t iso9660 -o ro` (the transport the guest's powernode-cidata-payload.sh
# uses) — verified out-of-band on a host with an iso9660-capable kernel; ops-hub's
# own kernel lacks iso9660, which is WHY this seed is delivered as an attached CD
# rather than an NFS snippet.
RSpec.describe System::Providers::Proxmox::CidataIsoBuilder do
  SECTOR = 2048

  # ---- minimal ISO 9660 reader (mirror of the writer, for round-tripping) ----
  def read_pvd(iso)
    iso.byteslice(16 * SECTOR, SECTOR)
  end

  def le32(bytes, off)
    bytes.byteslice(off, 4).unpack1("V")
  end

  # Parse the root directory into { posix_name => content } using the Rock Ridge
  # NM entry for the name and the directory record's extent/length for content.
  def parse_root_files(iso)
    pvd = read_pvd(iso)
    root_rec = pvd.byteslice(156, 34)
    root_lba = le32(root_rec, 2)
    root_len = le32(root_rec, 10)
    dir = iso.byteslice(root_lba * SECTOR, root_len)

    files = {}
    pos = 0
    while pos < dir.bytesize
      len = dir.getbyte(pos)
      break if len.nil? || len.zero?

      rec = dir.byteslice(pos, len)
      pos += len

      len_fi = rec.getbyte(32)
      iso_id = rec.byteslice(33, len_fi)
      next if iso_id == "\x00".b || iso_id == "\x01".b # skip "." / ".."

      extent   = le32(rec, 2)
      data_len = le32(rec, 10)
      su_off   = 33 + len_fi
      su_off += 1 if (33 + len_fi).odd?
      system_use = rec.byteslice(su_off, rec.bytesize - su_off) || "".b

      name = rock_ridge_name(system_use) || iso_id
      files[name] = iso.byteslice(extent * SECTOR, data_len)
    end
    files
  end

  def rock_ridge_name(system_use)
    o = 0
    while o + 4 <= system_use.bytesize
      sig = system_use.byteslice(o, 2)
      elen = system_use.getbyte(o + 2)
      break if elen.nil? || elen.zero?

      return system_use.byteslice(o + 5, elen - 5) if sig == "NM".b

      o += elen
    end
    nil
  end

  let(:user_data) { "ID=uuid-1\nKEY=btok\nSERVER=https://ops-hub.ipnode.us\nCA_PEM_FILE=/run/powernode/enroll-ca.pem\n" }
  let(:meta_data) { "-----BEGIN CERTIFICATE-----\nMIIfake\n-----END CERTIFICATE-----\n" }
  let(:iso) { described_class.build(files: { "user-data" => user_data, "meta-data" => meta_data }) }

  it "emits a sector-aligned iso9660 image" do
    expect(iso.bytesize).to be > 0
    expect(iso.bytesize % SECTOR).to eq(0)
  end

  it "zeroes the 16-sector system area" do
    expect(iso.byteslice(0, 16 * SECTOR)).to eq("\x00".b * (16 * SECTOR))
  end

  it "writes a primary volume descriptor with the CIDATA volume label" do
    pvd = read_pvd(iso)
    expect(pvd.getbyte(0)).to eq(1)                 # PVD type
    expect(pvd.byteslice(1, 5)).to eq("CD001".b)    # standard identifier
    expect(pvd.byteslice(40, 32).strip).to eq("CIDATA".b) # volume identifier = label
  end

  it "terminates the volume descriptor set" do
    term = iso.byteslice(17 * SECTOR, 7)
    expect(term.getbyte(0)).to eq(0xFF)
    expect(term.byteslice(1, 5)).to eq("CD001".b)
  end

  it "round-trips each file's POSIX name (Rock Ridge) and exact content" do
    files = parse_root_files(iso)
    expect(files.keys).to contain_exactly("user-data".b, "meta-data".b)
    expect(files["user-data".b]).to eq(user_data.b)
    expect(files["meta-data".b]).to eq(meta_data.b)
  end

  it "keeps a spec-legal 8.3 ISO 9660 fallback identifier for non-Rock-Ridge readers" do
    root_lba = le32(read_pvd(iso).byteslice(156, 34), 2)
    dir = iso.byteslice(root_lba * SECTOR, SECTOR)
    expect(dir).to include("USER_DAT.".b)
    expect(dir).to include("META_DAT.".b)
  end

  it "handles content spanning multiple sectors" do
    big = "x" * (SECTOR * 2 + 5)
    image = described_class.build(files: { "user-data" => big, "meta-data" => "m" })
    files = parse_root_files(image)
    expect(files["user-data".b]).to eq(big.b)
    expect(files["meta-data".b]).to eq("m".b)
  end
end
