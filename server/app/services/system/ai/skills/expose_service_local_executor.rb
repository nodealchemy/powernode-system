# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Skill: expose a backend service on the platform's OWN host(s) at a
      # friendly `/svc/<slug>` path, gated by ForwardAuth.
      #
      # North-star orchestrator #2 (the LOCAL sibling of
      # ExposeServicePubliclyExecutor). Where the public skill publishes a
      # service to the open internet via a VIP + hub DNAT + ACME cert, this
      # skill publishes it to the site's own authenticated users — no new
      # cert, no new public port. It is the operator-facing front door to the
      # `Sdwan::Service` local-exposure facet:
      #
      #   1. Resolve-or-create the Sdwan::Service (identity + overlay backend).
      #   2. Flip on its local-exposure facet (local_enabled + auth mode +
      #      optional scoped permission/group + strip-prefix + host cert).
      #   3. Regenerate the account's `local-services-<account>.yaml` via
      #      Sdwan::ServiceExposureWriter — Traefik file-watches and reloads,
      #      so the `/svc/<slug>` router comes online with no restart.
      #
      # Approval-gated (`requires_approval: true`): turning a backend into a
      # reachable endpoint is an exposure action, same risk class as the
      # public expose + ACME issuance skills.
      #
      # Idempotent: re-running with the same slug (or a service_id) updates the
      # existing service in place rather than piling up duplicates. The model's
      # own validations (reserved-slug guard, backend-present, scoped-requires-
      # permission-or-group, cert-belongs-to-account) are the safety floor —
      # this skill surfaces their messages as `failure(...)` rather than
      # re-implementing them.
      class ExposeServiceLocalExecutor < BaseSkillExecutor
        PROTOCOLS  = ::Sdwan::Service::HTTP_PROTOCOLS
        AUTH_MODES = ::Sdwan::Service::AUTH_MODES

        skill_descriptor(
          name: "expose_service_local",
          description: "Expose a backend service locally at a friendly /svc/<slug> path on the platform's own host(s), authenticated by the reverse proxy (ForwardAuth). Use this when an operator asks to 'publish <service> for our users', 'put <backend> behind /svc/<name> with login', or otherwise make an overlay/internal service reachable to the site's own authenticated users (NOT the public internet — use expose_service_publicly for that). Creates or updates the Sdwan::Service, enables its local-exposure facet, and regenerates the reverse proxy.",
          category: "devops",
          requires_approval: true,
          inputs: {
            service_id:          { type: "string",  required: false,
                                   description: "Existing Sdwan::Service id to expose (omit to create a new service from the fields below)" },
            slug:                { type: "string",  required: false,
                                   description: "URL slug for the /svc/<slug> mount (required when creating; lowercase alnum + hyphen, <=64, not a reserved platform path)" },
            name:                { type: "string",  required: false,
                                   description: "Human-friendly service name (required when creating)" },
            protocol:            { type: "string",  required: false, default: "https",
                                   description: "Backend protocol Traefik connects with: https or http (default https)" },
            backend_vip_id:      { type: "string",  required: false,
                                   description: "Sdwan::VirtualIp id of the overlay backend (provide this or backend_host when creating)" },
            backend_host:        { type: "string",  required: false,
                                   description: "Static backend host/IP if not using a VIP (provide this or backend_vip_id when creating)" },
            backend_port:        { type: "integer", required: false,
                                   description: "Backend service port (required when creating; 1-65535)" },
            auth_mode:           { type: "string",  required: false, default: "authenticated",
                                   description: "public (no auth) | authenticated (any valid platform user) | scoped (requires a permission or group)" },
            required_permission: { type: "string",  required: false,
                                   description: "Permission name required for scoped mode (e.g. services.grafana.view)" },
            required_group:      { type: "string",  required: false,
                                   description: "Group/role name required for scoped mode (used when no required_permission is given)" },
            strip_prefix:        { type: "boolean", required: false, default: true,
                                   description: "Strip /svc/<slug> before proxying so the backend sees '/' (default true; advertises X-Forwarded-Prefix)" },
            certificate_id:      { type: "string",  required: false,
                                   description: "System::AcmeCertificate id whose CN the /svc/<slug> router mounts under (default: the account's primary valid cert)" }
          },
          outputs: {
            service_id:         :string,
            slug:               :string,
            name:               :string,
            local_path:         :string,
            local_url:          :string,
            auth_mode:          :string,
            host:               :string,
            local_services_path: :string,
            routes_configured:  :integer,
            created:            :boolean
          }
        )

        # HIER-P2D: owned by the Ingress Manager (its system.expose_service_* row
        # gates this executor when run as that agent); System Concierge keeps the
        # operator-chat door and its approval card.
        binds_to "ingress_manager", "concierge"

        protected

        def perform(service_id: nil, slug: nil, name: nil, protocol: "https",
                    backend_vip_id: nil, backend_host: nil, backend_port: nil,
                    auth_mode: "authenticated", required_permission: nil, required_group: nil,
                    strip_prefix: true, certificate_id: nil, **_extra)
          service, created = resolve_or_build_service(
            service_id: service_id, slug: slug, name: name, protocol: protocol,
            backend_vip_id: backend_vip_id, backend_host: backend_host, backend_port: backend_port
          )
          return service if service.is_a?(Hash) # early failure(...)

          apply_local_facet!(service,
                             auth_mode: auth_mode, required_permission: required_permission,
                             required_group: required_group, strip_prefix: strip_prefix,
                             certificate_id: certificate_id)
          service.save!

          regen = ::Sdwan::ServiceExposureWriter.write!(account: @account)
          if regen[:skipped_service_ids]&.include?(service.id)
            # The facet flip is already persisted (idempotent — a later retry
            # once a cert exists picks up from here), but the writer silently
            # dropped this service's router (no resolvable host/cert), so it
            # is NOT reachable. Reporting success here would be exactly the
            # soft-fail-into-success bug this skill's sibling public-exposure
            # executor guards against for its own hard requirements.
            return failure(
              "service saved but not reachable: no valid certificate/host resolvable for " \
              "/svc/#{service.slug} (provision a certificate for this account, or pass " \
              "certificate_id, then retry)"
            )
          end
          # The writer's SECOND silent-drop reason (IMP-0c10b9fd5596): every
          # declared backend is draining, so no router was emitted rather than
          # one with an empty `servers` list. Same soft-fail-into-success bug
          # as the branch above, one key over — the facet is persisted, the
          # service is not reachable, and success here would report a
          # local_url nothing answers on.
          if regen[:drained_service_ids]&.include?(service.id)
            return failure(
              "service saved but not reachable: every backend of /svc/#{service.slug} is draining " \
              "— re-activate a member (system_set_service_backends) then retry"
            )
          end
          host = resolve_host(service)

          success(
            service_id: service.id,
            slug: service.slug,
            name: service.name,
            local_path: service.local_path_prefix,
            local_url: host ? "https://#{host}#{service.local_path_prefix}" : nil,
            auth_mode: service.local_auth_mode,
            host: host,
            local_services_path: regen[:output_path],
            routes_configured: regen[:route_count],
            created: created
          )
        rescue ActiveRecord::RecordInvalid => e
          failure(e.record.errors.full_messages.join("; "))
        rescue ::Sdwan::ServiceExposureWriter::WriteError => e
          failure("reverse-proxy regen failed: #{e.message}")
        end

        private

        # Returns [service, created_bool] on success, or a failure(...) Hash.
        def resolve_or_build_service(service_id:, slug:, name:, protocol:,
                                     backend_vip_id:, backend_host:, backend_port:)
          if service_id.present?
            svc = ::Sdwan::Service.find_by(id: service_id, account_id: @account.id)
            return failure("Sdwan::Service not found: #{service_id}") if svc.nil?

            return [ svc, false ]
          end

          if slug.blank? || name.blank? || backend_port.blank?
            return failure("creating a new service requires slug, name, and backend_port")
          end
          if backend_vip_id.blank? && backend_host.blank?
            return failure("creating a new service requires backend_vip_id or backend_host")
          end

          svc = ::Sdwan::Service.new(
            account: @account, slug: slug, name: name, protocol: protocol,
            backend_vip_id: backend_vip_id, backend_host: backend_host, backend_port: backend_port,
            status: "active"
          )
          [ svc, true ]
        end

        def apply_local_facet!(service, auth_mode:, required_permission:, required_group:,
                               strip_prefix:, certificate_id:)
          service.local_enabled        = true
          service.local_auth_mode      = auth_mode
          service.local_required_permission = required_permission
          service.local_required_group = required_group
          service.local_strip_prefix   = strip_prefix
          service.local_certificate_id = certificate_id if certificate_id.present?
        end

        # The host the /svc/<slug> router mounts under — the service's explicit
        # local cert CN, else the account's most-recent valid cert CN. Mirrors
        # Sdwan::ServiceExposureWriter#host_for so the returned local_url matches
        # the router Traefik actually serves.
        def resolve_host(service)
          return service.local_certificate.common_name if service.local_certificate

          ::System::AcmeCertificate.where(account_id: @account.id, status: "valid")
                                   .order(created_at: :desc).limit(1).pick(:common_name)
        end
      end
    end
  end
end
