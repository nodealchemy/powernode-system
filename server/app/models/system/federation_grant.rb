# frozen_string_literal: true

module System
  # Cross-peer access grant. alice@A issues a grant to bob@B for a
  # specific resource (or all resources of a kind). bob's platform
  # presents the grant's bearer token alongside its mTLS cert when
  # calling A's federation_api/resources/* endpoints.
  #
  # TTL defaults to 30 days; revoked grants soft-delete with 90-day
  # retention before archival.
  #
  # Plan reference: Decentralized Federation §E + P4.2 + Fix 3.
  class FederationGrant < BaseRecord
    include System::Base

    SCOPES = %w[read write admin migrate].freeze

    DEFAULT_TTL = 30.days
    MIN_TTL     = 7.days
    REVOKED_RETENTION = 90.days

    # --- Bearer-token envelope (D2: HMAC-signed, replaces raw-PK token) ---
    #
    # New tokens are HMAC-signed envelopes `fgs.<grant_id>.<hex_sig>`; the
    # signature lets the verifier reject a forged/guessed token WITHOUT a DB
    # lookup, and the token is no longer just the grant's (guessable-shaped)
    # primary key.
    TOKEN_PREFIX  = "fgs."
    LEGACY_PREFIX = "fg-"

    # Domain separator for the federation-grant token HMAC. Keeps this
    # derivation in a distinct namespace from every other use of the shared
    # server-secret root (e.g. ModuleBuildDispatchService's per-closure
    # `closure_id` and per-module `module-webhook:<id>` derivations) so a
    # grant.id can never derive the same value as some closure_id / module_id.
    TOKEN_HMAC_DOMAIN = "federation-grant"

    # Grace flag for legacy raw-PK `fg-<id>` tokens. Default TRUE so this
    # change LANDS SAFELY — peers holding pre-envelope tokens keep working.
    # The operator re-issues each peer's grant token (now minted as an `fgs.`
    # envelope), then sets this false to reject legacy tokens entirely.
    LEGACY_TOKEN_ENV = "POWERNODE_FEDERATION_LEGACY_TOKEN"

    self.table_name = "system_federation_grants"

    belongs_to :federation_peer, class_name: "System::FederationPeer"
    # Optional — system-issued grants (e.g. service-subscription grants
    # from Federation::ServiceCatalogService when a remote peer subscribes
    # to an offering) have no specific user grantor; the operator's
    # authorization is implicit via the catalog itself.
    belongs_to :grantor_user,    class_name: "User", optional: true

    attribute :permission_scopes, :jsonb, default: -> { [] }
    attribute :metadata,          :jsonb, default: -> { {} }

    # Pessimistic-scope allowlists per Locked Decision #12. Empty = no
    # restriction on that axis (back-compat for v1 grants). Populated
    # = request denied unless the calling context matches.
    attribute :node_instance_ids, :jsonb, default: -> { [] }
    attribute :sdwan_network_ids, :jsonb, default: -> { [] }
    attribute :source_cidrs,      :jsonb, default: -> { [] }

    validates :remote_subject, presence: true, length: { maximum: 256 }
    validates :resource_kind,  presence: true, length: { maximum: 64 }
    validates :issued_at,      presence: true
    validates :expires_at,     presence: true
    validate  :expires_at_after_issued_at
    validate  :ttl_above_minimum
    validate  :permission_scopes_valid
    validate  :pessimistic_scope_arrays_well_formed

    before_validation :ensure_timestamps_present, on: :create

    scope :active, -> {
      where(revoked_at: nil, archived_at: nil)
        .where("expires_at > ?", Time.current)
    }
    scope :expired,  -> { where("expires_at <= ?", Time.current).where(archived_at: nil) }
    scope :revoked,  -> { where.not(revoked_at: nil).where(archived_at: nil) }
    scope :archived, -> { where.not(archived_at: nil) }
    scope :ready_for_archival, -> {
      where.not(revoked_at: nil)
        .where(archived_at: nil)
        .where("revoked_at < ?", REVOKED_RETENTION.ago)
    }
    scope :by_scope, ->(scope) { where("permission_scopes @> ?", [ scope.to_s ].to_json) }

    def active?
      revoked_at.nil? && archived_at.nil? && expires_at.present? && expires_at > Time.current
    end

    def expired?
      expires_at.present? && expires_at <= Time.current
    end

    def revoked?
      revoked_at.present?
    end

    def archived?
      archived_at.present?
    end

    def has_scope?(scope_name)
      permission_scopes.include?(scope_name.to_s)
    end

    # === Pessimistic scope predicates (LD #12) ===
    #
    # Each predicate returns true when:
    #   - the corresponding allowlist is empty (no restriction on this axis)
    #   - OR the supplied value is present in the allowlist
    #
    # The auth chain AND-combines all three; a populated allowlist
    # that doesn't match = request denied.

    def unrestricted?
      Array(node_instance_ids).empty? &&
        Array(sdwan_network_ids).empty? &&
        Array(source_cidrs).empty?
    end

    def applies_to_instance?(instance_id)
      list = Array(node_instance_ids).compact.map(&:to_s)
      return true if list.empty?
      return false if instance_id.blank?
      list.include?(instance_id.to_s)
    end

    def applies_to_network?(network_id)
      list = Array(sdwan_network_ids).compact.map(&:to_s)
      return true if list.empty?
      return false if network_id.blank?
      list.include?(network_id.to_s)
    end

    def applies_to_source_ip?(source_ip)
      list = Array(source_cidrs).compact.reject(&:blank?)
      return true if list.empty?
      return false if source_ip.blank?

      begin
        ip = ::IPAddr.new(source_ip.to_s)
      rescue ::IPAddr::InvalidAddressError, ArgumentError
        return false
      end

      list.any? do |cidr|
        begin
          ::IPAddr.new(cidr.to_s).include?(ip)
        rescue ::IPAddr::InvalidAddressError, ArgumentError
          false
        end
      end
    end

    # Returns true if ALL three pessimistic axes pass. Used by
    # FederationApi::BaseController#authorize_grant!.
    def applies_to?(instance_id:, sdwan_network_id:, source_ip:)
      applies_to_instance?(instance_id) &&
        applies_to_network?(sdwan_network_id) &&
        applies_to_source_ip?(source_ip)
    end

    def revoke!(reason: nil, user: nil)
      return false if revoked?
      update!(
        revoked_at: Time.current,
        revocation_reason: reason,
        metadata: metadata.merge("revoked_by_user_id" => user&.id).compact
      )
    end

    def archive!
      return false if archived?
      update!(archived_at: Time.current)
    end

    # The bearer token presented by the remote peer in
    # `Authorization: Bearer <token>`.
    #
    # Format (D2): an HMAC-signed envelope `fgs.<grant_id>.<hex_sig>` where
    #   hex_sig = HMAC-SHA256(server_secret, "federation-grant:<grant_id>")
    # rooted in the platform's shared server secret
    # (ModuleBuildDispatchService.server_secret — prod-fail-closed,
    # dev/test-fallback), domain-separated by TOKEN_HMAC_DOMAIN. The signature
    # lets the verifier reject a forged/guessed token WITHOUT a DB lookup, and
    # ROTATING the server secret invalidates EVERY outstanding token (then the
    # operator re-issues per peer).
    #
    # Returns nil when the server secret is unavailable (production, env unset)
    # — fail-closed: a caller cannot mint an unsigned token.
    #
    # Staged rollout: new grants immediately mint this `fgs.` envelope; pre-
    # envelope peers hold raw-PK `fg-<id>` tokens that the verifier still
    # accepts while POWERNODE_FEDERATION_LEGACY_TOKEN is on (the default), so
    # this lands without breaking federation. The operator flips it off after
    # re-issuing every peer's token.
    def bearer_token
      sig = self.class.token_signature(id)
      return nil if sig.blank?
      "#{TOKEN_PREFIX}#{id}.#{sig}"
    end

    class << self
      # HMAC-SHA256(server_secret, "federation-grant:<grant_id>"), hex-encoded.
      # Single source of truth for both minting (#bearer_token) and verifying
      # (.find_by_bearer_token). Returns nil — NEVER a fallback — when the
      # shared server secret is unset in production, so the verifier fails
      # closed rather than trusting a publicly-known dev value (repo is MIT).
      def token_signature(grant_id)
        secret = ::System::ModuleBuildDispatchService.server_secret
        return nil if secret.blank? || grant_id.blank?

        OpenSSL::HMAC.hexdigest("SHA256", secret, "#{TOKEN_HMAC_DOMAIN}:#{grant_id}")
      end

      # Resolve a presented bearer token to its FederationGrant.
      #   - `fgs.` envelope: recompute the HMAC and CONSTANT-TIME compare; only
      #     a valid signature reaches the DB lookup. Secret unset → nil.
      #   - `fg-` legacy: accepted only while the grace flag is on; logs a
      #     one-line deprecation warning (NEVER the token value).
      #   - anything else / a malformed / forged token → nil, never a 500.
      def find_by_bearer_token(token)
        return nil unless token.is_a?(String)

        if token.start_with?(TOKEN_PREFIX)
          resolve_signed_token(token)
        elsif token.start_with?(LEGACY_PREFIX)
          resolve_legacy_token(token)
        end
      end

      private

      def resolve_signed_token(token)
        # `fgs.<id>.<sig>` → 3 parts. A malformed token (missing id or sig)
        # yields a blank part → nil, never a 500.
        _prefix, grant_id, provided_sig = token.split(".", 3)
        return nil if grant_id.blank? || provided_sig.blank?

        expected_sig = token_signature(grant_id)
        return nil if expected_sig.blank? # secret unavailable → fail closed

        return nil unless ActiveSupport::SecurityUtils.secure_compare(expected_sig, provided_sig)

        # find_by only runs on a validly-SIGNED id, which we minted (a real
        # UUID), so no malformed-UUID StatementInvalid can reach here; the
        # rescue is belt-and-suspenders against any unexpected raise.
        find_by(id: grant_id)
      rescue StandardError
        nil
      end

      def resolve_legacy_token(token)
        return nil unless legacy_tokens_accepted?

        # One-line deprecation breadcrumb — NEVER log the token value.
        Rails.logger.warn(
          "[FederationGrant] accepted DEPRECATED raw-PK bearer token (legacy " \
          "grace) — re-issue this peer's grant and set #{LEGACY_TOKEN_ENV}=false"
        )
        id = token.sub(/\A#{Regexp.escape(LEGACY_PREFIX)}/, "")
        return nil if id.blank?

        # A garbage legacy id (non-UUID) would raise StatementInvalid on the
        # uuid cast — rescue so a malformed token is nil, not a 500.
        find_by(id: id)
      rescue StandardError
        nil
      end

      def legacy_tokens_accepted?
        ActiveModel::Type::Boolean.new.cast(ENV.fetch(LEGACY_TOKEN_ENV, true))
      end
    end

    private

    def ensure_timestamps_present
      self.issued_at ||= Time.current
      self.expires_at ||= issued_at + DEFAULT_TTL
    end

    def expires_at_after_issued_at
      return unless expires_at && issued_at
      return if expires_at > issued_at
      errors.add(:expires_at, "must be after issued_at")
    end

    def ttl_above_minimum
      return unless expires_at && issued_at
      return if (expires_at - issued_at) >= MIN_TTL
      errors.add(:expires_at, "TTL must be at least #{MIN_TTL.inspect} (#{MIN_TTL.to_i}s)")
    end

    def permission_scopes_valid
      bad = Array(permission_scopes).reject { |s| SCOPES.include?(s) }
      return if bad.empty?
      errors.add(:permission_scopes, "contains invalid scope(s): #{bad.inspect}; allowed: #{SCOPES.inspect}")
    end

    # Locked Decision #12 pessimistic scope columns are JSONB arrays. The
    # access path rescues per-element parse errors (e.g.,
    # IPAddr::InvalidAddressError) but write-time validation prevents bad
    # data from landing at all. Each column is independent: empty array
    # means unrestricted on that axis, populated means AND-gate against
    # the calling context.
    def pessimistic_scope_arrays_well_formed
      validate_string_id_array(node_instance_ids, :node_instance_ids)
      validate_string_id_array(sdwan_network_ids, :sdwan_network_ids)
      validate_cidr_array(source_cidrs,           :source_cidrs)
    end

    def validate_string_id_array(value, field)
      return if value.nil? || value == []
      unless value.is_a?(Array)
        errors.add(field, "must be an array (got #{value.class.name})")
        return
      end
      bad = value.reject { |id| id.is_a?(String) && id.present? && id.length <= 64 }
      return if bad.empty?
      errors.add(field, "contains invalid id entries: #{bad.first(3).inspect}")
    end

    def validate_cidr_array(value, field)
      return if value.nil? || value == []
      unless value.is_a?(Array)
        errors.add(field, "must be an array (got #{value.class.name})")
        return
      end
      bad = value.reject { |cidr| valid_cidr?(cidr) }
      return if bad.empty?
      errors.add(field, "contains invalid CIDR entries: #{bad.first(3).inspect}")
    end

    def valid_cidr?(cidr)
      return false unless cidr.is_a?(String) && cidr.present?
      ::IPAddr.new(cidr.to_s)
      true
    rescue ::IPAddr::InvalidAddressError, ArgumentError
      false
    end
  end
end
