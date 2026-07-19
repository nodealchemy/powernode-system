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
    # password (env-only) + the public key PEM (not secret).
    Material = Struct.new(:key_path, :password, :public_key_pem, keyword_init: true)

    class << self
      def ensure!
        new.ensure!
      end
    end

    def initialize(dir: nil)
      @dir = dir || default_dir
    end

    # Idempotent: generates the keypair on first call, appends the public key to
    # the trusted list, and returns the Material. Safe to call on every sign.
    def ensure!
      FileUtils.mkdir_p(@dir, mode: 0o700)
      generate! unless File.exist?(key_path) && File.exist?(pass_path)
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

    # Generate an ecdsa-p256 cosign keypair (cosign's default; matches the Vault
    # transit key type). cosign writes <prefix>.key (encrypted with
    # COSIGN_PASSWORD) + <prefix>.pub; we move them into the persist dir with
    # tight perms. The password + key contents are NEVER logged.
    def generate!
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
        File.write(key_path,  File.read("#{prefix}.key"), mode: "w", perm: 0o600)
        File.write(pub_path,  File.read("#{prefix}.pub"), mode: "w", perm: 0o644)
        File.write(pass_path, password,                   mode: "w", perm: 0o600)
      end
      Rails.logger.info("[ModuleSigningKey] generated local cosign signing key at #{key_path} (0600)") if defined?(Rails)
    end

    # Append our PUBLIC key to the trusted-key list if absent (idempotent).
    # APPEND, never replace — existing keys (DEV Vault transit + legacy) MUST be
    # retained so already-signed artifacts stay verifiable (rotation = append new,
    # cut over, keep old). Non-fatal: a SiteSetting hiccup must not break signing.
    def register_public_key!
      pub = read_public
      return if pub.blank?

      existing = Array(::SiteSetting.get(TRUSTED_KEYS_SETTING)).map { |k| k.to_s }.reject(&:blank?)
      return if existing.any? { |k| k.strip == pub.strip }

      # Store as a JSON ARRAY (setting_type: "json") — the trusted-key reader
      # (ModuleOciIngestService::OrasOciAdapter#site_setting_trusted_keys) expects
      # `Array(get(...))` to yield one PEM per element. A "string" type would
      # collapse the list into one blob and break per-key cosign verify.
      ::SiteSetting.set(TRUSTED_KEYS_SETTING, existing + [ pub ], setting_type: "json")
      Rails.logger.info("[ModuleSigningKey] appended local public key to #{TRUSTED_KEYS_SETTING} (now #{existing.size + 1} key(s))") if defined?(Rails)
    rescue StandardError => e
      Rails.logger.warn("[ModuleSigningKey] trusted_public_keys append failed (non-fatal): #{e.class}: #{e.message}") if defined?(Rails)
    end

    def read_password = File.read(pass_path).chomp
    def read_public   = File.exist?(pub_path) ? File.read(pub_path) : nil
  end
end
