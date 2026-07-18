# frozen_string_literal: true

module System
  module Providers
    module Proxmox
      # Pure-Ruby ISO 9660 (NoCloud) image builder.
      #
      # Why in-process Ruby and not `genisoimage`/`xorriso`: the ops-hub
      # appliance image ships no CD-authoring tool AND no dpkg to add one, so the
      # backend can't shell out. This builds the tiny NoCloud seed (a couple of
      # root files + a volume label) itself.
      #
      # It is the API-token-safe counterpart to the NFS `cicustom` snippet path:
      # instead of writing snippet files onto a shared NFS storage (which needs a
      # kernel NFS client ops-hub lacks), the caller builds this ISO, uploads it
      # via the PVE storage API (Datastore.Allocate — no root@pam), and attaches
      # it as a CD-ROM. The guest's initramfs stager
      # (extensions/system/initramfs/modules.d/90powernode/powernode-cidata-payload.sh)
      # mounts it with `mount -t iso9660 -o ro` off /dev/sr[01] and reads
      # `user-data` + `meta-data` — so those exact lowercase names must survive
      # the mount. We emit a **Rock Ridge (SUSP)** name entry (NM) alongside the
      # ISO 9660 identifier so the Linux isofs driver presents the POSIX name
      # verbatim, exactly as a `genisoimage -R` NoCloud ISO does. The ISO 9660
      # fallback identifier is a spec-legal 8.3 uppercased name (USER_DAT.;1) for
      # readers that ignore Rock Ridge.
      #
      # Scope is deliberately minimal: a single flat root directory, no
      # subdirectories, no Joliet. Sufficient for a NoCloud seed; not a general
      # ISO writer.
      class CidataIsoBuilder
        SECTOR = 2048
        SYSTEM_AREA_SECTORS = 16 # sectors 0..15 (all zero)

        Entry = Struct.new(:name, :iso_id, :data, keyword_init: true)

        def self.build(files:, volume_id: "CIDATA")
          new(files: files, volume_id: volume_id).build
        end

        # files: ordered Hash/Array of [posix_name, content_string]
        def initialize(files:, volume_id: "CIDATA")
          @volume_id = volume_id.to_s
          @entries = files.map.with_index do |(name, content), i|
            Entry.new(name: name.to_s, iso_id: iso_identifier(name.to_s, i), data: content.to_s.dup.force_encoding("BINARY"))
          end
        end

        def build
          # --- layout (LBA = logical block address, 2048-byte sectors) ---
          pvd_lba        = SYSTEM_AREA_SECTORS       # 16
          terminator_lba = pvd_lba + 1               # 17
          l_path_lba     = terminator_lba + 1        # 18
          m_path_lba     = l_path_lba + 1            # 19
          root_dir_lba   = m_path_lba + 1            # 20

          root_dir_bytes = build_root_directory(root_dir_lba, file_lbas_placeholder: true)
          root_dir_sectors = sectors_for(root_dir_bytes.bytesize)
          first_file_lba = root_dir_lba + root_dir_sectors

          # Assign each file an LBA (sector-aligned) + rebuild the root dir with
          # the real extents now that we know them.
          lba = first_file_lba
          @file_lbas = {}
          @entries.each do |e|
            @file_lbas[e.name] = lba
            lba += sectors_for(e.data.bytesize)
          end
          total_sectors = lba

          root_dir_bytes = build_root_directory(root_dir_lba, file_lbas_placeholder: false)

          path_table_l = build_path_table(root_dir_lba, endian: :little)
          path_table_m = build_path_table(root_dir_lba, endian: :big)
          path_table_size = path_table_l.bytesize # both tables are the same size

          pvd = build_pvd(
            total_sectors: total_sectors, root_dir_lba: root_dir_lba,
            root_dir_len: root_dir_sectors * SECTOR, path_table_size: path_table_size,
            l_path_lba: l_path_lba, m_path_lba: m_path_lba
          )

          io = +"".b
          io << ("\x00".b * (SECTOR * SYSTEM_AREA_SECTORS))
          io << pad_sector(pvd)
          io << pad_sector(volume_descriptor_set_terminator)
          io << pad_sector(path_table_l)
          io << pad_sector(path_table_m)
          io << pad_sector(root_dir_bytes)
          @entries.each { |e| io << pad_sector(e.data) }
          io
        end

        private

        # ---- ISO 9660 identifier (fallback for non-Rock-Ridge readers) ----
        # 8.3, uppercase, d-characters (A-Z 0-9 _), version ";1". Rock Ridge NM
        # carries the true lowercase/dashed name, so this only needs uniqueness.
        def iso_identifier(name, index)
          base = name.upcase.gsub(/[^A-Z0-9_]/, "_")
          stem = base.split(".").first.to_s[0, 8]
          stem = "FILE#{index}" if stem.empty?
          "#{stem}.;1"
        end

        def sectors_for(bytes) = ((bytes + SECTOR - 1) / SECTOR)

        def pad_sector(bytes)
          rem = bytes.bytesize % SECTOR
          rem.zero? ? bytes.b : (bytes.b + ("\x00".b * (SECTOR - rem)))
        end

        # both-endian integer encodings (ISO 9660 stores LSB then MSB)
        def both32(n) = [ n ].pack("V") + [ n ].pack("N")
        def both16(n) = [ n ].pack("v") + [ n ].pack("n")

        # 7-byte directory recording timestamp (years since 1900, GMT offset in
        # 15-min units). Fixed epoch keeps the build deterministic + testable.
        def dir_datetime
          [ 125, 1, 1, 0, 0, 0, 0 ].pack("C6c") # 2025-01-01T00:00:00, +0
        end

        # ---- Rock Ridge SUSP entries -------------------------------------
        # SP (in the root "." record only) signals SUSP is in use; NM carries the
        # verbatim POSIX name; PX the POSIX file mode/links/uid/gid.
        def susp_sp
          # "SP" len=7 ver=1, 0xBE 0xEF check bytes, LEN_SKP=0
          "SP".b + [ 7, 1, 0xBE, 0xEF, 0 ].pack("C5")
        end

        def susp_nm(name)
          n = name.b
          # "NM" len ver flags(0) name...
          "NM".b + [ 5 + n.bytesize, 1, 0 ].pack("C3") + n
        end

        def susp_px(mode)
          # "PX" len=36 ver=1 : mode, links, uid, gid (each both-endian u32)
          "PX".b + [ 36, 1 ].pack("C2") + both32(mode) + both32(1) + both32(0) + both32(0)
        end

        # ---- directory records -------------------------------------------
        def dir_record(iso_id_bytes, extent_lba, data_len, is_dir:, system_use: "".b)
          len_fi = iso_id_bytes.bytesize
          base = 33 + len_fi
          base += 1 if base.odd? # pad file id to even boundary
          rec_len = base + system_use.bytesize
          # SUSP must also leave the record length even
          rec_len += 1 if rec_len.odd?

          rec = +"".b
          rec << [ rec_len ].pack("C")
          rec << [ 0 ].pack("C") # extended attribute record length
          rec << both32(extent_lba)
          rec << both32(data_len)
          rec << dir_datetime
          rec << [ is_dir ? 0x02 : 0x00 ].pack("C") # file flags
          rec << [ 0 ].pack("C") # file unit size
          rec << [ 0 ].pack("C") # interleave gap size
          rec << both16(1)       # volume sequence number
          rec << [ len_fi ].pack("C")
          rec << iso_id_bytes
          rec << "\x00".b if (33 + len_fi).odd? # pad file id
          rec << system_use
          rec << "\x00".b if rec.bytesize < rec_len # final even pad
          rec
        end

        def build_root_directory(root_dir_lba, file_lbas_placeholder:)
          dot    = dir_record("\x00".b, root_dir_lba, SECTOR, is_dir: true, system_use: susp_sp + susp_px(0o040555))
          dotdot = dir_record("\x01".b, root_dir_lba, SECTOR, is_dir: true, system_use: susp_px(0o040555))
          body = +"".b
          body << dot << dotdot
          @entries.each do |e|
            lba = file_lbas_placeholder ? 0 : @file_lbas.fetch(e.name)
            body << dir_record(e.iso_id.b, lba, e.data.bytesize, is_dir: false,
                               system_use: susp_nm(e.name) + susp_px(0o100444))
          end
          body
        end

        # ---- path table (one entry: the root directory) ------------------
        def build_path_table(root_dir_lba, endian:)
          di = "\x00".b # root directory identifier
          len_di = di.bytesize
          rec = +"".b
          rec << [ len_di ].pack("C")
          rec << [ 0 ].pack("C") # extended attribute record length
          rec << (endian == :little ? [ root_dir_lba ].pack("V") : [ root_dir_lba ].pack("N"))
          rec << (endian == :little ? [ 1 ].pack("v") : [ 1 ].pack("n")) # parent dir number
          rec << di
          rec << "\x00".b if len_di.odd?
          rec
        end

        # ---- primary volume descriptor -----------------------------------
        def build_pvd(total_sectors:, root_dir_lba:, root_dir_len:, path_table_size:, l_path_lba:, m_path_lba:)
          pvd = +"".b
          pvd << [ 1 ].pack("C")           # type: primary volume descriptor
          pvd << "CD001".b                 # standard identifier
          pvd << [ 1 ].pack("C")           # version
          pvd << "\x00".b                  # unused
          pvd << astr("", 32)              # system identifier
          pvd << dstr(@volume_id, 32)      # volume identifier (the label)
          pvd << ("\x00".b * 8)            # unused
          pvd << both32(total_sectors)     # volume space size
          pvd << ("\x00".b * 32)           # unused
          pvd << both16(1)                 # volume set size
          pvd << both16(1)                 # volume sequence number
          pvd << both16(SECTOR)            # logical block size
          pvd << both32(path_table_size)   # path table size
          pvd << [ l_path_lba ].pack("V")  # location of type-L path table
          pvd << [ 0 ].pack("V")           # optional L path table
          pvd << [ m_path_lba ].pack("N")  # location of type-M path table
          pvd << [ 0 ].pack("N")           # optional M path table
          pvd << dir_record("\x00".b, root_dir_lba, root_dir_len, is_dir: true).ljust(34, "\x00".b)[0, 34]
          pvd << dstr("", 128)             # volume set identifier
          pvd << astr("", 128)             # publisher identifier
          pvd << astr("", 128)             # data preparer identifier
          pvd << astr("POWERNODE CIDATA", 128) # application identifier
          pvd << astr("", 37)              # copyright file identifier
          pvd << astr("", 37)              # abstract file identifier
          pvd << astr("", 37)              # bibliographic file identifier
          ts = vol_datetime
          pvd << ts << ts                  # creation + modification
          pvd << ("0" * 16 + "\x00".b)     # expiration (none)
          pvd << ("0" * 16 + "\x00".b)     # effective (none)
          pvd << [ 1 ].pack("C")           # file structure version
          pvd << "\x00".b                  # unused
          pvd << ("\x00".b * 512)          # application used
          pvd << ("\x00".b * 653)          # reserved
          pvd
        end

        def volume_descriptor_set_terminator
          "\xFF".b + "CD001".b + [ 1 ].pack("C")
        end

        # 17-byte volume datetime: "YYYYMMDDHHMMSSss" + gmt offset byte.
        def vol_datetime = ("20250101000000" + "00").b + [ 0 ].pack("c")

        # a-characters / d-characters, space padded to len.
        def astr(s, len) = s.to_s.b.ljust(len, " ")[0, len]
        def dstr(s, len) = s.to_s.upcase.b.ljust(len, " ")[0, len]
      end
    end
  end
end
