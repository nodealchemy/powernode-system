# frozen_string_literal: true

module System
  module Federation
    # Subscriber-side record of consumption of a remote operator's
    # ServiceOffering. Created via federation_api/subscriptions POST;
    # the operator issues a FederationGrant + the subscriber's local
    # Traefik gets a route + ACME cert.
    #
    # Lifecycle:
    #   pending   — subscription created; grant issued; waiting for
    #                cert issuance + Traefik route to land
    #   active    — cert issued + route active; serving traffic
    #   suspended — operator paused access (no traffic); subscription
    #                preserved for re-activation
    #   cancelled — terminal; grant revoked; cert + route removed
    #
    # Plan reference: Decentralized Federation §L + P4.6.
    class ServiceSubscription < ApplicationRecord
      self.table_name = "system_federation_service_subscriptions"

      PROTOCOLS = %w[https http tcp tls].freeze
      STATUSES  = %w[pending active suspended cancelled].freeze
      TERMINAL_STATUSES = %w[cancelled].freeze

      TRANSITIONS = {
        "pending"   => %w[active cancelled],
        "active"    => %w[suspended cancelled],
        "suspended" => %w[active cancelled],
        "cancelled" => []
      }.freeze

      belongs_to :account
      belongs_to :federation_peer,
                 class_name: "::System::FederationPeer",
                 foreign_key: :federation_peer_id
      belongs_to :federation_grant,
                 class_name: "::System::FederationGrant",
                 foreign_key: :federation_grant_id
      belongs_to :acme_certificate,
                 class_name: "::System::AcmeCertificate",
                 foreign_key: :acme_certificate_id,
                 optional: true

      attribute :metadata, :jsonb, default: -> { {} }

      validates :service_offering_slug, presence: true, length: { maximum: 64 }
      validates :local_hostname, presence: true, length: { maximum: 255 }
      validates :protocol, inclusion: { in: PROTOCOLS }
      validates :status, inclusion: { in: STATUSES }
      validates :backend_port, presence: true,
                               numericality: { only_integer: true, in: 1..65_535 }
      validates :local_hostname, uniqueness: { scope: :account_id }

      validate :site_local_skips_cert
      validate :public_protocol_requires_cert

      scope :active_subscriptions, -> { where(status: "active") }
      scope :live, -> { where(status: %w[pending active suspended]) }
      scope :terminal, -> { where(status: TERMINAL_STATUSES) }
      scope :for_peer, ->(peer) { where(federation_peer_id: peer.id) }
      scope :for_slug, ->(slug) { where(service_offering_slug: slug) }

      def can_transition_to?(new_status)
        TRANSITIONS.fetch(status, []).include?(new_status.to_s)
      end

      def activate!
        return false unless can_transition_to?("active")
        update!(status: "active", activated_at: Time.current)
      end

      def suspend!(reason: nil)
        return false unless can_transition_to?("suspended")
        update!(
          status: "suspended",
          suspended_at: Time.current,
          metadata: metadata.merge("suspension_reason" => reason.to_s.presence)
        )
      end

      def cancel!(reason: nil)
        return false unless can_transition_to?("cancelled")
        update!(
          status: "cancelled",
          cancelled_at: Time.current,
          metadata: metadata.merge("cancellation_reason" => reason.to_s.presence)
        )
      end

      # True when local_hostname targets the loopback interface for
      # site-local TCP forwarding (e.g. "localhost:5432" or
      # "127.0.0.1:6379"). These subscriptions don't need a public
      # cert — traffic stays inside the box.
      def site_local?
        return false if local_hostname.blank?
        local_hostname.start_with?("localhost:", "127.0.0.1:")
      end

      def terminal?
        TERMINAL_STATUSES.include?(status)
      end

      private

      # Site-local subscriptions (TCP forwards via powernode-tcp-forwarder)
      # do NOT have an acme_certificate — traffic never crosses a TLS
      # boundary. Enforce that the association is nil for these.
      # Checks both FK and association so `build`-created records (which
      # have a non-nil association but nil FK) are validated correctly.
      def site_local_skips_cert
        return unless site_local?
        return if acme_certificate_id.nil? && acme_certificate.nil?
        errors.add(:acme_certificate_id, "must be nil for site-local hostnames")
      end

      # Public-protocol subscriptions (https/tls) MUST have a cert —
      # without one, Traefik can't terminate TLS for local_hostname.
      # Checks the association (not just the FK) so `build`-created
      # records with an unpersisted cert pass validation.
      def public_protocol_requires_cert
        return unless %w[https tls].include?(protocol)
        return if site_local?
        return if acme_certificate.present? || acme_certificate_id.present?
        errors.add(:acme_certificate_id, "is required for #{protocol} subscriptions")
      end
    end
  end
end
