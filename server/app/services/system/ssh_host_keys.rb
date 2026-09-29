# frozen_string_literal: true

require "base64"
require "digest"

module System
  # IMP-190834701b0a — validation and rendering for a node's SSH host PUBLIC
  # keys: the agent reports them on the heartbeat, System::SshHostKeyWriter
  # stores them on NodeInstance#ssh_host_keys, and System::SshExecutionService
  # renders them into a per-call known_hosts file.
  #
  # Every key passes through .normalize TWICE: on the way in (heartbeat
  # ingest) and on the way out (.recorded_for, which every known_hosts render
  # reads). The second pass is deliberate. A known_hosts file is a
  # line-oriented trust list, so a stored value carrying a newline could add
  # an entry of its own (a `@cert-authority *` line trusts every host). The
  # render must not rely on the writer having been the only thing that ever
  # touched the column.
  #
  # Public keys only. Nothing here reads, accepts or emits private material.
  # A value shaped like a private key fails the base64 check, because PEM
  # armor carries dashes and spaces, and its content is never echoed.
  module SshHostKeys
    # OpenSSH host key algorithms, in preference order. ed25519 comes first
    # because it is the directed preference and the modern default. DSA is
    # absent on purpose: OpenSSH has removed it.
    ALLOWED_TYPES = %w[
      ssh-ed25519
      ecdsa-sha2-nistp256
      ecdsa-sha2-nistp384
      ecdsa-sha2-nistp521
      sk-ssh-ed25519@openssh.com
      sk-ecdsa-sha2-nistp256@openssh.com
      ssh-rsa
    ].freeze

    # A 16384-bit RSA public key, the largest OpenSSH generates, is about 2.8
    # KB in base64. Anything past this bound is not a host key.
    MAX_KEY_CHARS = 4096
    # sshd ships one key per algorithm, so a handful covers every real host.
    MAX_KEYS = 8

    BASE64_FORMAT = %r{\A[A-Za-z0-9+/]+={0,2}\z}
    # The known_hosts HOST field. A strict charset keeps out the pattern
    # characters (`*`, `?`, `!`, `,`), whitespace and the `@` marker prefix.
    ALIAS_FORMAT = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

    module_function

    # Returns { "type", "key", "fingerprint" } for a valid entry, else nil.
    # Never raises on hostile input.
    def normalize(entry)
      return nil unless entry.is_a?(Hash)

      type = entry["type"] || entry[:type]
      key  = entry["key"] || entry[:key]
      return nil unless type.is_a?(String) && key.is_a?(String)
      return nil unless ALLOWED_TYPES.include?(type)
      return nil if key.length > MAX_KEY_CHARS || !key.match?(BASE64_FORMAT)

      blob = Base64.strict_decode64(key)
      return nil unless embedded_type(blob) == type

      { "type" => type, "key" => key, "fingerprint" => fingerprint(blob) }
    rescue ArgumentError, TypeError
      nil
    end

    # Valid entries only: de-duplicated by fingerprint, in ALLOWED_TYPES
    # preference order, capped at MAX_KEYS. A non-array payload yields [].
    def normalize_all(entries)
      return [] unless entries.is_a?(Array)

      entries.first(MAX_KEYS * 4)
             .filter_map { |entry| normalize(entry) }
             .uniq { |entry| entry["fingerprint"] }
             .sort_by.with_index { |entry, index| [ ALLOWED_TYPES.index(entry["type"]), index ] }
             .first(MAX_KEYS)
    end

    # The instance's recorded keys, re-validated. [] means no usable key,
    # whether the agent never reported one or every stored entry fails.
    def recorded_for(instance)
      document = instance.respond_to?(:ssh_host_keys) ? instance.ssh_host_keys : nil
      return [] unless document.is_a?(Hash)

      normalize_all(document["keys"])
    end

    def fingerprints(entries)
      Array(entries).map { |entry| entry["fingerprint"] }
    end

    # One "<alias> <type> <key>" line per entry. Only already-normalized
    # entries reach here, so neither field can carry whitespace.
    def known_hosts(host_alias, entries)
      raise ArgumentError, "invalid known_hosts alias" unless host_alias.to_s.match?(ALIAS_FORMAT)

      entries.map { |entry| "#{host_alias} #{entry.fetch('type')} #{entry.fetch('key')}\n" }.join
    end

    # SHA256:<unpadded base64>, the form `ssh-keygen -l` prints, so an audit
    # row can be matched against the node itself.
    def fingerprint(blob)
      "SHA256:#{Base64.strict_encode64(Digest::SHA256.digest(blob)).delete('=')}"
    end

    # The OpenSSH wire-format key blob opens with its own algorithm name
    # (uint32 length + string). It must agree with the declared type.
    def embedded_type(blob)
      return nil if blob.bytesize < 4

      length = blob.byteslice(0, 4).unpack1("N")
      return nil if length.zero? || length > 64 || blob.bytesize < 4 + length

      blob.byteslice(4, length)
    end
  end
end
