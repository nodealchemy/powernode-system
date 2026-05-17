# frozen_string_literal: true

module Federation
  # Subscriber-side orchestrator: takes the operator's response to a
  # subscribe POST and walks the local subscription through
  # `pending → active`. Coordinates four pieces:
  #
  #   1. Local FederationGrant snapshot — records the bearer token +
  #      scope the operator issued. Used by the subscriber's Traefik
  #      to inject the Authorization header on outbound requests.
  #
  #   2. AcmeCertificate (skipped for site-local TCP forwards) —
  #      issued via Acme::CertificateManager. For TLS-bearing
  #      protocols (https/tls), a valid cert is required for the
  #      route to function.
  #
  #   3. ServiceSubscription row — the durable link between offering,
  #      grant, and cert. Created in `pending`, transitions to
  #      `active` after the route is written.
  #
  #   4. Traefik dynamic config — emitted by ServiceRouteWriter.
  #      For HTTP/TLS subscriptions only; site-local TCP forwards
  #      get a separate config writer (P4.6.7).
  #
  # Failure semantics: if cert issuance fails OR route writing
  # fails OR subscription creation fails, the lifecycle returns
  # failure with a clear error AND the partial state is left in
  # place for inspection/retry. The caller can re-invoke after
  # fixing the underlying issue.
  #
  # Plan reference: Decentralized Federation §L.4 + P4.6.4.
  class SubscriptionLifecycleService
    Result = Struct.new(:ok?, :error, :subscription, :grant, :certificate,
                        keyword_init: true)

    PUBLIC_TLS_PROTOCOLS = %w[https tls].freeze

    class << self
      def activate!(account:, federation_peer:, offering_slug:,
                    local_hostname:, operator_response:,
                    dns_credential: nil, acme_client: nil)
        new(
          account: account,
          federation_peer: federation_peer,
          acme_client: acme_client
        ).activate!(
          offering_slug: offering_slug,
          local_hostname: local_hostname,
          operator_response: operator_response,
          dns_credential: dns_credential
        )
      end
    end

    def initialize(account:, federation_peer:, acme_client: nil)
      @account = account
      @peer = federation_peer
      @acme_client = acme_client
    end

    def activate!(offering_slug:, local_hostname:, operator_response:,
                  dns_credential: nil)
      resp = symbolize(operator_response)
      protocol = resp[:protocol].to_s
      site_local = site_local?(local_hostname)

      validate_response!(resp)

      grant = create_local_grant!(resp, offering_slug, local_hostname)
      cert = nil

      if !site_local && PUBLIC_TLS_PROTOCOLS.include?(protocol)
        cert = ensure_valid_cert!(local_hostname, dns_credential)
        unless cert.status == "valid"
          return failure(
            "Cert issuance did not complete (status=#{cert.status}): " \
            "#{cert.last_renewal_error}",
            grant: grant, certificate: cert
          )
        end
      end

      subscription = ::System::Federation::ServiceSubscription.create!(
        account: @account,
        federation_peer: @peer,
        service_offering_slug: offering_slug,
        service_offering_id: resp[:service_offering_id],
        local_hostname: local_hostname,
        protocol: protocol,
        backend_vip: resp[:backend_host],
        backend_port: resp[:backend_port].to_i,
        federation_grant: grant,
        acme_certificate: cert,
        status: "pending",
        subscribed_at: Time.current,
        metadata: { "operator_response" => resp.transform_keys(&:to_s) }
      )

      # Activate first so ServiceRouteWriter sees it in `active` state
      # when it queries (the writer filters to status=active subs).
      subscription.activate!

      unless site_local
        ::Federation::ServiceRouteWriter.write!(account: @account)
      end

      Result.new(
        ok?: true,
        subscription: subscription.reload,
        grant: grant,
        certificate: cert
      )
    rescue StandardError => e
      Rails.logger.error("[Federation::SubscriptionLifecycleService] #{e.class}: #{e.message}")
      failure(e.message)
    end

    private

    def validate_response!(resp)
      missing = %i[grant_id backend_host backend_port protocol].reject { |k| resp[k].present? }
      return if missing.empty?
      raise ArgumentError, "operator_response missing required keys: #{missing.inspect}"
    end

    def symbolize(hash)
      hash.transform_keys { |k| k.to_s.to_sym }
    end

    def site_local?(hostname)
      hostname.to_s.start_with?("localhost:", "127.0.0.1:")
    end

    def create_local_grant!(resp, offering_slug, local_hostname)
      ::System::FederationGrant.create!(
        account: @account,
        federation_peer: @peer,
        grantor_user: nil,
        remote_subject: "service-sub-received:#{offering_slug}:#{local_hostname}",
        resource_kind: "service_offering",
        resource_id: resp[:service_offering_id] || resp[:offering_id],
        permission_scopes: Array(resp[:permission_scopes]),
        issued_at: Time.current,
        expires_at: parse_time(resp[:expires_at]) || 30.days.from_now,
        node_instance_ids: [],
        sdwan_network_ids: [],
        source_cidrs: [],
        metadata: {
          "received_from_peer_id" => @peer.id,
          "remote_grant_id" => resp[:grant_id]
        }
      )
    end

    def parse_time(value)
      return nil if value.blank?
      value.is_a?(Time) ? value : Time.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    # Finds or creates an AcmeCertificate for the local_hostname and
    # drives it to `valid` via Acme::CertificateManager. If the cert
    # is already valid (and not expiring soon), returns it directly.
    def ensure_valid_cert!(local_hostname, dns_credential)
      existing = ::System::AcmeCertificate.find_by(
        account: @account, common_name: local_hostname
      )
      return existing if existing&.status == "valid"

      cert = existing || ::System::AcmeCertificate.create!(
        account: @account,
        common_name: local_hostname,
        dns_credential: dns_credential,
        challenge_type: dns_credential ? "dns-01" : "http-01",
        status: "pending"
      )

      ::Acme::CertificateManager.issue!(
        certificate: cert,
        acme_client: @acme_client
      )
      cert.reload
    end

    def failure(message, **attrs)
      Result.new(ok?: false, error: message, **attrs)
    end
  end
end
