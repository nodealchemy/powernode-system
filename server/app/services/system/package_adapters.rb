# frozen_string_literal: true

module System
  # Package-repository adapters for converting upstream metadata indexes
  # (apt's Packages files, rpm's repomd.xml + primary.xml) into the
  # platform's normalized Package shape.
  #
  # Adapter selection happens via #for(kind:), mirroring how
  # LocalQemuProvider's adapter pattern picks Libvirt/Recorder/Disabled.
  #
  # Architecture caveat: apt supports multi-arch in one mmdebstrap chroot
  # via qemu-user-static binfmt, but native arm64 Gitea runners exist in
  # the fleet so we dispatch a matrix job (one per arch) instead. RPM
  # adapters MUST always dispatch one-job-per-arch — `dnf --installroot
  # --forcearch` is incomplete and unsafe.
  module PackageAdapters
    class UnsupportedKindError < StandardError; end

    def self.for(kind:)
      case kind.to_s
      when "apt"        then AptAdapter.new
      when "rpm", "dnf" then RpmAdapter.new
      else raise UnsupportedKindError, "Unknown package repository kind: #{kind}"
      end
    end
  end
end
