# frozen_string_literal: true

module Federation
  # Operator-side service for the catalog + subscription handshake.
  #
  # Two responsibilities:
  #   1. `list_active_offerings(account:)` — exposes the catalog as
  #      seen by a remote subscriber. Returns active + deprecated
  #      offerings (deprecated stays visible with a deprecation notice;
  #      `accepting_subscriptions?` filters the actually-subscribable
  #      subset for the subscribe step).
  #
  #   2. `issue_subscription!(...)` — handles an incoming subscribe POST
  #      from a federated peer. Validates offering availability +
  #      capacity, issues a FederationGrant scoped to the offering,
  #      and returns the connection details the subscriber's local
  #      Traefik needs to materialize its route.
  #
  # The SUBSCRIBER-SIDE row (`ServiceSubscription`) is not created here
  # — that's the subscriber's local concern, materialized by
  # `Federation::SubscriptionLifecycleService.activate!` (P4.6.4) after
  # the operator's response lands.
  #
  # Plan reference: Decentralized Federation §L + P4.6.2.
  class ServiceCatalogService
    class CatalogError < StandardError; end

    Result = Struct.new(:ok?, :error, :grant, :offering, :connection,
                        keyword_init: true)

    class << self
      def list_active_offerings(account:)
        ::System::Federation::ServiceOffering
          .where(account: account)
          .catalog_listed
          .order(:name)
      end

      def issue_subscription!(account:, offering_slug:, requesting_peer:,
                              local_hostname:, ttl_days: nil)
        new.issue_subscription!(
          account: account,
          offering_slug: offering_slug,
          requesting_peer: requesting_peer,
          local_hostname: local_hostname,
          ttl_days: ttl_days
        )
      end
    end

    def issue_subscription!(account:, offering_slug:, requesting_peer:,
                            local_hostname:, ttl_days: nil)
      offering = ::System::Federation::ServiceOffering.find_by(
        account: account, slug: offering_slug
      )
      return failure("Unknown offering: #{offering_slug}") unless offering

      unless offering.status == "active"
        return failure("Offering #{offering_slug.inspect} not accepting new " \
                       "subscriptions (status=#{offering.status})")
      end

      if offering.at_capacity?
        return failure("Offering #{offering_slug.inspect} at capacity " \
                       "(#{offering.capacity_metadata['max_subscribers']} max)")
      end

      grant = issue_grant!(offering, requesting_peer, local_hostname, ttl_days)

      Result.new(
        ok?: true,
        offering: offering,
        grant: grant,
        connection: {
          grant_id: grant.id,
          backend_host: backend_address_for(offering),
          backend_port: offering.backend_port,
          protocol: offering.protocol,
          expires_at: grant.expires_at.iso8601,
          ttl_seconds: (grant.expires_at - Time.current).to_i
        }
      )
    rescue ActiveRecord::RecordInvalid => e
      failure("Invalid subscription request: #{e.message}")
    rescue StandardError => e
      Rails.logger.error("[Federation::ServiceCatalogService] #{e.class}: #{e.message}")
      failure(e.message)
    end

    private

    def issue_grant!(offering, peer, local_hostname, ttl_days_override)
      ttl_days = (ttl_days_override || offering.default_grant_ttl_days).to_i
      min_ttl = ::System::Federation::ServiceOffering::MIN_GRANT_TTL_DAYS
      ttl_days = min_ttl if ttl_days < min_ttl

      # Compose a stable remote_subject per (peer, offering, local_hostname).
      # Same peer subscribing the same offering twice with different hostnames
      # gets distinct grant rows (legitimate; one peer can serve multiple
      # local domains from the same operator's service).
      remote_subject = "service-sub:#{offering.slug}:#{local_hostname}@peer-#{peer.id}"

      ::System::FederationGrant.create!(
        account: offering.account,
        federation_peer: peer,
        grantor_user: nil,  # System-issued — operator implicitly authorizes via the catalog
        remote_subject: remote_subject,
        resource_kind: "service_offering",
        resource_id: offering.id,
        permission_scopes: offering.default_grant_scopes,
        issued_at: Time.current,
        expires_at: ttl_days.days.from_now,
        node_instance_ids: [],
        sdwan_network_ids: [],
        source_cidrs: []
      )
    end

    def backend_address_for(offering)
      # Prefer VIP if configured (failover-aware); fall back to host string.
      if offering.backend_vip_id.present? && offering.backend_vip.present?
        # Sdwan::VirtualIp.address gives the routable IP for the VIP.
        offering.backend_vip.try(:address) || offering.backend_host
      else
        offering.backend_host
      end
    end

    def failure(message)
      Result.new(ok?: false, error: message)
    end
  end
end
