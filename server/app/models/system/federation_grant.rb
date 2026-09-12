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

    # --- Bearer-token envelope (D2: HMAC-signed) ---
    #
    # Tokens are HMAC-signed envelopes `fgs.<grant_id>.<hex_sig>`; the
    # signature lets the verifier reject a forged/guessed token WITHOUT a DB
    # lookup, and the token is not just the grant's (guessable-shaped)
    # primary key. This is the only token shape accepted.
    TOKEN_PREFIX  = "fgs."

    # Domain separator for the federation-grant token HMAC. Keeps this
    # derivation in a distinct namespace from every other use of the shared
    # server-secret root (e.g. ModuleBuildDispatchService's per-closure
    # `closure_id` and per-module `module-webhook:<id>` derivations) so a
    # grant.id can never derive the same value as some closure_id / module_id.
    TOKEN_HMAC_DOMAIN = "federation-grant"

    # Sentinel for "any value on this axis". A pessimistic-scope allowlist
    # that means unrestricted says so explicitly as `["*"]`; it must stand
    # alone (never mixed with concrete entries).
    ANY = "*"

    self.table_name = "system_federation_grants"

    belongs_to :federation_peer, class_name: "System::FederationPeer"
    # Optional — system-issued grants (e.g. service-subscription grants
    # from Federation::ServiceCatalogService when a remote peer subscribes
    # to an offering) have no specific user grantor; the operator's
    # authorization is implicit via the catalog itself.
    belongs_to :grantor_user,    class_name: "User", optional: true

    attribute :permission_scopes, :jsonb, default: -> { [] }
    attribute :metadata,          :jsonb, default: -> { {} }

    # Pessimistic-scope allowlists per Locked Decision #12. `["*"]` (ANY) =
    # no restriction on that axis; concrete entries = request denied unless
    # the calling context matches; blank = deny. Validation refuses a blank
    # axis, so every creator states each axis explicitly.
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
    # Checked when a grant is created or an axis changes — not on every save,
    # so revoke!/archive! still work on a row written around validation (such
    # a row denies anyway; blocking its revocation would only strand it).
    validate  :pessimistic_scope_arrays_well_formed, if: :pessimistic_scope_changed?

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
    #   - the corresponding allowlist is exactly `["*"]` (ANY on this axis)
    #   - OR the supplied value is present in the allowlist
    # and false when the allowlist is blank (a row written around validation
    # denies rather than opening up).
    #
    # The auth chain AND-combines all three; an axis that doesn't match =
    # request denied.

    def unrestricted?
      any_axis?(node_instance_ids) &&
        any_axis?(sdwan_network_ids) &&
        any_axis?(source_cidrs)
    end

    def applies_to_instance?(instance_id)
      return true if any_axis?(node_instance_ids)
      list = axis_entries(node_instance_ids).map(&:to_s)
      return false if list.empty? || instance_id.blank?
      list.include?(instance_id.to_s)
    end

    def applies_to_network?(network_id)
      return true if any_axis?(sdwan_network_ids)
      list = axis_entries(sdwan_network_ids).map(&:to_s)
      return false if list.empty? || network_id.blank?
      list.include?(network_id.to_s)
    end

    def applies_to_source_ip?(source_ip)
      return true if any_axis?(source_cidrs)
      list = axis_entries(source_cidrs).reject(&:blank?)
      return false if list.empty? || source_ip.blank?

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

      # Resolve a presented bearer token to its FederationGrant. Only the
      # `fgs.` envelope resolves: recompute the HMAC and CONSTANT-TIME
      # compare; only a valid signature reaches the DB lookup. Secret unset,
      # any other shape, or a malformed / forged token → nil, never a 500.
      def find_by_bearer_token(token)
        return nil unless token.is_a?(String) && token.start_with?(TOKEN_PREFIX)

        resolve_signed_token(token)
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
    end

    private

    def any_axis?(value)
      value.is_a?(Array) && value == [ ANY ]
    end

    # Concrete entries of an axis. A non-array value (only reachable around
    # validation) yields none, so it denies rather than being coerced.
    def axis_entries(value)
      value.is_a?(Array) ? value.compact : []
    end

    def pessimistic_scope_changed?
      new_record? ||
        will_save_change_to_node_instance_ids? ||
        will_save_change_to_sdwan_network_ids? ||
        will_save_change_to_source_cidrs?
    end

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
    # data from landing at all. Each column is independent and must be
    # stated: `["*"]` (ANY) means unrestricted on that axis, concrete entries
    # AND-gate against the calling context, and blank is refused.
    def pessimistic_scope_arrays_well_formed
      validate_string_id_array(node_instance_ids, :node_instance_ids)
      validate_string_id_array(sdwan_network_ids, :sdwan_network_ids)
      validate_cidr_array(source_cidrs,           :source_cidrs)
    end

    def validate_string_id_array(value, field)
      return unless axis_shape_valid?(value, field)
      return if any_axis?(value)
      bad = value.reject { |id| id.is_a?(String) && id.present? && id.length <= 64 }
      return if bad.empty?
      errors.add(field, "contains invalid id entries: #{bad.first(3).inspect}")
    end

    def validate_cidr_array(value, field)
      return unless axis_shape_valid?(value, field)
      return if any_axis?(value)
      bad = value.reject { |cidr| valid_cidr?(cidr) }
      return if bad.empty?
      errors.add(field, "contains invalid CIDR entries: #{bad.first(3).inspect}")
    end

    # Blank, non-array and ANY-mixed-with-entries are refused on every axis.
    # Returns true only when the value is a non-empty array whose entries
    # still need per-axis checking (or is exactly ANY).
    def axis_shape_valid?(value, field)
      if value.nil? || value == []
        errors.add(field, "must not be blank: list the allowed #{field}, or #{[ ANY ].inspect} (ANY) " \
                          "for no restriction on this axis")
        return false
      end
      unless value.is_a?(Array)
        errors.add(field, "must be an array (got #{value.class.name})")
        return false
      end
      if value.include?(ANY) && value.size > 1
        errors.add(field, "#{ANY.inspect} (ANY) must stand alone, not be mixed with other entries")
        return false
      end
      true
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
