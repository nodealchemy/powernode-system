# frozen_string_literal: true

# Generates and stores WireGuard keypairs for SDWAN peers. Public key lives
# on the Sdwan::PeerKey row (it isn't secret); private key is stored
# Vault-first via the VaultCredential concern (database-encrypted fallback
# when Vault is unavailable). Rotation creates a new row pointing at the
# previous via rotated_from_id.
#
# Key generation uses OpenSSL's X25519 raw operations (X25519 is the same
# curve WireGuard uses). The 32-byte raw private and public keys are
# base64-encoded — the same format `wg genkey` / `wg pubkey` emit.
#
# Slice 1 of the SDWAN plan.
require "openssl"
require "base64"

module Sdwan
  class KeyDistributor
    class GenerationError < StandardError; end

    # Returns the peer's active key, generating one if it has none. Idempotent.
    def self.ensure_key_for!(peer)
      existing = peer.active_key
      return existing if existing

      generate_and_store!(peer: peer)
    end

    # Force-rotates: marks the current key revoked and generates a fresh one
    # whose rotated_from_id chains back to the old.
    def self.rotate!(peer:, reason: "scheduled")
      ::Sdwan::PeerKey.transaction do
        previous = peer.active_key
        previous&.revoke!(reason: reason)
        generate_and_store!(peer: peer, rotated_from: previous)
      end
    end

    def self.generate_and_store!(peer:, rotated_from: nil)
      keypair = generate_keypair

      ::Sdwan::PeerKey.transaction do
        key = ::Sdwan::PeerKey.create!(
          peer: peer,
          public_key: keypair[:public_key_b64],
          rotated_from_id: rotated_from&.id
        )

        # store_in_vault writes the private half to Vault (with DB fallback)
        # and updates vault_path / migrated_to_vault_at on the row.
        key.store_in_vault(
          public_key: keypair[:public_key_b64],
          private_key: keypair[:private_key_b64],
          algorithm: "X25519",
          generated_at: Time.current.iso8601
        )

        key.reload
      end
    end

    # Returns { private_key_b64:, public_key_b64: }. Raises GenerationError
    # if the OpenSSL build doesn't expose raw X25519 ops.
    def self.generate_keypair
      pkey = OpenSSL::PKey.generate_key("X25519")

      raw_private =
        if pkey.respond_to?(:raw_private_key)
          pkey.raw_private_key
        else
          extract_raw_from_pkcs8(pkey.private_to_der)
        end

      raw_public =
        if pkey.respond_to?(:raw_public_key)
          pkey.raw_public_key
        else
          extract_raw_from_spki(pkey.public_to_der)
        end

      raise GenerationError, "X25519 private key is wrong length: #{raw_private.bytesize}" if raw_private.bytesize != 32
      raise GenerationError, "X25519 public key is wrong length: #{raw_public.bytesize}"   if raw_public.bytesize != 32

      {
        private_key_b64: Base64.strict_encode64(raw_private),
        public_key_b64: Base64.strict_encode64(raw_public)
      }
    end

    # PKCS#8 private key DER for X25519 ends with a 32-byte octet string —
    # the trailing 32 bytes are the raw key material. This holds across
    # OpenSSL versions because the algorithm-specific PrivateKey field for
    # X25519 is always a single 32-byte octet string per RFC 8410.
    def self.extract_raw_from_pkcs8(der)
      der.byteslice(-32, 32)
    end

    # SubjectPublicKeyInfo DER for X25519 ends with a 32-byte BIT STRING
    # body — same RFC 8410 reasoning.
    def self.extract_raw_from_spki(der)
      der.byteslice(-32, 32)
    end
  end
end
