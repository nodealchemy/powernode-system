# frozen_string_literal: true

module System
  module Federation
    # Operator-side catalog entry for a service the platform offers
    # to federated subscribers. Subscribers browse offerings via
    # federation_api/service_catalog and consume via
    # federation_api/subscriptions.
    #
    # Lifecycle:
    #   draft     — operator is building; not yet visible to subscribers
    #   active    — visible in catalog; accepting new subscriptions
    #   deprecated — visible (with deprecation notice); rejects new subs;
    #                existing subscriptions continue to be served
    #   retired   — terminal; access revoked after 30-day grace period
    #               (Social Contract #4: Notification on revocation)
    #
    # Plan reference: Decentralized Federation §L + P4.6.
    class ServiceOffering < ApplicationRecord
      self.table_name = "system_federation_service_offerings"

      PROTOCOLS = %w[https http tcp tls].freeze
      STATUSES  = %w[draft active deprecated retired].freeze
      TERMINAL_STATUSES = %w[retired].freeze

      TRANSITIONS = {
        "draft"      => %w[active retired],
        "active"     => %w[deprecated retired],
        "deprecated" => %w[active retired],
        "retired"    => []
      }.freeze

      # Minimum grant TTL (matches Architectural Fix 2 — Grant TTL +
      # soft-delete + archival). Per-offering default may exceed this.
      MIN_GRANT_TTL_DAYS = 7

      belongs_to :account
      belongs_to :backend_vip, class_name: "::Sdwan::VirtualIp",
                                foreign_key: :backend_vip_id, optional: true
      has_many :service_subscriptions,
               class_name: "System::Federation::ServiceSubscription",
               foreign_key: :service_offering_id,
               primary_key: :id,
               dependent: :restrict_with_error

      attribute :capacity_metadata,     :jsonb, default: -> { {} }
      attribute :latency_metadata,      :jsonb, default: -> { {} }
      attribute :default_grant_scopes,  :jsonb, default: -> { [ "read" ] }
      attribute :metadata,              :jsonb, default: -> { {} }

      validates :slug, presence: true, length: { maximum: 64 },
                       format: { with: /\A[a-z0-9][a-z0-9-]*\z/,
                                 message: "must be lowercase alphanumeric with hyphens" }
      validates :slug, uniqueness: { scope: :account_id }
      validates :name, presence: true, length: { maximum: 255 }
      validates :protocol, inclusion: { in: PROTOCOLS }
      validates :status, inclusion: { in: STATUSES }
      validates :backend_port, presence: true,
                               numericality: { only_integer: true, in: 1..65_535 }
      validates :default_grant_ttl_days, numericality: {
        only_integer: true, greater_than_or_equal_to: MIN_GRANT_TTL_DAYS
      }

      validate :backend_address_present
      validate :default_grant_scopes_valid

      scope :active_offerings,     -> { where(status: "active") }
      scope :catalog_listed,       -> { where(status: %w[active deprecated]) }
      scope :accepting_new_subscriptions, -> { where(status: "active") }
      scope :terminal,             -> { where(status: TERMINAL_STATUSES) }
      scope :by_protocol,          ->(p) { where(protocol: p) }

      def can_transition_to?(new_status)
        TRANSITIONS.fetch(status, []).include?(new_status.to_s)
      end

      def activate!
        return false unless can_transition_to?("active")
        update!(status: "active", deprecated_at: nil)
      end

      def deprecate!(reason: nil)
        return false unless can_transition_to?("deprecated")
        update!(
          status: "deprecated",
          deprecated_at: Time.current,
          metadata: metadata.merge("deprecation_reason" => reason.to_s.presence)
        )
      end

      def retire!(reason: nil)
        return false unless can_transition_to?("retired")
        update!(
          status: "retired",
          retired_at: Time.current,
          metadata: metadata.merge("retirement_reason" => reason.to_s.presence)
        )
      end

      def accepting_subscriptions?
        status == "active" && !at_capacity?
      end

      def terminal?
        TERMINAL_STATUSES.include?(status)
      end

      # Capacity check using the `max_subscribers` key in capacity_metadata.
      # Nil/absent means uncapped.
      def at_capacity?
        cap = capacity_metadata["max_subscribers"] || capacity_metadata[:max_subscribers]
        return false if cap.nil?
        service_subscriptions.where(status: %w[pending active]).count >= cap.to_i
      end

      def active_subscription_count
        service_subscriptions.where(status: "active").count
      end

      private

      # Either backend_vip_id (preferred — VIP failover) or backend_host
      # (static fallback) must be set. Both nil = invalid offering.
      def backend_address_present
        return if backend_vip_id.present? || backend_host.present?
        errors.add(:backend_host, "must be set when backend_vip_id is absent")
      end

      # default_grant_scopes must be an array of valid scope strings.
      # The set of recognized scopes mirrors FederationGrant permission_scopes.
      def default_grant_scopes_valid
        scopes = default_grant_scopes
        unless scopes.is_a?(Array)
          errors.add(:default_grant_scopes, "must be an array")
          return
        end
        bad = scopes - %w[read write admin migrate]
        return if bad.empty?
        errors.add(:default_grant_scopes, "contains unknown scopes: #{bad.inspect}")
      end
    end
  end
end
