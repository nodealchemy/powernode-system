# frozen_string_literal: true

module Sdwan
  # First-class publishable service: identity + overlay backend + an optional
  # LOCAL-exposure facet (/svc/<slug> on the account's own host via the bundled
  # Traefik, gated by ForwardAuth). The FEDERATED facet is
  # System::Federation::ServiceOffering (belongs_to :service); federated peers
  # consume it via Federation::ServiceRouteWriter on their side. The local plane
  # is emitted by Sdwan::ServiceExposureWriter on this side. Backend is
  # VIP-backed so Traefik dials the service over the overlay (no loopback hop).
  class Service < ApplicationRecord
    self.table_name = "sdwan_services"

    PROTOCOLS  = %w[https http tcp tls].freeze
    STATUSES   = %w[active disabled].freeze
    AUTH_MODES = %w[public authenticated scoped].freeze
    HTTP_PROTOCOLS = %w[https http].freeze
    # Platform router prefixes a published service must never alias — /svc/<slug>
    # is namespaced, but guard the slug too so it can't round-trip to one.
    RESERVED_SLUGS = %w[api agent cable sidekiq svc].freeze
    SLUG_FORMAT = /\A[a-z0-9][a-z0-9-]{0,62}\z/

    belongs_to :account
    belongs_to :backend_vip, class_name: "::Sdwan::VirtualIp",
               foreign_key: :backend_vip_id, optional: true
    belongs_to :local_certificate, class_name: "System::AcmeCertificate",
               foreign_key: :local_certificate_id, optional: true

    validates :slug, presence: true, length: { maximum: 64 },
                     format: { with: SLUG_FORMAT,
                               message: "must be lowercase alphanumeric with hyphens" },
                     uniqueness: { scope: :account_id }
    validates :name, presence: true, length: { maximum: 255 }
    validates :protocol, inclusion: { in: PROTOCOLS }
    validates :status, inclusion: { in: STATUSES }
    validates :backend_port, presence: true,
                             numericality: { only_integer: true, in: 1..65_535 }
    validates :local_auth_mode, inclusion: { in: AUTH_MODES }
    validate :slug_not_reserved
    validate :backend_present
    validate :local_exposure_requires_http
    validate :scoped_requires_permission_or_group
    validate :local_certificate_belongs_to_account

    scope :active,          -> { where(status: "active") }
    scope :locally_exposed, -> { where(status: "active", local_enabled: true) }

    # Canonical local path prefix. /svc/ namespaces published services so they
    # never collide with the platform routers (/api, /cable, /sidekiq, /agent).
    def local_path_prefix
      "/svc/#{slug}"
    end

    # Deterministic Traefik router/service key for the local exposure.
    def local_router_slug
      "localsvc-#{id}"
    end

    # The upstream URL Traefik dials over the overlay (IPv6 hosts bracketed for
    # the URL authority). Scheme defaults to the service protocol.
    def backend_url(scheme: protocol)
      host = backend_address.to_s
      host = "[#{host}]" if host.include?(":") && !host.start_with?("[")
      "#{scheme}://#{host}:#{backend_port}"
    end

    # The overlay address (VIP host or static host) without scheme/port.
    def backend_address
      return backend_vip.cidr.to_s.split("/").first if backend_vip

      backend_host
    end

    private

    def slug_not_reserved
      return if slug.blank?

      errors.add(:slug, "is reserved") if RESERVED_SLUGS.include?(slug)
    end

    def backend_present
      return if backend_vip_id.present? || backend_host.present?

      errors.add(:base, "a backend_vip or backend_host must be set")
    end

    # /svc/<slug> path routing is HTTP-only (you can't PathPrefix-route raw TCP).
    # TCP/TLS services can still be federated (HostSNI), just not locally exposed.
    def local_exposure_requires_http
      return unless local_enabled
      return if HTTP_PROTOCOLS.include?(protocol)

      errors.add(:local_enabled, "local /svc path exposure requires an http or https protocol")
    end

    def scoped_requires_permission_or_group
      return unless local_auth_mode == "scoped"
      return if local_required_permission.present? || local_required_group.present?

      errors.add(:base, "scoped local exposure requires a permission or group")
    end

    def local_certificate_belongs_to_account
      return if local_certificate.nil? || local_certificate.account_id == account_id

      errors.add(:local_certificate_id, "must belong to the same account")
    end
  end
end
