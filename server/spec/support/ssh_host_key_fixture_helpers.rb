# frozen_string_literal: true

require "base64"

# IMP-190834701b0a — SSH host PUBLIC key fixtures, built at runtime.
#
# Never a committed literal: gitleaks does not allowlist spec files and push
# protection scans every commit, so a key-shaped string in source is a hazard
# even when it is only a public key. Each blob is the OpenSSH wire format the
# real key would carry (uint32 length + type name, then uint32 length + key
# bytes), with random bytes standing in for the key itself — enough for the
# validator's embedded-type check and for a real SHA256 fingerprint.
module SshHostKeyFixtures
  module_function

  def blob(type = "ssh-ed25519", body_bytes: 32)
    [ type.bytesize ].pack("N") + type + [ body_bytes ].pack("N") + Random.bytes(body_bytes)
  end

  def key(type = "ssh-ed25519", body_bytes: 32)
    Base64.strict_encode64(blob(type, body_bytes: body_bytes))
  end

  def entry(type = "ssh-ed25519", body_bytes: 32)
    { "type" => type, "key" => key(type, body_bytes: body_bytes) }
  end

  def fingerprint(key_b64)
    "SHA256:#{Base64.strict_encode64(Digest::SHA256.digest(Base64.strict_decode64(key_b64))).delete('=')}"
  end

  # The stored column document, as System::SshHostKeyWriter persists it.
  def document(*entries, boot_id: "boot-fixture")
    {
      "keys" => entries.map { |e| e.merge("fingerprint" => fingerprint(e["key"])) },
      "recorded_at" => Time.current.utc.iso8601,
      "boot_id" => boot_id
    }
  end
end
