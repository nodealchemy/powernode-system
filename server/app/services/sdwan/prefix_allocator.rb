# frozen_string_literal: true

# IPv6 ULA address derivation for SDWAN. Hierarchy:
#
#   per-install /40   fdXX:XXXX:XX00::/40  (random, persisted once on first
#                                           account allocation; shared by
#                                           every Sdwan::Configuration row
#                                           on this Powernode install)
#   per-account /48   fdXX:XXXX:XX??::/48  (8-bit hash of account_id with
#                                           rejection sampling against
#                                           Sdwan::Configuration)
#   per-network /64   fdXX:XXXX:XX??:????::/64  (16-bit hash of network_id
#                                                with rejection sampling
#                                                inside the account's /48)
#   per-peer /128     full 64 host bits derived from peer.id (deterministic,
#                     no collision check — UUIDs are unique already)
#
# Bit layout cheat-sheet:
#   Bits  0-15   group 1   "fdXX"
#   Bits 16-31   group 2   16 random install bits
#   Bits 32-47   group 3   high byte = 8 random install bits;
#                          low byte  = 8-bit per-account hash
#   Bits 48-63   group 4   16-bit per-network hash
#   Bits 64-127  groups 5-8   64 deterministic peer-host bits
#
# Slice 1 of the SDWAN plan.
require "digest"
require "securerandom"

module Sdwan
  class PrefixAllocator
    class CapacityExhausted < StandardError; end

    # Returns the Sdwan::Configuration for this account, creating it on first
    # call. The /40 root is generated once per install (the first row written
    # in the table) and reused for every account thereafter; the /48 is
    # rejection-sampled against existing rows so two accounts never collide.
    def self.ensure_configuration!(account_id:)
      Sdwan::Configuration.find_or_create_by!(account_id: account_id) do |cfg|
        cfg.instance_prefix_40 = install_prefix_40
        cfg.account_prefix_48  = pick_account_prefix_48(cfg.instance_prefix_40, account_id)
      end
    end

    # Returns a fresh /64 carved from the account's /48. Rejection-samples
    # against existing networks for that account so the 16-bit hash collisions
    # don't silently overwrite address space.
    def self.allocate_network_cidr!(account_id:, network_id:)
      cfg = ensure_configuration!(account_id: account_id)
      taken = ::Sdwan::Network.where(account_id: account_id).pluck(:cidr_64).to_set

      counter = 0
      loop do
        seed = counter.zero? ? network_id.to_s : "#{network_id}:#{counter}"
        word = network_word_from_seed(seed)
        cidr = compose_cidr_64(cfg.account_prefix_48, word)
        return cidr unless taken.include?(cidr)

        counter += 1
        raise CapacityExhausted, "exhausted /64 space (65536 networks per account)" if counter > 65_535
      end
    end

    # Deterministic /128 within a network's /64. Same peer_id always maps to
    # the same address — operators can read a packet capture and reverse to
    # a peer row without DB churn. UUIDv7 collisions are negligible so no
    # rejection sampling.
    def self.allocate_peer_address!(network:, peer_id:)
      host64 = peer_host_64bits_from_seed(peer_id.to_s)
      compose_address_128(network.cidr_64, host64)
    end

    # ------------------------------------------------------------------
    # Internal helpers — public for spec coverage.
    # ------------------------------------------------------------------

    # The install /40. Generated on first call, then frozen on the first
    # Sdwan::Configuration row. Subsequent reads return whatever the table
    # already has, so nothing else can re-roll it.
    def self.install_prefix_40
      existing = Sdwan::Configuration.where.not(instance_prefix_40: nil).limit(1).pluck(:instance_prefix_40).first
      return existing if existing

      generate_random_prefix_40
    end

    # 5 random bytes; first byte forced to 0xfd; lower 8 bits of byte 5 are
    # masked out to make this a clean /40 boundary.
    def self.generate_random_prefix_40
      bytes = SecureRandom.bytes(5).bytes
      bytes[0] = 0xfd
      bytes[4] &= 0x00 # mask lower byte of group 3 (per-account space)
      hex = bytes.map { |b| format("%02x", b) }.join
      "#{hex[0, 4]}:#{hex[4, 4]}:#{hex[8, 2]}00::/40"
    end

    def self.pick_account_prefix_48(instance_prefix_40, account_id)
      taken_bytes = Sdwan::Configuration
        .where(instance_prefix_40: instance_prefix_40)
        .pluck(:account_prefix_48)
        .map { |p| extract_account_byte(p) }
        .to_set

      counter = 0
      loop do
        seed = counter.zero? ? account_id.to_s : "#{account_id}:#{counter}"
        byte = account_byte_from_seed(seed)
        unless taken_bytes.include?(byte)
          return compose_prefix_48(instance_prefix_40, byte)
        end

        counter += 1
        raise CapacityExhausted, "exhausted /48 space (256 accounts per install)" if counter > 255
      end
    end

    def self.account_byte_from_seed(seed)
      Digest::SHA256.digest(seed.to_s).bytes.first
    end

    def self.network_word_from_seed(seed)
      digest = Digest::SHA256.digest(seed.to_s).bytes
      (digest[0] << 8) | digest[1]
    end

    def self.peer_host_64bits_from_seed(seed)
      Digest::SHA256.digest(seed.to_s)[0, 8]
    end

    # ------------------------------------------------------------------
    # CIDR composition
    # ------------------------------------------------------------------

    def self.compose_prefix_48(instance_prefix_40, account_byte)
      head, _ = instance_prefix_40.split("::/40")
      groups = head.split(":") # ["fdXX", "YYYY", "ZZ00"]
      group3_high = groups[2][0, 2]
      account_hex = format("%02x", account_byte)
      "#{groups[0]}:#{groups[1]}:#{group3_high}#{account_hex}::/48"
    end

    def self.compose_cidr_64(account_prefix_48, network_word)
      head, _ = account_prefix_48.split("::/48")
      word_hex = format("%04x", network_word)
      "#{head}:#{word_hex}::/64"
    end

    def self.compose_address_128(network_cidr_64, host64_bytes)
      head, _ = network_cidr_64.split("::/64")
      groups = host64_bytes.unpack("nnnn") # 4 unsigned 16-bit big-endian shorts
      hex_groups = groups.map { |g| format("%04x", g) }
      "#{head}:#{hex_groups.join(':')}/128"
    end

    def self.extract_account_byte(prefix_48)
      head, _ = prefix_48.split("::/48")
      group3 = head.split(":")[2]
      group3[2, 2].to_i(16)
    end
  end
end
