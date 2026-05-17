# frozen_string_literal: true

module System
  # Sparse lookup mapping a platform component (api/worker/frontend/etc.)
  # to its NodeTemplate + allocated SDWAN VirtualIP. Federation peers and
  # the Sidekiq worker call `Powernode::Bootstrap.discover_peer(:api)` at
  # startup to learn what VIP to dial.
  #
  # Plan reference: Decentralized Federation §G, P2.
  class PlatformDeployment < BaseRecord
    include System::Base

    SERVICE_ROLES = %w[
      api
      worker
      frontend
      postgres
      redis
      reverse-proxy
      satellite-runtime
    ].freeze

    belongs_to :node_template, class_name: "System::NodeTemplate"
    belongs_to :virtual_ip, class_name: "Sdwan::VirtualIp", optional: true

    attribute :metadata, :jsonb, default: -> { {} }

    validates :name, presence: true, length: { maximum: 100 },
                     uniqueness: { scope: :account_id, case_sensitive: false }
    validates :service_role, inclusion: { in: SERVICE_ROLES }
    validates :target_replicas, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :public_dns_hostname, length: { maximum: 256 }, allow_nil: true
    validates :satellite_extension_slug, length: { maximum: 64 }, allow_nil: true

    scope :by_role,        ->(role) { where(service_role: role) }
    scope :with_vip,       -> { where.not(virtual_ip_id: nil) }
    scope :public_facing,  -> { where.not(public_dns_hostname: nil) }
    scope :for_satellite,  ->(slug) { where(satellite_extension_slug: slug) }
    scope :for_mainline,   -> { where(satellite_extension_slug: nil) }

    # Returns the preferred dial target for this deployment.
    # VIP wins over public DNS — VIP is overlay-routed (lower latency,
    # survives WAN outage); DNS is for bootstrap before joining the mesh.
    def preferred_endpoint
      return virtual_ip.cidr.split("/").first if virtual_ip
      public_dns_hostname
    end

    # Resolution order used by Federation::EndpointProber for federation
    # peer dialing (Plan §J Endpoint Discovery): VIP first, DNS second.
    # Returns an array of { url, scope } records, priority-ordered.
    def dial_candidates(port: nil)
      candidates = []
      if virtual_ip && (host = virtual_ip.cidr&.split("/")&.first)
        candidates << { url: scheme_and_host(host, port), scope: :sdwan }
      end
      if public_dns_hostname
        candidates << { url: scheme_and_host(public_dns_hostname, port), scope: :wan }
      end
      candidates
    end

    private

    def scheme_and_host(host, port)
      port_segment = port ? ":#{port}" : ""
      "https://#{host}#{port_segment}"
    end
  end
end
