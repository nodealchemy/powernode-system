# frozen_string_literal: true

module System
  module DevCell
    # Generates an Ed25519 keypair IN-SERVICE (application code — never
    # `ssh-keygen` / a shell / `rails runner`, so no private key ever hits
    # shell history) and encodes it into the two OpenSSH formats the dev-cell's
    # git-over-SSH path needs:
    #
    #   * public_key_openssh  — "ssh-ed25519 AAAA... <comment>" — registered as
    #                            the Gitea deploy key (public, not secret).
    #   * private_key_openssh — "-----BEGIN OPENSSH PRIVATE KEY-----" (cipher
    #                            "none") — the cell's git SSH identity. Returned
    #                            to the caller ONCE, for Vault storage + the
    #                            mTLS bootstrap body, and NEVER logged.
    #
    # Ed25519 is chosen (operator preference; smaller, modern, Gitea-native).
    # OpenSSL 3.x exposes the raw key bytes (raw_public_key / raw_private_key),
    # from which both OpenSSH encodings are assembled per the format spec. The
    # encoding is round-trip-verified in the accompanying spec via
    # Net::SSH::KeyFactory (a broken private-key blob would fail to parse).
    class SshKeyGenerator
      KEY_TYPE = "ssh-ed25519"
      ALGORITHM = "ed25519"
      # "none" cipher OpenSSH private-key block size (padding boundary).
      BLOCK_SIZE = 8

      Keypair = Struct.new(
        :algorithm, :private_key_openssh, :public_key_openssh, :fingerprint,
        keyword_init: true
      )

      def self.generate(comment: "")
        new.generate(comment: comment)
      end

      def generate(comment: "")
        pkey = OpenSSL::PKey.generate_key("ED25519")
        raw_pub  = pkey.raw_public_key   # 32-byte public key
        raw_priv = pkey.raw_private_key  # 32-byte private seed

        public_blob = ssh_string(KEY_TYPE) + ssh_string(raw_pub)

        Keypair.new(
          algorithm: ALGORITHM,
          public_key_openssh: format_public(public_blob, comment),
          private_key_openssh: encode_openssh_private(public_blob, raw_pub, raw_priv, comment),
          fingerprint: sha256_fingerprint(public_blob)
        )
      end

      private

      # SSH wire-format string: 4-byte big-endian length prefix + raw bytes.
      def ssh_string(bytes)
        b = bytes.to_s.b
        [ b.bytesize ].pack("N") + b
      end

      def format_public(public_blob, comment)
        line = "#{KEY_TYPE} #{Base64.strict_encode64(public_blob)}"
        comment.to_s.empty? ? line : "#{line} #{comment}"
      end

      # OpenSSH SHA256 public-key fingerprint (unpadded base64 of SHA256(blob)).
      def sha256_fingerprint(public_blob)
        digest = OpenSSL::Digest::SHA256.digest(public_blob)
        "SHA256:#{Base64.strict_encode64(digest).delete('=')}"
      end

      # OpenSSH private-key format (PROTOCOL.key), unencrypted:
      #   "openssh-key-v1\0"
      #   | ssh_string(ciphername="none") | ssh_string(kdfname="none")
      #   | ssh_string(kdfoptions="")     | uint32(numkeys=1)
      #   | ssh_string(public_blob)       | ssh_string(private_section)
      # private_section:
      #   uint32(checkint) uint32(checkint)   # must match on decrypt
      #   | ssh_string("ssh-ed25519") | ssh_string(pub 32B)
      #   | ssh_string(seed 32B || pub 32B)   # OpenSSH 64-byte private field
      #   | ssh_string(comment)
      #   | padding 1,2,3,... up to BLOCK_SIZE
      def encode_openssh_private(public_blob, raw_pub, raw_priv, comment)
        check = [ SecureRandom.random_number(2**32) ].pack("N")

        priv = check + check +
               ssh_string(KEY_TYPE) +
               ssh_string(raw_pub) +
               ssh_string(raw_priv + raw_pub) +
               ssh_string(comment.to_s)

        pad = 0
        priv += ((pad += 1) & 0xFF).chr while (priv.bytesize % BLOCK_SIZE) != 0

        body = "openssh-key-v1\0".b +
               ssh_string("none") +
               ssh_string("none") +
               ssh_string("") +
               [ 1 ].pack("N") +
               ssh_string(public_blob) +
               ssh_string(priv)

        wrap_pem(Base64.strict_encode64(body))
      end

      def wrap_pem(b64)
        wrapped = b64.scan(/.{1,70}/).join("\n")
        "-----BEGIN OPENSSH PRIVATE KEY-----\n#{wrapped}\n-----END OPENSSH PRIVATE KEY-----\n"
      end
    end
  end
end
