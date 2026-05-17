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
    # `Authorization: Bearer fg-<grant_id>`. v1 uses the grant_id directly
    # (cryptographically random UUIDv7); a future round may add an
    # HMAC-signed JWT envelope so the remote peer can't forge by guessing.
    def bearer_token
      "fg-#{id}"
    end

    class << self
      def find_by_bearer_token(token)
        return nil unless token.is_a?(String) && token.start_with?("fg-")
        id = token.sub(/\Afg-/, "")
        find_by(id: id)
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
