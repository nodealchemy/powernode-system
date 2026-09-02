# frozen_string_literal: true

module Sdwan
  # First-class publishable service: identity + overlay backend + two optional
  # exposure facets. LOCAL (/svc/<slug> on the account's own host via the
  # bundled Traefik, gated by ForwardAuth, HTTP(S)-only). PUBLIC (Path B —
  # `public_enabled`: a public HostSNI tcp.router on the SAME websecure
  # entrypoint, TLS-carrying-TCP-only i.e. `protocol == "tls"`; `edge_mode`
  # passthrough/terminate + `client_auth` none/required, ratified in
  # docs/operations/reverse-proxy.md + docs/runbooks/traefik-tcp-exposure-vs-dnat.md).
  # The FEDERATED facet is System::Federation::ServiceOffering (belongs_to
  # :service); federated peers consume it via Federation::ServiceRouteWriter on
  # their side. Both the local and public facets are emitted by
  # Sdwan::ServiceExposureWriter on this side. Backend is VIP-backed so Traefik
  # dials the service over the overlay (no loopback hop).
  class Service < ApplicationRecord
    self.table_name = "system_sdwan_services"

    PROTOCOLS  = %w[https http tcp tls].freeze
    STATUSES   = %w[active disabled].freeze
    AUTH_MODES = %w[public authenticated scoped].freeze
    # Service-level connectivity health, stamped by
    # System::Fleet::Sensors::SdwanServiceHealthSensor (IMP-c7d663f24a0b).
    # "unknown" is the honest default and the only state a service can hold
    # before IPFIX telemetry has been correlated to it — it is deliberately
    # NOT "serving", because an unobserved service is not a healthy one.
    #
    # "unobservable" is a DIFFERENT claim from "unknown" and the distinction is
    # the point: unknown means "no data yet, ask again next tick"; unobservable
    # means "this backend can never be correlated" — a backend_host holding a
    # hostname rather than an address, which cannot be matched against the
    # inet-typed flow records at all. Collapsing the two would hide a
    # permanently unmeasurable service inside the transient state.
    HEALTH_STATES = %w[unknown serving silent unobservable].freeze
    HTTP_PROTOCOLS = %w[https http].freeze
    # Path B (public TLS-carrying TCP via Traefik SNI) requires a protocol that
    # actually carries a TLS ClientHello with SNI. Plain "tcp" does not — that
    # traffic stays on nftables DNAT permanently (increment 6), never Traefik.
    SNI_PROTOCOL = "tls"
    EDGE_MODES = %w[passthrough terminate].freeze
    CLIENT_AUTH_MODES = %w[none required].freeze
    # Platform router prefixes a published service must never alias — /svc/<slug>
    # is namespaced, but guard the slug too so it can't round-trip to one.
    RESERVED_SLUGS = %w[api agent cable sidekiq svc].freeze
    SLUG_FORMAT = /\A[a-z0-9][a-z0-9-]{0,62}\z/

    belongs_to :account
    belongs_to :backend_vip, class_name: "::Sdwan::VirtualIp",
               foreign_key: :backend_vip_id, optional: true
    belongs_to :local_certificate, class_name: "System::AcmeCertificate",
               foreign_key: :local_certificate_id, optional: true
    # APO-3c load-balanced backend set. Empty for every service nobody has
    # scaled — see #load_balanced_backends for why that stays the norm.
    has_many :backends, class_name: "::Sdwan::ServiceBackend",
             foreign_key: :sdwan_service_id, inverse_of: :service, dependent: :destroy

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
    validates :health_state, inclusion: { in: HEALTH_STATES }
    validates :edge_mode, inclusion: { in: EDGE_MODES }
    validates :client_auth, inclusion: { in: CLIENT_AUTH_MODES }
    validate :slug_not_reserved
    validate :backend_present
    validate :local_exposure_requires_http
    validate :public_exposure_requires_sni
    validate :client_auth_requires_terminate
    validate :scoped_requires_permission_or_group
    validate :local_certificate_belongs_to_account

    scope :active,          -> { where(status: "active") }
    scope :locally_exposed, -> { where(status: "active", local_enabled: true) }
    scope :publicly_exposed, -> { where(status: "active", public_enabled: true) }
    scope :silent,          -> { where(health_state: "silent") }

    # Canonical local path prefix. /svc/ namespaces published services so they
    # never collide with the platform routers (/api, /cable, /sidekiq, /agent).
    def local_path_prefix
      "/svc/#{slug}"
    end

    # Deterministic Traefik router/service key for the local exposure.
    def local_router_slug
      "localsvc-#{id}"
    end

    # Deterministic Traefik tcp.router/service key for the public (Path B)
    # TLS-carrying TCP exposure. Distinct namespace from local_router_slug
    # ("localsvc-") and federation's "sub-" so the three never collide.
    def public_router_slug
      "pubsvc-#{id}"
    end

    # The upstream URL Traefik dials over the overlay (IPv6 hosts bracketed for
    # the URL authority). Scheme defaults to the service protocol.
    def backend_url(scheme: protocol)
      "#{scheme}://#{::Sdwan::HostPort.join(backend_address, backend_port)}"
    end

    # The overlay address (VIP host or static host) without scheme/port.
    def backend_address
      return backend_vip.cidr.to_s.split("/").first if backend_vip

      backend_host
    end

    # The effective backend set Sdwan::ServiceExposureWriter load-balances
    # across (APO-3c). Always at least one member.
    #
    # A service with no ACTIVE Sdwan::ServiceBackend row — which is every
    # service that predates the backend set, and every service nobody has
    # scaled — resolves to its legacy backend_vip/backend_host + backend_port
    # columns wrapped in LegacyBackend, so the writer has exactly one code path
    # and the degenerate output stays byte-identical to what it emitted before
    # any of this existed.
    #
    # Emission order is (created_at, id): Traefik file-watches the dynamic dir
    # and reloads on every write, so a set whose order churns between writes
    # rewrites the file (and reshuffles the round-robin ring) for no reason.
    # created_at first so the set reads in the order it was scaled up; id as the
    # tiebreak because two replicas provisioned in one batch can share a
    # timestamp.
    #
    # Filtering and ordering happen in Ruby, not SQL, on purpose: the writer
    # eager-loads `:backends`, and a scoped/ordered association call would issue
    # a fresh query per service and defeat that (N+1 across every exposed
    # service in the account).
    def load_balanced_backends
      explicit = backends.select { |backend| backend.status == "active" }
                         .sort_by { |backend| [ backend.created_at || Time.at(0), backend.id.to_s ] }
      return explicit if explicit.any?

      [ LegacyBackend.new(self) ]
    end

    # Gives the pre-backend-set columns the same interface as an
    # Sdwan::ServiceBackend row (#address / #backend_port / #weight / #url) so
    # no consumer has to branch on "does this service have a backend set".
    LegacyBackend = Struct.new(:service) do
      def address
        service.backend_address
      end

      def backend_port
        service.backend_port
      end

      def weight
        ::Sdwan::ServiceBackend::DEFAULT_WEIGHT
      end

      def url(scheme:)
        service.backend_url(scheme: scheme)
      end
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

    # Path B (public TLS-carrying TCP) only ever rides Traefik SNI routing —
    # that requires the traffic to present a TLS ClientHello with SNI before
    # Traefik can route it. Plain "tcp" (no SNI) and everything else stays on
    # nftables DNAT (Sdwan::PortMapping, increment 6) permanently; it is never
    # eligible for public_enabled here.
    def public_exposure_requires_sni
      return unless public_enabled
      return if protocol == SNI_PROTOCOL

      errors.add(:public_enabled,
                 "public TLS-carrying TCP exposure requires the tls protocol (SNI-routable); " \
                 "non-SNI tcp belongs on Sdwan::PortMapping/nftables DNAT instead")
    end

    # mTLS client-cert enforcement at the Traefik edge only works when Traefik
    # actually terminates the TLS connection — a "passthrough" router forwards
    # the encrypted stream untouched, so Traefik never sees (and cannot verify)
    # a client certificate on that path.
    def client_auth_requires_terminate
      return if client_auth == "none"
      return if edge_mode == "terminate"

      errors.add(:client_auth,
                 "required client-cert enforcement needs edge_mode terminate " \
                 "(Traefik cannot inspect a client certificate on an undecrypted passthrough stream)")
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
