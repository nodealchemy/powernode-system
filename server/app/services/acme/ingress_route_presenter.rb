# frozen_string_literal: true

module Acme
  # Read-only projection of the reverse-proxy routes derived from a single
  # System::AcmeCertificate row. Powers GET /api/v1/system/ingress_routes.
  #
  # SOURCE OF TRUTH for the derived router metadata + host matcher is
  # Acme::TraefikConfigWriter (the write path). This presenter calls into
  # TraefikConfigWriter.routers_for / .host_rule_for so the routes reported to
  # operators are byte-for-byte the routes Traefik actually serves — the read
  # and write paths can never drift. This class adds only read-side concerns:
  # cert status/expiry metadata, the `active` flag, and the public-endpoint
  # convenience list. It performs NO writes, NO filesystem access, and touches
  # NO AR associations (every field comes off the cert row itself).
  class IngressRoutePresenter
    # `backend_url:`/`frontend_url:`/`worker_web_url:`/`extra_hosts:` are the
    # env-derived values the writer would otherwise read per-router/per-cert.
    # IngressRoutesController computes them ONCE per request and threads them in
    # so a multi-cert index request parses the env 4x total instead of ~13x per
    # cert. When omitted, the writer's class methods read the env themselves
    # (single-cert callers).
    def initialize(certificate, backend_url: nil, frontend_url: nil, worker_web_url: nil, extra_hosts: nil)
      @cert = certificate
      @backend_url    = backend_url    || ::Acme::TraefikConfigWriter.backend_url
      @frontend_url   = frontend_url   || ::Acme::TraefikConfigWriter.frontend_url
      @worker_web_url = worker_web_url || ::Acme::TraefikConfigWriter.worker_web_url
      @extra_hosts    = extra_hosts    || ::Acme::TraefikConfigWriter.extra_hosts
    end

    def self.project(certificate, backend_url: nil, frontend_url: nil, worker_web_url: nil, extra_hosts: nil)
      new(certificate,
          backend_url: backend_url,
          frontend_url: frontend_url,
          worker_web_url: worker_web_url,
          extra_hosts: extra_hosts).as_json
    end

    def as_json
      {
        id:                @cert.id,
        common_name:       @cert.common_name,
        sans:              @cert.sans || [],
        host_rule:         host_rule,
        status:            @cert.status,
        active:            @cert.status == "valid",
        issuer:            @cert.issuer,
        issued_at:         @cert.issued_at&.iso8601,
        expires_at:        @cert.expires_at&.iso8601,
        days_until_expiry: days_until_expiry,
        routers:           routers,
        public_endpoints:  public_endpoints
      }
    end

    private

    # Mirrors the Traefik host matcher the writer emits for this cert.
    def host_rule
      ::Acme::TraefikConfigWriter.host_rule_for(@cert.common_name, extra_hosts: @extra_hosts)
    end

    # The 10 derived Traefik routers for this cert, straight from the writer's
    # shared projection (name, path_prefix, backend_service, backend_url,
    # entrypoint, tls_resolver). The frontend catchall carries path_prefix nil.
    def routers
      ::Acme::TraefikConfigWriter.routers_for(@cert,
                                              backend_url: @backend_url,
                                              frontend_url: @frontend_url,
                                              worker_web_url: @worker_web_url)
    end

    # Convenience list of the public HTTPS endpoints this cert serves: the
    # common_name plus any operator-configured extra hosts.
    def public_endpoints
      hosts = [ @cert.common_name ] + @extra_hosts
      hosts.compact.uniq.map { |h| "https://#{h}/" }
    end

    # floor((expires_at - now) / 1.day); nil when the cert has no expiry.
    def days_until_expiry
      return nil unless @cert.expires_at
      ((@cert.expires_at - Time.current) / 1.day).floor
    end
  end
end
