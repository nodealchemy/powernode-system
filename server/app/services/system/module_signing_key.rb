# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "tmpdir"
require "open3"

module System
  # Self-generated LOCAL cosign signing key for native module signing on a plane
  # with NO Vault (operator chose local-key over Vault for ops-hub, task #48,
  # Fable-reviewed). Deliberately mirrors System::InternalCaService::LocalCaAdapter's
  # file-based custody: generate ONCE on first use, persist as a 0600 file under
  # the CA /persist tree, and register the PUBLIC key into
  # `system.module_signing.trusted_public_keys` so verifiers trust it.
  #
  # Why a 0600 FILE (not Security::SecretStore): the file is definitively
  # Vault-INDEPENDENT — SecretStore's peppered path (AccountEncryptionKeyService,
  # `vault:v…`) routes through Vault transit, exactly the coupling we're removing.
  # A plain file mirrors the CA root key, which is already proven durable on
  # ops-hub across recompose.
  #
  # SECRECY: this class NEVER logs, echoes, or returns the private key or the
  # password anywhere they could be captured — only the on-disk PATH + the
  # password value handed straight to cosign's env. Public key is not secret.
  class ModuleSigningKey
    class KeyError < StandardError; end

    TRUSTED_KEYS_SETTING = "system.module_signing.trusted_public_keys"

    # Material handed to the signer: the key file PATH (never its contents) + the
    # password (env-only) + the public key PEM (not secret). #inspect/#to_s REDACT
    # the password (Fable #8) so it can never surface in a log line, exception
    # dump, or console echo — the contract is "the password only ever reaches
    # cosign's subprocess env".
    Material = Struct.new(:key_path, :password, :public_key_pem, keyword_init: true) do
      def inspect
        "#<#{self.class} key_path=#{key_path.inspect} password=[REDACTED] " \
          "public_key_pem=#{public_key_pem ? '[present]' : 'nil'}>"
      end
      alias_method :to_s, :inspect
    end

    class << self
      def ensure!
        new.ensure!
      end
    end

    def initialize(dir: nil)
      @dir = dir || default_dir
    end

    # Idempotent: generates the keypair on first call (serialized by an exclusive
    # flock so concurrent first-use can't double-generate a mismatched key/pass
    # pair — Fable #4/#6), guarantees the PUBLIC key is registered in the trusted
    # list (raises if it can't be — Fable #2, a signing key whose pubkey isn't
    # trusted would let R6 silently fail-OPEN), and returns the Material.
    def ensure!
      FileUtils.mkdir_p(@dir, mode: 0o700)
      generate! unless complete?
      register_public_key!
      Material.new(key_path: key_path, password: read_password, public_key_pem: read_public)
    end

    private

    def default_dir
      ENV["POWERNODE_MODULE_SIGNING_DIR"].presence ||
        File.join(ENV.fetch("POWERNODE_CA_LOCAL_DIR", "/var/lib/powernode/internal-ca"), "module-signing")
    end

    def key_path  = File.join(@dir, "cosign.key")
    def pub_path  = File.join(@dir, "cosign.pub")
    def pass_path = File.join(@dir, "cosign.pass")
    def lock_path = File.join(@dir, ".cosign.lock")

    # All THREE files must be present for the material to be usable: a missing pub
    # (Fable #5) would let register_public_key! silently skip (→ #2), and a
    # key-without-pass or pass-without-key (Fable #6) can't sign. Any incomplete
    # set triggers a clean regenerate under the lock.
    def complete?
      File.exist?(key_path) && File.exist?(pub_path) && File.exist?(pass_path)
    end

    # Generate an ecdsa-p256 cosign keypair (cosign's default; matches the Vault
    # transit key type) EXACTLY ONCE, even under concurrent first-use. An
    # exclusive flock serializes generation; the double-check inside the lock
    # means the loser of the race returns without regenerating. Each output file
    # is written to a temp sibling then atomically renamed (Fable #4/#6) so a
    # reader never observes a torn file and a crash mid-generate leaves an
    # incomplete (→ regenerated) set rather than a key/pass MISMATCH. Key is
    # written LAST — its presence implies pass+pub already landed. The password +
    # key contents are NEVER logged.
    def generate!
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        return if complete? # another process won the race and already finished

        password = SecureRandom.base64(48)
        Dir.mktmpdir("cosign-keygen-") do |tmp|
          prefix = File.join(tmp, "cosign")
          _out, err, status = ::Open3.capture3(
            { "COSIGN_PASSWORD" => password },
            "cosign", "generate-key-pair", "--output-key-prefix", prefix
          )
          unless status.success?
            raise KeyError, "cosign generate-key-pair failed: " \
                            "#{::System::ShellOutputSanitizer.redact(err.presence) || "exit #{status.exitstatus}"}"
          end
          atomic_write(pass_path, password,                   0o600)
          atomic_write(pub_path,  File.read("#{prefix}.pub"), 0o644)
          atomic_write(key_path,  File.read("#{prefix}.key"), 0o600) # LAST: the marker
        end
        Rails.logger.info("[ModuleSigningKey] generated local cosign signing key at #{key_path} (0600)") if defined?(Rails)
      end
    end

    # Write to a temp sibling in the SAME dir (same filesystem → rename is atomic)
    # created with tight perms from the start (never briefly world-readable), then
    # rename over the target. No reader ever sees a partially-written key/pass/pub.
    def atomic_write(path, content, perm)
      tmp = File.join(@dir, ".#{File.basename(path)}.#{SecureRandom.hex(8)}.tmp")
      File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, perm) { |f| f.write(content) }
      File.chmod(perm, tmp)
      File.rename(tmp, path)
    rescue StandardError
      File.delete(tmp) if tmp && File.exist?(tmp)
      raise
    end

    # Ensure our PUBLIC key is in the trusted-key list — APPEND, never replace
    # (existing DEV Vault-transit + legacy keys MUST be retained so already-signed
    # artifacts stay verifiable; rotation = append new, cut over, keep old).
    #
    # FAIL-LOUD (Fable #2): a fresh plane where this silently failed would leave
    # trusted_public_keys EMPTY, R6's key_verification_available? false, and native
    # promote would then SKIP verification entirely — the exact write-only case R6
    # exists to prevent. So the append MUST succeed: we re-read after writing and
    # raise KeyError if our pubkey isn't present, which fails ensure! → fails
    # signing loudly rather than promoting an unverified artifact. Stored as a JSON
    # ARRAY (setting_type: "json") — the reader (OrasOciAdapter#site_setting_trusted_keys)
    # expects `Array(get(...))` to yield one PEM per element; a "string" type would
    # collapse the list into one blob and break per-key cosign verify.
    def register_public_key!
      pub = read_public
      raise KeyError, "local signing pubkey missing/blank at #{pub_path}" if pub.blank?

      existing = trusted_list
      return if existing.any? { |k| k.strip == pub.strip } # already trusted — idempotent

      ::SiteSetting.set(TRUSTED_KEYS_SETTING, existing + [ pub ], setting_type: "json")

      unless trusted_list.any? { |k| k.strip == pub.strip }
        raise KeyError, "failed to register local signing pubkey into #{TRUSTED_KEYS_SETTING}"
      end
      Rails.logger.info("[ModuleSigningKey] appended local public key to #{TRUSTED_KEYS_SETTING} (now #{existing.size + 1} key(s))") if defined?(Rails)
    rescue KeyError
      raise
    rescue StandardError => e
      # Any store/read failure is FATAL for local signing — do NOT swallow it
      # (swallowing is what fed the fail-open). Surface as a typed KeyError.
      raise KeyError, "trusted_public_keys registration failed: #{e.class}: #{e.message}"
    end

    def trusted_list
      Array(::SiteSetting.get(TRUSTED_KEYS_SETTING)).map { |k| k.to_s }.reject(&:blank?)
    end

    def read_password = File.read(pass_path).chomp
    def read_public   = File.exist?(pub_path) ? File.read(pub_path) : nil
  end
end
