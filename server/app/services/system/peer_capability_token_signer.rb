# frozen_string_literal: true

require "base64"
require "json"
require "securerandom"
require "ed25519"

module System
  # AI/MCP workload substrate L2.5 (A2A) — mints + verifies Ed25519-signed peer
  # CAPABILITY TOKENS: portable proof that instance A (`sub`) may invoke skill S
  # (`skill`) on instance B (`aud`), authorized by the platform. The on-node A2A
  # MCP server verifies the signature OFFLINE against the advertised public key
  # (no per-call platform round-trip).
  #
  # Mirrors Sdwan::MembershipCredentialSigner's signing path (canonical JSON +
  # Ed25519 via the `ed25519` gem, private key from Vault, never logged).
  # Minting is GATED on PeerCapabilityService.authorize — a token is only issued
  # when the 4-gate A2A policy passes, so the signed token IS the capability.
  class PeerCapabilityTokenSigner
    class SigningError < StandardError; end
    class MissingKeyError < SigningError; end
    class NotAuthorizedError < SigningError; end

    DEFAULT_TTL_SECONDS = 300 # 5 min — short blast radius for a leaked token
    TOKEN_VERSION = 1

    Token = ::Struct.new(:envelope_json, :signature_b64, :handle, :public_key_b64, :claims, keyword_init: true)

    def self.mint!(caller_instance:, target_instance:, skill:, ttl_seconds: DEFAULT_TTL_SECONDS)
      new(account: caller_instance.account).mint!(
        caller_instance: caller_instance, target_instance: target_instance, skill: skill, ttl_seconds: ttl_seconds
      )
    end

    def initialize(account:)
      @account = account
    end

    def mint!(caller_instance:, target_instance:, skill:, ttl_seconds: DEFAULT_TTL_SECONDS)
      skill = skill.to_s
      raise SigningError, "skill is required" if skill.blank?
      raise NotAuthorizedError, "caller and target must share an account" unless same_account?(caller_instance, target_instance)

      caller_peer = peer_for(caller_instance)
      target_peer = peer_for(target_instance)
      raise NotAuthorizedError, "caller or target has not announced as a peer" unless caller_peer && target_peer

      decision = ::System::PeerCapabilityService.authorize(caller_peer: caller_peer, target_peer: target_peer, skill: skill)
      raise NotAuthorizedError, decision.reason unless decision.authorized

      now = Time.current
      material = signing_key_material!
      claims = {
        "v"       => TOKEN_VERSION,
        "iss"     => material[:handle],
        "account" => @account.id,
        "sub"     => caller_instance.id,
        "aud"     => target_instance.id,
        "skill"   => skill,
        "iat"     => now.to_i,
        "nbf"     => now.to_i,
        "exp"     => (now + ttl_seconds.to_i.seconds).to_i,
        "jti"     => ::SecureRandom.uuid
      }
      envelope_json = canonicalize(claims)
      signature_b64 = sign(envelope_json: envelope_json, private_key_b64: material[:private_key_b64])

      Token.new(
        envelope_json: envelope_json, signature_b64: signature_b64,
        handle: material[:handle], public_key_b64: material[:public_key_b64], claims: claims
      )
    end

    # Offline verification — used by specs + any platform-side check; the agent
    # does the equivalent with crypto/ed25519. Returns the claims hash or raises
    # SigningError.
    def self.verify!(envelope_json:, signature_b64:, public_key_b64:, audience: nil, skill: nil, now: nil)
      raw_pub = ::Base64.decode64(public_key_b64.to_s)
      raise SigningError, "bad public key length" unless raw_pub.bytesize == 32

      sig = ::Base64.decode64(signature_b64.to_s)
      ::Ed25519::VerifyKey.new(raw_pub).verify(sig, envelope_json) # raises Ed25519::VerifyError on mismatch

      claims = ::JSON.parse(envelope_json)
      t = (now || Time.current).to_i
      raise SigningError, "token not yet valid" if claims["nbf"] && t < claims["nbf"].to_i
      raise SigningError, "token expired"        if claims["exp"] && t >= claims["exp"].to_i
      raise SigningError, "audience mismatch"     if audience && claims["aud"].to_s != audience.to_s
      raise SigningError, "skill mismatch"        if skill && claims["skill"].to_s != skill.to_s

      claims
    rescue ::Ed25519::VerifyError
      raise SigningError, "signature verification failed"
    end

    # Active capability-signing public key(s) for the account, by handle — for
    # advertisement to agents (node_api config pull): [{ handle, public_key_b64, algorithm }]
    def self.advertised_keys_for(account)
      ::System::PeerCapabilitySigningKey.active.where(account_id: account.id).map do |k|
        { "handle" => k.handle, "public_key_b64" => k.public_key_b64, "algorithm" => "ED25519" }
      end
    end

    private

    def same_account?(a, b)
      a&.account_id.present? && a.account_id == b&.account_id
    end

    def peer_for(instance)
      ::System::NodeInstancePeer.find_by(node_instance_id: instance.id)
    end

    def handle_for(account)
      "a2a-cap-acct-#{account.id.to_s.delete('-').first(16)}"
    end

    # Resolve (or first-use mint) the account's capability signing key. The
    # private key is generated in-process via the ed25519 gem and immediately
    # handed to the VaultCredential plumbing (Vault when available, encrypted DB
    # fallback); it never appears in a log line. Mirrors the SDWAN MC signer.
    def signing_key_material!
      handle = handle_for(@account)
      holder = ::System::PeerCapabilitySigningKey.active.find_by(account_id: @account.id, handle: handle)

      if holder
        priv = holder.private_key_b64
        raise MissingKeyError, "capability signing key #{holder.id} present but private key unavailable" if priv.blank?
        return { handle: handle, private_key_b64: priv, public_key_b64: holder.public_key_b64 }
      end

      keypair = generate_signing_keypair
      holder = ::System::PeerCapabilitySigningKey.create!(
        account: @account, handle: handle, public_key_b64: keypair[:public_key_b64],
        metadata: { "algorithm" => "ED25519", "generated_at" => Time.current.iso8601 }
      )
      holder.store_in_vault(
        private_key_b64: keypair[:private_key_b64], public_key_b64: keypair[:public_key_b64],
        algorithm: "ED25519", generated_at: Time.current.iso8601
      )
      { handle: handle, private_key_b64: keypair[:private_key_b64], public_key_b64: keypair[:public_key_b64] }
    end

    def generate_signing_keypair
      signing_key = ::Ed25519::SigningKey.generate
      raw_private = signing_key.to_bytes
      raw_public  = signing_key.verify_key.to_bytes
      raise SigningError, "ED25519 raw key wrong length" unless raw_private.bytesize == 32 && raw_public.bytesize == 32

      { private_key_b64: ::Base64.strict_encode64(raw_private), public_key_b64: ::Base64.strict_encode64(raw_public) }
    end

    def sign(envelope_json:, private_key_b64:)
      raw = ::Base64.decode64(private_key_b64)
      raise MissingKeyError, "capability signing key not found" if raw.blank?
      raise SigningError, "ED25519 raw key wrong length" unless raw.bytesize == 32

      ::Base64.strict_encode64(::Ed25519::SigningKey.new(raw).sign(envelope_json))
    end

    def canonicalize(hash)
      ::JSON.generate(deep_sort(hash))
    end

    def deep_sort(obj)
      case obj
      when Hash then obj.sort.to_h { |k, v| [k, deep_sort(v)] }
      when Array then obj.map { |e| deep_sort(e) }
      else obj
      end
    end
  end
end
