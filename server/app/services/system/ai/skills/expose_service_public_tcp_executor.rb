# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Skill: govern Sdwan::Service#public_enabled — the toggle for Path B
      # (public TLS-carrying TCP via Traefik HostSNI, campaign 019f3458
      # increment 5's substrate). Sole owner of BOTH directions of that
      # toggle; SystemIngressTool's inline `system_update_service` CRUD action
      # refuses to touch it (regression-pinned by its "does NOT flip
      # public_enabled through update_service" spec) — exposing a service to
      # the public internet, and un-exposing it, both go through this
      # approval-gated executor rather than plain CRUD.
      #
      # This differs from the LOCAL sibling's ownership split
      # (ExposeServiceLocalExecutor owns turning local_enabled ON;
      # SystemIngressTool's `system_unexpose_service_local` inline action owns
      # turning it OFF, fail-safe/no-approval): Path B's blast radius runs in
      # BOTH directions — enabling routes backend traffic to the raw public
      # internet, and disabling drops a live public route — so neither
      # direction is the inline "obviously safe" case Local's fail-safe-off
      # design assumes.
      #
      # EXPOSE (`enabled: true`, the default) validates, in order:
      #   1. the Sdwan::Service exists in THIS account (a foreign-account id
      #      fails identically to an unknown one — no cross-account existence
      #      leak)
      #   2. protocol == "tls" (Sdwan::Service::SNI_PROTOCOL) — Path B only
      #      ever rides Traefik SNI routing (mirrors the model's own
      #      `public_exposure_requires_sni` validation, checked here first for
      #      a clearer message before any write is attempted)
      #   3. a resolvable HostSNI host (mirrors
      #      Sdwan::ServiceExposureWriter#host_for /
      #      ExposeServiceLocalExecutor#resolve_host) — a service with neither
      #      an explicit local_certificate nor an account-wide valid cert has
      #      no host to route on, and ServiceExposureWriter would silently
      #      SKIP it rather than emit a hostless (traffic-hijacking) router
      #   4. under `edge_mode == "terminate"` only: a valid
      #      System::AcmeCertificate whose common_name matches that resolved
      #      host — Traefik resolves the serving cert for a terminate-mode
      #      router purely by SNI-matching against `tls.certificates`
      #      (Acme::TraefikConfigWriter), so a "terminate" router with no
      #      matching valid cert would come online but fail every handshake
      #
      # UNEXPOSE (`enabled: false`) is the simple, always-available "turn it
      # off": no protocol/host/cert preconditions — the model itself imposes
      # no constraints on flipping public_enabled to false, and neither does
      # this executor.
      #
      # Both directions finish with `save!` (the model's own validations are
      # the final safety net — same "surface the model's messages rather than
      # re-implementing them" convention as ExposeServiceLocalExecutor) and a
      # Sdwan::ServiceExposureWriter regen so the change takes effect without
      # a Traefik restart.
      #
      # `requires_approval: true`, matching the family
      # (ExposeServicePubliclyExecutor, ExposeServiceLocalExecutor), and the
      # flag is ENFORCED as of APO-1c (IMP-7e2bdc1774e4): BaseSkillExecutor
      # #execute resolves Ai::InterventionPolicy before #perform, so
      # SystemIngressTool#call -> #run_executor now parks an
      # Ai::ApprovalRequest for this action unless an operator policy says
      # otherwise. Until then improvement `019f34a3` recorded the opposite —
      # the flag was declared here and read by nobody — and this executor
      # deliberately did NOT invent a bespoke check to paper over it, because
      # consistency with the family mattered more than a one-off fix. The base
      # class was the right altitude, and that is where the gate landed.
      #
      # Pinned by the request spec's approval-gating blocks
      # (spec/requests/api/v1/mcp/system_ingress_tool_spec.rb), which were
      # inverted from pinning the gap to pinning the gate.
      class ExposeServicePublicTcpExecutor < BaseSkillExecutor
        skill_descriptor(
          name: "expose_service_public_tcp",
          description: "Toggle a backend service's public (Path B) TLS-carrying TCP exposure via Traefik HostSNI routing. Use this when an operator asks to 'publish <service> on the public internet over raw TLS/TCP', 'turn on/off public exposure for <service>', or otherwise flip Sdwan::Service#public_enabled. EXPOSE (enabled: true, default) validates the service's protocol is tls, that a HostSNI host resolves, and — under edge_mode terminate — that a matching valid ACME certificate exists, before enabling. UNEXPOSE (enabled: false) simply disables it. NOT for HTTP(S) (use expose_service_publicly) or the site-local /svc plane (use expose_service_local).",
          category: "devops",
          requires_approval: true,
          inputs: {
            service_id: { type: "string", required: true,
                          description: "Existing Sdwan::Service id to toggle public (Path B) TCP exposure for" },
            enabled:    { type: "boolean", required: false, default: true,
                          description: "true (default) to EXPOSE (enable public_enabled); false to UNEXPOSE (disable it)" }
          },
          outputs: {
            service_id:          :string,
            slug:                :string,
            public_enabled:      :boolean,
            edge_mode:           :string,
            client_auth:         :string,
            host:                :string,
            local_services_path: :string,
            routes_configured:   :integer
          }
        )

        # HIER-P2D: owned by the Ingress Manager (its system.expose_service_* row
        # gates this executor when run as that agent); System Concierge keeps the
        # operator-chat door and its approval card.
        binds_to "ingress_manager", "concierge"

        protected

        def perform(service_id:, enabled: true, **_extra)
          service = ::Sdwan::Service.find_by(id: service_id, account_id: @account.id)
          return failure("Sdwan::Service not found: #{service_id}") if service.nil?

          if enabled
            preflight_failure = validate_exposable(service)
            return preflight_failure if preflight_failure
          end

          service.public_enabled = enabled
          service.save!

          regen = ::Sdwan::ServiceExposureWriter.write!(account: @account)

          success(
            service_id: service.id,
            slug: service.slug,
            public_enabled: service.public_enabled,
            edge_mode: service.edge_mode,
            client_auth: service.client_auth,
            host: resolve_host(service),
            local_services_path: regen[:output_path],
            routes_configured: regen[:route_count]
          )
        rescue ActiveRecord::RecordInvalid => e
          failure(e.record.errors.full_messages.join("; "))
        rescue ::Sdwan::ServiceExposureWriter::WriteError => e
          failure("reverse-proxy regen failed: #{e.message}")
        end

        private

        # Pre-flight checks for EXPOSE only (see class doc for the ordered
        # list and why each exists). Returns a `failure(...)` Hash, or nil
        # when clear to proceed.
        def validate_exposable(service)
          unless service.protocol == ::Sdwan::Service::SNI_PROTOCOL
            return failure(
              "public TLS-carrying TCP exposure requires the tls protocol (SNI-routable); " \
              "#{service.slug} is #{service.protocol}"
            )
          end

          host = resolve_host(service)
          if host.blank?
            return failure(
              "no resolvable host for #{service.slug}: set an explicit local_certificate_id on the " \
              "service, or issue a valid System::AcmeCertificate for this account"
            )
          end

          if service.edge_mode == "terminate" && !valid_cert_for_host?(host)
            return failure(
              "edge_mode terminate requires a valid System::AcmeCertificate whose common_name matches " \
              "the resolved host (#{host}); Traefik resolves the terminate-mode serving cert purely by " \
              "SNI match against tls.certificates, so a mismatched/missing cert would fail every handshake"
            )
          end

          nil
        end

        def valid_cert_for_host?(host)
          ::System::AcmeCertificate.exists?(account_id: @account.id, status: "valid", common_name: host)
        end

        # Mirrors Sdwan::ServiceExposureWriter#host_for /
        # ExposeServiceLocalExecutor#resolve_host so the previewed host
        # matches what the writer actually renders the HostSNI rule against.
        def resolve_host(service)
          return service.local_certificate.common_name if service.local_certificate

          ::System::AcmeCertificate.where(account_id: @account.id, status: "valid")
                                   .order(created_at: :desc).limit(1).pick(:common_name)
        end
      end
    end
  end
end
