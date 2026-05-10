# frozen_string_literal: true

# Issues and re-issues Sdwan::MembershipCredential rows. The signer is the
# only path through which MCs come into existence — controllers call it
# from the topology compile path, the autonomy refresher calls it before
# expiry, and operators call it indirectly via the MCP "issue MC" surface.
#
# Signer responsibilities:
#
#   1. Resolve the constellation signing key (Vault-stored Ed25519
#      private key, namespace "constellation"). N0 derives a single
#      per-account constellation handle ("constellation:<account_uuid>")
#      so the model wire-shape is forward-compatible with the N2
#      Constellation/Root models without requiring those tables to exist
#      yet. When the N2 models land, we swap the resolver to fetch the
#      constellation row + its signing-key vault path.
#   2. Render the canonical envelope JSON. The renderer is deterministic
#      — given the same inputs it produces the same bytes. The agent
#      verifies the signature over `envelope_json` exactly as persisted.
#   3. Sign with Ed25519. Signature is base64-encoded for transport.
#   4. Persist the new MC + supersede the previous active row in the
#      same transaction. The partial unique index on `(peer, network)
#      WHERE status = 'active'` would otherwise trip on a refresh.
#   5. Emit FleetEvents (`sdwan.credential_issued`) so the operator
#      dashboard sees every issuance. Failures emit
#      `sdwan.credential_refresh_failed`.
#
# Phase N0 of the in-house encrypted mesh overlay roadmap.
require "base64"
require "json"
require "openssl"

module Sdwan
  class MembershipCredentialSigner
    class SigningError < StandardError; end
    class MissingKeyError < SigningError; end

    # Default validity window (1 hour) and refresh boundary (30 min in).
    # Plan §4.2 fixes these — short enough to limit blast radius of a
    # leaked envelope, long enough that a single missed heartbeat doesn't
    # tear down a tunnel.
    DEFAULT_TTL_SECONDS     = 3_600
    DEFAULT_REFRESH_SECONDS = 1_800

    def self.issue!(peer:, ttl_seconds: DEFAULT_TTL_SECONDS, refresh_seconds: DEFAULT_REFRESH_SECONDS)
      new(peer: peer).issue!(ttl_seconds: ttl_seconds, refresh_seconds: refresh_seconds)
    end

    # Returns the current active MC for (peer, network) if it is still
    # within its refresh window — otherwise issues a fresh one.
    # Idempotent for the same tick.
    def self.ensure_fresh!(peer:, ttl_seconds: DEFAULT_TTL_SECONDS, refresh_seconds: DEFAULT_REFRESH_SECONDS)
      current = ::Sdwan::MembershipCredential
                  .where(sdwan_peer_id: peer.id, sdwan_network_id: peer.sdwan_network_id, status: "active")
                  .order(revision: :desc)
                  .first
      return current if current&.usable? && !current.refresh_due?

      issue!(peer: peer, ttl_seconds: ttl_seconds, refresh_seconds: refresh_seconds)
    end

    def initialize(peer:)
      @peer = peer
      @account = peer.account
      @network = peer.network
    end

    def issue!(ttl_seconds: DEFAULT_TTL_SECONDS, refresh_seconds: DEFAULT_REFRESH_SECONDS)
      validate_inputs!(ttl_seconds: ttl_seconds, refresh_seconds: refresh_seconds)

      now = Time.current
      not_before    = now
      not_after     = now + ttl_seconds.seconds
      refresh_after = now + refresh_seconds.seconds

      next_revision = next_revision_for(@peer, @network)
      handle        = constellation_handle_for(@account)

      envelope_hash = render_envelope(
        peer: @peer,
        network: @network,
        revision: next_revision,
        not_before: not_before,
        not_after: not_after,
        constellation_handle: handle
      )

      envelope_json = canonicalize(envelope_hash)
      signing_material = signing_key_material!(handle)

      signature_b64 = sign(envelope_json: envelope_json, private_key_b64: signing_material[:private_key_b64])

      mc = ::Sdwan::MembershipCredential.transaction do
        # Supersede the previous active row in the same txn so the
        # partial unique index doesn't trip.
        previous = ::Sdwan::MembershipCredential
                     .where(sdwan_peer_id: @peer.id, sdwan_network_id: @network.id, status: "active")
                     .lock
                     .first
        previous&.supersede(reason: "rotated_revision_#{next_revision}")
        previous&.save!

        record = ::Sdwan::MembershipCredential.new(
          account: @account,
          peer: @peer,
          network: @network,
          revision: next_revision,
          issued_at: now,
          not_before: not_before,
          not_after: not_after,
          refresh_after: refresh_after,
          envelope_json: envelope_json,
          signature_b64: signature_b64,
          constellation_handle: handle,
          signed_with_vault_path: signing_material[:vault_path]
        )
        record.issue
        record.save!
        record
      end

      emit_event(
        kind: "sdwan.credential_issued",
        severity: :low,
        payload: issued_payload(mc)
      )

      mc
    rescue StandardError => e
      emit_event(
        kind: "sdwan.credential_refresh_failed",
        severity: :high,
        payload: {
          peer_id: @peer&.id,
          network_id: @network&.id,
          error_class: e.class.to_s,
          error_message: e.message
        }
      )
      # Re-raise — callers (autonomy refresher, controller) decide
      # whether to retry, surface, or escalate.
      raise
    end

    # Revokes the current active/expiring MC for (peer, network).
    # Returns the affected row (or nil if none was live).
    def self.revoke_for!(peer:, reason: "operator_revoked")
      live = ::Sdwan::MembershipCredential
               .where(sdwan_peer_id: peer.id, sdwan_network_id: peer.sdwan_network_id, status: %w[active expiring])
               .lock
               .order(revision: :desc)
               .first
      return nil unless live

      live.revoke(reason: reason)
      live.save!

      ::System::Fleet::EventBroadcaster.emit!(
        account: peer.account,
        kind: "sdwan.credential_revoked",
        severity: :medium,
        payload: {
          peer_id: peer.id,
          network_id: peer.sdwan_network_id,
          revision: live.revision,
          reason: reason.to_s
        },
        source: "sdwan.mc_signer"
      ) if defined?(::System::Fleet::EventBroadcaster)

      live
    end

    private

    attr_reader :peer, :network, :account

    def validate_inputs!(ttl_seconds:, refresh_seconds:)
      raise SigningError, "peer is required"    if peer.nil?
      raise SigningError, "network is required" if network.nil?
      raise SigningError, "account is required" if account.nil?

      key = peer.active_key
      raise SigningError, "peer has no active WireGuard key" if key.nil?
      raise SigningError, "ttl_seconds must be positive"     unless ttl_seconds.to_i.positive?
      raise SigningError, "refresh_seconds must be positive" unless refresh_seconds.to_i.positive?
      raise SigningError, "refresh_seconds must be < ttl_seconds" if refresh_seconds.to_i >= ttl_seconds.to_i
    end

    def next_revision_for(peer, network)
      max = ::Sdwan::MembershipCredential
              .where(sdwan_peer_id: peer.id, sdwan_network_id: network.id)
              .maximum(:revision) || 0
      max + 1
    end

    # Until N2 lands the Constellation table, we use a deterministic
    # per-account handle. The wire format is identical — only the
    # provenance changes when constellations become first-class.
    def constellation_handle_for(account)
      "acct-#{account.id.to_s.delete('-').first(16)}"
    end

    # Canonical envelope shape. Plan §4.2 — JWT-ish but unwrapped (we
    # ship the JSON + signature side-by-side rather than concatenating
    # base64-encoded segments) so debuggers can inspect the body without
    # decoding.
    def render_envelope(peer:, network:, revision:, not_before:, not_after:, constellation_handle:)
      key = peer.active_key
      {
        "iss" => constellation_handle,
        "sub" => peer_handle(peer),
        "aud" => network_handle(network),
        "iat" => not_before.to_i,
        "nbf" => not_before.to_i,
        "exp" => not_after.to_i,
        "rev" => revision,
        "wg_pubkey" => key.public_key,
        "addr_v6" => normalize_address(peer.assigned_address),
        "managed_routes" => Array(peer.respond_to?(:lan_subnets) ? peer.lan_subnets : []).map { |cidr| { "dst" => cidr.to_s } },
        # Tags + capabilities are populated in N1b; emit empty arrays
        # in N0 so the wire shape is stable.
        "tags" => [],
        "capabilities" => [],
        "endpoints" => endpoints_for(peer)
      }
    end

    # Stable peer identifier: 16-char base32 of SHA256(public_key).
    # Plan §4.1 calls this the "peer handle." Used as the protocol-level
    # identifier in WHOIS/RENDEZVOUS (N3+); we emit it now so the wire
    # shape stays consistent.
    def peer_handle(peer)
      key = peer.active_key
      digest = ::Digest::SHA256.digest(key.public_key.to_s)
      ::Base32.encode(digest)[0, 16].downcase
    rescue NameError
      # Base32 gem may not be loaded in core; hex fallback. The handle
      # contract is "16 stable bytes derivable by the agent" — both
      # encodings satisfy that, agent does the same fallback.
      ::Digest::SHA256.hexdigest(peer.active_key.public_key.to_s)[0, 16]
    end

    def network_handle(network)
      "net-#{network.id.to_s.delete('-').first(8)}"
    end

    # CIDR'd assigned_address → bare /128 address for the envelope.
    def normalize_address(addr)
      return nil if addr.blank?
      addr.to_s.split("/").first
    end

    # Endpoint candidates — picked off Sdwan::Peer's dual-stack columns.
    # N4 will replace this with the multi-endpoint candidates table.
    def endpoints_for(peer)
      out = []
      if peer.respond_to?(:endpoint_host_v6) && peer.endpoint_host_v6.present?
        out << { "host" => peer.endpoint_host_v6, "port" => peer.endpoint_port.to_i, "kind" => "wan", "v6" => true }
      end
      if peer.respond_to?(:endpoint_host_v4) && peer.endpoint_host_v4.present?
        out << { "host" => peer.endpoint_host_v4, "port" => peer.endpoint_port.to_i, "kind" => "wan", "v6" => false }
      end
      if out.empty? && peer.respond_to?(:endpoint_host) && peer.endpoint_host.present?
        family_v6 = peer.endpoint_host.to_s.include?(":")
        out << {
          "host" => peer.endpoint_host,
          "port" => peer.endpoint_port.to_i,
          "kind" => "wan",
          "v6" => family_v6
        }
      end
      out
    end

    # Stable canonical JSON for signing. JSON.generate with sorted keys
    # at every level so that two callers producing the same logical
    # envelope produce byte-identical strings (and therefore identical
    # signatures, allowing peer-to-peer revision comparisons later).
    def canonicalize(hash)
      ::JSON.generate(deep_sort(hash))
    end

    def deep_sort(obj)
      case obj
      when Hash
        obj.sort.to_h { |k, v| [k, deep_sort(v)] }
      when Array
        obj.map { |e| deep_sort(e) }
      else
        obj
      end
    end

    # Resolves the constellation signing key from Vault. In N0 the key
    # is per-account (one constellation per account); the resolver
    # auto-mints a key on first use so the signer doesn't require an
    # explicit "create constellation" step before MCs can issue.
    #
    # The Sdwan::ConstellationSigningKey row is the VaultCredential
    # holder — it gives the Vault provider an AR record to bind the
    # vault_path / encrypted_credentials columns to. Public half is
    # column-stored; private half is Vault-only (DB-encrypted fallback
    # when Vault is unavailable in test/dev).
    #
    # Returns `{ private_key_b64:, public_key_b64:, vault_path: }`.
    # The private key NEVER appears in logs; we hand it to OpenSSL and
    # discard the local reference immediately after sign() returns.
    def signing_key_material!(handle)
      holder = ::Sdwan::ConstellationSigningKey
                 .active
                 .find_by(account_id: account.id, handle: handle)

      if holder
        priv = holder.private_key_b64
        if priv.present?
          return {
            private_key_b64: priv,
            public_key_b64:  holder.public_key_b64,
            vault_path:      holder.vault_path
          }
        end
        # Holder exists but private key missing (Vault eviction or
        # corrupted DB fallback). Refuse rather than silently mint a
        # second key — operator must explicitly rotate via N5+.
        raise MissingKeyError, "constellation signing key holder #{holder.id} present but private key unavailable"
      end

      # First use — mint and persist. Generation runs in process; the
      # raw key bytes are immediately handed to the VaultCredential
      # plumbing (store_in_vault) which writes to Vault when available
      # and to the encrypted DB column otherwise. Raw private key
      # never appears in a log line.
      keypair = generate_signing_keypair
      holder = ::Sdwan::ConstellationSigningKey.create!(
        account: account,
        handle: handle,
        public_key_b64: keypair[:public_key_b64],
        metadata: { "algorithm" => "ED25519", "generated_at" => Time.current.iso8601 }
      )
      holder.store_in_vault(
        private_key_b64: keypair[:private_key_b64],
        public_key_b64:  keypair[:public_key_b64],
        algorithm: "ED25519",
        generated_at: Time.current.iso8601
      )

      # Re-fetch to bypass the VaultCredential concern's @vault_credentials
      # memoization (cleared by store_in_vault but the reload-doesn't-clear-
      # ivars Rails behavior leaves it stuck at nil otherwise).
      fresh = ::Sdwan::ConstellationSigningKey.find(holder.id)

      {
        private_key_b64: keypair[:private_key_b64],
        public_key_b64:  keypair[:public_key_b64],
        vault_path:      fresh.vault_path
      }
    end

    # Ed25519 keypair via OpenSSL raw operations. Mirrors KeyDistributor's
    # X25519 helpers — we want the same {private_b64, public_b64} shape so
    # downstream consumers (verifier in agent, manifest signer in N2) can
    # share one decoder.
    def generate_signing_keypair
      pkey = ::OpenSSL::PKey.generate_key("ED25519")

      raw_private =
        if pkey.respond_to?(:raw_private_key)
          pkey.raw_private_key
        else
          # PKCS#8 SEED for Ed25519 is the trailing 32 bytes per RFC 8410.
          pkey.private_to_der.byteslice(-32, 32)
        end
      raw_public =
        if pkey.respond_to?(:raw_public_key)
          pkey.raw_public_key
        else
          pkey.public_to_der.byteslice(-32, 32)
        end

      raise SigningError, "ED25519 raw key wrong length" unless raw_private.bytesize == 32 && raw_public.bytesize == 32

      {
        private_key_b64: ::Base64.strict_encode64(raw_private),
        public_key_b64: ::Base64.strict_encode64(raw_public)
      }
    end

    def sign(envelope_json:, private_key_b64:)
      raw = ::Base64.decode64(private_key_b64)
      raise MissingKeyError, "constellation signing key not found" if raw.blank?

      pkey = ::OpenSSL::PKey.new_raw_private_key("ED25519", raw)
      sig = pkey.sign(nil, envelope_json)
      ::Base64.strict_encode64(sig)
    end

    def emit_event(kind:, severity:, payload:)
      return unless defined?(::System::Fleet::EventBroadcaster)

      ::System::Fleet::EventBroadcaster.emit!(
        account: account,
        kind: kind,
        severity: severity,
        payload: payload,
        source: "sdwan.mc_signer"
      )
    rescue StandardError => e
      Rails.logger.warn("[Sdwan::MembershipCredentialSigner] event emit failed: #{e.class}: #{e.message}")
    end

    def issued_payload(mc)
      {
        peer_id: mc.sdwan_peer_id,
        network_id: mc.sdwan_network_id,
        node_instance_id: peer.node_instance_id,
        revision: mc.revision,
        constellation_handle: mc.constellation_handle,
        not_before: mc.not_before.utc.iso8601,
        not_after: mc.not_after.utc.iso8601,
        refresh_after: mc.refresh_after.utc.iso8601
      }
    end
  end
end
