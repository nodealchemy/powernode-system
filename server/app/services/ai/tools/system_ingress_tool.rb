# frozen_string_literal: true

# MCP tool surface for ingress + service exposure (public + local) + ACME.
#
# Mirrors SdwanTool / SystemFleetTool shape (REQUIRED_PERMISSION floor +
# per-action permission map + action switch). Two flavours of action:
#
#   - Executor-backed (one-shot orchestration / approval-gated): the action is
#     a thin routing layer over a System extension skill executor.
#   - Inline CRUD (Sdwan::Service lifecycle): plain resource management done in
#     this tool, mirroring SdwanTool's create_virtual_ip / list_virtual_ips.
#
# Actions:
#   - system_reverse_proxy_compose       → ReverseProxyComposeExecutor   (executor)
#   - system_expose_service_publicly     → ExposeServicePubliclyExecutor (executor)
#   - system_expose_service_local        → ExposeServiceLocalExecutor    (executor, approval-gated)
#   - system_acme_provision_certificate  → AcmeCertificateProvisionExecutor (executor)
#   - system_expose_service_public_tcp   → ExposeServicePublicTcpExecutor (executor, approval-gated) — Path B ON
#   - system_unexpose_service_public_tcp → ExposeServicePublicTcpExecutor (executor, approval-gated) — Path B OFF
#   - system_create_service / list / get / update / delete                (inline CRUD)
#   - system_unexpose_service_local                                       (inline)
#   - system_set_service_backends        (inline, approval-gated via DeferredToolCall) — APO-3d
#
# Ownership rule: every change to *exposure semantics* (enabling local
# exposure, auth mode, scoped permission/group) goes through the approval-gated
# `system_expose_service_local` executor. Inline CRUD owns identity + overlay
# backend plumbing + read + lifecycle, and `system_unexpose_service_local`
# is the fail-safe "turn it off" (no approval — disabling is deny-by-default).
# Path B (public_enabled) diverges from that fail-safe pattern: BOTH directions
# — expose and unexpose — are owned end to end by ExposeServicePublicTcpExecutor,
# never inline CRUD, because disabling a live public route carries real risk
# too (unlike turning off a ForwardAuth-gated local exposure).
#
# The BACKEND SET (APO-3d, IMP-0c10b9fd5596) is the third owner class:
# `system_set_service_backends` writes a service's Sdwan::ServiceBackend rows
# declaratively (the list given becomes the set) and its per-service
# load-balancer overrides (metadata["load_balancer"]). It is the only MCP door
# onto either; the autonomous producers (scale-out, scale-in, DR replace/reap)
# maintain the set through the executors under their own categories. It is
# approval-gated through the DeferredToolCall replay seam because a backend
# set decides where EVERY request to a published service goes — the same
# class of decision as enabling the exposure, which is gated too.
module Ai
  module Tools
    class SystemIngressTool < BaseTool
      REQUIRED_PERMISSION = "system.ingress.read"

      # The Ai::InterventionPolicy category the backend-set verb gates on. A
      # category of its own, so an operator tunes "who may redirect a
      # published service's traffic" independently of the expose verbs.
      # Ai::InterventionPolicyService resolves an unseeded category to
      # require_approval, which is the intended verdict; the seeded row that
      # makes it VISIBLE in the Autonomy modal belongs in
      # System::Governance::PolicyDeclarations beside the ingress rows.
      SERVICE_BACKENDS_CATEGORY = "system.service_backends_update"
      SERVICE_BACKENDS_ACTION   = "system_set_service_backends"

      # The per-service load-balancer overrides the verb may write into
      # Sdwan::Service#metadata["load_balancer"] — exactly the keys
      # Sdwan::ServiceLoadBalancing resolves, so nothing unread can be stored.
      LOAD_BALANCER_KEYS = %w[health_check_enabled health_check_path
                              health_check_interval health_check_timeout].freeze

      ACTION_PERMISSIONS = {
        "system_reverse_proxy_compose"      => "system.ingress.manage",
        "system_expose_service_publicly"    => "system.ingress.manage",
        "system_expose_service_local"       => "system.ingress.manage",
        "system_acme_provision_certificate" => "system.acme.manage",
        "system_create_service"             => "system.ingress.manage",
        "system_update_service"             => "system.ingress.manage",
        "system_delete_service"             => "system.ingress.manage",
        "system_unexpose_service_local"     => "system.ingress.manage",
        "system_list_services"              => "system.ingress.read",
        "system_get_service"                => "system.ingress.read",
        "system_expose_service_public_tcp"   => "system.ingress.manage",
        "system_unexpose_service_public_tcp" => "system.ingress.manage",
        "system_set_service_backends"        => "system.ingress.manage"
      }.freeze

      # Maps each executor-backed action to the executor class that implements it.
      ACTION_EXECUTORS = {
        "system_reverse_proxy_compose"      => "System::Ai::Skills::ReverseProxyComposeExecutor",
        "system_expose_service_publicly"    => "System::Ai::Skills::ExposeServicePubliclyExecutor",
        "system_expose_service_local"       => "System::Ai::Skills::ExposeServiceLocalExecutor",
        "system_acme_provision_certificate" => "System::Ai::Skills::AcmeCertificateProvisionExecutor",
        "system_expose_service_public_tcp"   => "System::Ai::Skills::ExposeServicePublicTcpExecutor",
        "system_unexpose_service_public_tcp" => "System::Ai::Skills::ExposeServicePublicTcpExecutor"
      }.freeze

      # Both public-TCP actions route to the SAME executor
      # (ExposeServicePublicTcpExecutor) — the MCP action name IS the
      # enable/disable signal, so it is forced here rather than left to
      # caller-supplied params (a "system_unexpose_service_public_tcp" call
      # must always disable, regardless of what params say). Empty for every
      # other action — `run_executor` merges this on top of the normal
      # declared-input filtering with no behavior change for them.
      ACTION_EXECUTOR_OVERRIDES = {
        "system_expose_service_public_tcp"   => { enabled: true },
        "system_unexpose_service_public_tcp" => { enabled: false }
      }.freeze

      # Inline (non-executor) CRUD/lifecycle actions → private handler methods.
      INLINE_ACTIONS = {
        "system_create_service"         => :create_service,
        "system_list_services"          => :list_services,
        "system_get_service"            => :get_service,
        "system_update_service"         => :update_service,
        "system_delete_service"         => :delete_service,
        "system_unexpose_service_local" => :unexpose_service_local,
        "system_set_service_backends"   => :set_service_backends
      }.freeze

      # APO-1a (IMP-1e58753b3b6c) — governance declarations for every action
      # this tool advertises. NON-ENFORCING: `mutating:` alone leaves
      # BaseTool#gated_action? false, so #execute still routes to #call and
      # behaviour is unchanged. Gate wiring (categories/executors) is APO-1e.
      declare_action "system_acme_provision_certificate", mutating: true
      declare_action "system_create_service", mutating: true
      declare_action "system_delete_service", mutating: true
      declare_action "system_expose_service_local", mutating: true
      declare_action "system_expose_service_public_tcp", mutating: true
      declare_action "system_expose_service_publicly", mutating: true
      declare_action "system_get_service", mutating: false
      declare_action "system_list_services", mutating: false
      declare_action "system_reverse_proxy_compose", mutating: true
      declare_action "system_unexpose_service_local", mutating: true
      declare_action "system_unexpose_service_public_tcp", mutating: true
      declare_action "system_update_service", mutating: true

      # APO-3d — GATED, through the generic DeferredToolCall replay seam:
      # BaseTool#execute parks the call under SERVICE_BACKENDS_CATEGORY and the
      # approved replay re-enters #execute as the ORIGINAL caller, reaching
      # #set_service_backends through #call. The gate context validates the
      # payload first (a malformed set keeps its own error rather than becoming
      # an approval that can only fail), and #authorization_error keeps the
      # per-action permission check in front of the gate.
      declare_action SERVICE_BACKENDS_ACTION,
                     mutating: true,
                     action_category: SERVICE_BACKENDS_CATEGORY,
                     executor_class: "Ai::Executors::DeferredToolCall",
                     gate_context: :set_service_backends_gate_context,
                     on_proceed: :deferred_tool_call_result

      def self.definition
        {
          name: "system_ingress",
          description: "Ingress + service exposure (public + local /svc) + ACME certificate provisioning. Regenerates the reverse-proxy (Traefik) config for an issued certificate, exposes a service publicly end-to-end (VIP -> port mapping -> cert -> reverse proxy) or locally at /svc/<slug> with ForwardAuth, manages Sdwan::Service records (create/list/get/update/delete), and provisions ACME certificates. Parameters are the union of the per-action inputs (see action_definitions).",
          parameters: {
            action:             { type: "string",  required: true, enum: action_definitions.keys,
                                  description: "Action to perform" },
            certificate_id:     { type: "string",  required: false },
            service_hostname:   { type: "string",  required: false },
            service_protocol:   { type: "string",  required: false, enum: ::Sdwan::Service::HTTP_PROTOCOLS },
            sdwan_network_id:   { type: "string",  required: false },
            sdwan_hub_peer_id:  { type: "string",  required: false },
            vip_cidr:           { type: "string",  required: false },
            target_peer_id:     { type: "string",  required: false },
            target_instance_id: { type: "string",  required: false },
            backend_port:       { type: "integer", required: false },
            common_name:        { type: "string",  required: false },
            sans:               { type: "array",   required: false, items: { type: "string" } },
            issuer:             { type: "string",  required: false, enum: ::System::AcmeCertificate::ISSUERS },
            challenge_type:     { type: "string",  required: false, enum: ::System::AcmeCertificate::CHALLENGE_TYPES },
            dns_credential_id:  { type: "string",  required: false },
            acme_email:         { type: "string",  required: false },
            tls_issuer:         { type: "string",  required: false },
            # Sdwan::Service CRUD + local exposure
            service_id:          { type: "string",  required: false },
            slug:                { type: "string",  required: false },
            name:                { type: "string",  required: false },
            protocol:            { type: "string",  required: false, enum: ::Sdwan::Service::PROTOCOLS },
            backend_vip_id:      { type: "string",  required: false },
            backend_host:        { type: "string",  required: false },
            status:              { type: "string",  required: false, enum: ::Sdwan::Service::STATUSES },
            auth_mode:           { type: "string",  required: false, enum: ::Sdwan::Service::AUTH_MODES },
            required_permission: { type: "string",  required: false },
            required_group:      { type: "string",  required: false },
            strip_prefix:        { type: "boolean", required: false },
            local_enabled:       { type: "boolean", required: false },
            # Path B (public TLS-carrying TCP, campaign 019f3458 increment 5 +
            # increment 10 prerequisite). edge_mode/client_auth are inert
            # TLS-transport plumbing, wired through create/update like
            # protocol/backend_port. public_enabled is read-only here (list
            # filter + visibility) — it is owned end to end by
            # system_expose_service_public_tcp / system_unexpose_service_public_tcp
            # (ExposeServicePublicTcpExecutor), never this CRUD surface; see
            # system_update_service's action_definitions entry below.
            edge_mode:           { type: "string",  required: false, enum: ::Sdwan::Service::EDGE_MODES },
            client_auth:         { type: "string",  required: false, enum: ::Sdwan::Service::CLIENT_AUTH_MODES },
            public_enabled:      { type: "boolean", required: false },
            enabled:             { type: "boolean", required: false },
            # APO-3d backend set (system_set_service_backends)
            backends:            { type: "array",   required: false, items: { type: "object" } },
            load_balancer:       { type: "object",  required: false }
          }
        }
      end

      def self.action_definitions
        {
          "system_reverse_proxy_compose" => {
            description: "Regenerate the reverse-proxy (Traefik) dynamic config so the platform serves an issued ACME certificate. The certificate must already be valid.",
            parameters: {
              certificate_id: { type: "string", required: true, description: "System::AcmeCertificate id (status must be valid)" }
            }
          },
          "system_expose_service_publicly" => {
            description: "Expose a service to the public internet end-to-end: create/reuse an SDWAN VIP, port-map it on the hub, provision a TLS certificate for the hostname, and regenerate the reverse proxy.",
            parameters: {
              service_hostname:   { type: "string",  required: true,  description: "Public FQDN to serve the service on (certificate CN)" },
              service_protocol:   { type: "string",  required: true,  enum: ::Sdwan::Service::HTTP_PROTOCOLS,
                                                     description: "http | https" },
              sdwan_network_id:   { type: "string",  required: true,  description: "Sdwan::Network to host the VIP" },
              sdwan_hub_peer_id:  { type: "string",  required: true,  description: "Sdwan::Peer acting as the DNAT hub" },
              vip_cidr:           { type: "string",  required: true,  description: "Operator-supplied host CIDR for the VIP (typically /128 v6 or /32 v4) within the network's /64" },
              backend_port:       { type: "integer", required: true,  description: "Backend service port to route public traffic to" },
              target_peer_id:     { type: "string",  required: false, description: "Sdwan::Peer hosting the backend (mutually exclusive with target_instance_id)" },
              target_instance_id: { type: "string",  required: false, description: "System::NodeInstance hosting the backend (mutually exclusive with target_peer_id)" },
              tls_issuer:         { type: "string",  required: false, enum: ::System::AcmeCertificate::ISSUERS,
                                                     description: "ACME issuer (default letsencrypt-prod)" },
              challenge_type:     { type: "string",  required: false, enum: ::System::AcmeCertificate::CHALLENGE_TYPES,
                                                     description: "ACME challenge (default dns-01)" },
              dns_credential_id:  { type: "string",  required: false, description: "System::AcmeDnsCredential id (for dns-01)" }
            }
          },
          "system_acme_provision_certificate" => {
            description: "Provision (issue) an ACME TLS certificate for a hostname; the issued cert is stored as a System::AcmeCertificate.",
            parameters: {
              common_name:       { type: "string", required: true,  description: "Primary CN / FQDN for the certificate" },
              issuer:            { type: "string", required: true,  enum: ::System::AcmeCertificate::ISSUERS,
                                                    description: "letsencrypt-prod | letsencrypt-staging | internal-ca" },
              challenge_type:    { type: "string", required: true,  enum: ::System::AcmeCertificate::CHALLENGE_TYPES,
                                                    description: "dns-01 | http-01 | tls-alpn-01" },
              sans:              { type: "array",  required: false, items: { type: "string" },
                                                    description: "Additional Subject Alternative Names (FQDNs)" },
              dns_credential_id: { type: "string", required: false, description: "System::AcmeDnsCredential id (required for dns-01)" },
              acme_email:        { type: "string", required: false, description: "ACME registration contact email" }
            }
          },
          "system_expose_service_local" => {
            description: "Expose a backend service locally at /svc/<slug> on the platform's own host(s), authenticated by the reverse proxy (ForwardAuth). Creates or updates the Sdwan::Service and enables its local-exposure facet. Approval-gated. For the public internet use system_expose_service_publicly instead.",
            parameters: {
              service_id:          { type: "string",  required: false, description: "Existing Sdwan::Service id to expose (omit to create from the fields below)" },
              slug:                { type: "string",  required: false, description: "URL slug for /svc/<slug> (required when creating)" },
              name:                { type: "string",  required: false, description: "Service display name (required when creating)" },
              protocol:            { type: "string",  required: false, enum: ::Sdwan::Service::HTTP_PROTOCOLS,
                                                        description: "Backend protocol: https | http (default https)" },
              backend_vip_id:      { type: "string",  required: false, description: "Sdwan::VirtualIp id of the overlay backend (this or backend_host when creating)" },
              backend_host:        { type: "string",  required: false, description: "Static backend host/IP (this or backend_vip_id when creating)" },
              backend_port:        { type: "integer", required: false, description: "Backend port (required when creating)" },
              auth_mode:           { type: "string",  required: false, enum: ::Sdwan::Service::AUTH_MODES,
                                                        description: "public | authenticated | scoped (default authenticated)" },
              required_permission: { type: "string",  required: false, description: "Permission required for scoped mode" },
              required_group:      { type: "string",  required: false, description: "Group/role required for scoped mode" },
              strip_prefix:        { type: "boolean", required: false, description: "Strip /svc/<slug> before proxying (default true)" },
              certificate_id:      { type: "string",  required: false, description: "System::AcmeCertificate id whose CN to mount under (default: account primary)" }
            }
          },
          "system_expose_service_public_tcp" => {
            description: "Enable a service's public (Path B) TLS-carrying TCP exposure via Traefik HostSNI routing — validates protocol tls, a resolvable host, and (under edge_mode terminate) a matching valid ACME certificate, then flips public_enabled on and regenerates the reverse proxy. Approval-gated; the sole owner of turning Path B ON (in either direction — see system_unexpose_service_public_tcp).",
            parameters: {
              service_id: { type: "string", required: true, description: "Sdwan::Service id (protocol must be tls)" }
            }
          },
          "system_unexpose_service_public_tcp" => {
            description: "Disable a service's public (Path B) TLS-carrying TCP exposure and regenerate the reverse proxy. Approval-gated (unlike the fail-safe, no-approval system_unexpose_service_local) — the sole owner of turning Path B OFF; system_update_service refuses public_enabled in either direction.",
            parameters: {
              service_id: { type: "string", required: true, description: "Sdwan::Service id" }
            }
          },
          "system_create_service" => {
            description: "Create an Sdwan::Service (identity + overlay backend). Does NOT expose it — use system_expose_service_local to publish it at /svc/<slug>, or system_expose_service_public_tcp for Path B public TLS-carrying TCP. edge_mode/client_auth may be pre-provisioned here; public_enabled itself is owned by system_expose_service_public_tcp / system_unexpose_service_public_tcp, not this action.",
            parameters: {
              slug:           { type: "string",  required: true,  description: "URL slug (lowercase alnum + hyphen, <=64, not a reserved platform path)" },
              name:           { type: "string",  required: true,  description: "Service display name" },
              backend_port:   { type: "integer", required: true,  description: "Backend service port (1-65535)" },
              protocol:       { type: "string",  required: false, enum: ::Sdwan::Service::PROTOCOLS,
                                                   description: "https | http | tcp | tls (default https)" },
              backend_vip_id: { type: "string",  required: false, description: "Sdwan::VirtualIp id of the overlay backend (this or backend_host)" },
              backend_host:   { type: "string",  required: false, description: "Static backend host/IP (this or backend_vip_id)" },
              status:         { type: "string",  required: false, enum: ::Sdwan::Service::STATUSES,
                                                   description: "active | disabled (default active)" },
              edge_mode:      { type: "string",  required: false, enum: ::Sdwan::Service::EDGE_MODES,
                                                   description: "Path B TLS-carrying TCP: passthrough | terminate (default passthrough; inert until public_enabled)" },
              client_auth:    { type: "string",  required: false, enum: ::Sdwan::Service::CLIENT_AUTH_MODES,
                                                   description: "Path B mTLS enforcement: none | required (default none; required needs edge_mode terminate)" }
            }
          },
          "system_list_services" => {
            description: "List this account's Sdwan::Service records, newest first, one page at a time. " \
                         "Read count (the total matching your filters) and has_more to tell a complete answer from a truncated one.",
            parameters: {
              status:         { type: "string",  required: false, enum: ::Sdwan::Service::STATUSES,
                                                   description: "Filter by status (active | disabled)" },
              local_enabled:  { type: "boolean", required: false, description: "Filter by local-exposure state" },
              public_enabled: { type: "boolean", required: false, description: "Filter by public (Path B) exposure state" },
              **PAGINATION_PARAMETERS
            }
          },
          "system_get_service" => {
            description: "Fetch a single Sdwan::Service by id (scoped to this account).",
            parameters: {
              service_id: { type: "string", required: true, description: "Sdwan::Service id" }
            }
          },
          "system_update_service" => {
            description: "Update an Sdwan::Service's identity + backend plumbing (name, protocol, status, backend, Path B edge_mode/client_auth). Exposure semantics (local_enabled, auth mode, and public_enabled) are NOT settable here. local_enabled is owned by system_expose_service_local; public_enabled (Path B) is owned by system_expose_service_public_tcp / system_unexpose_service_public_tcp — deliberately not settable through this CRUD action in either direction. Regenerates the reverse proxy when the service is locally and/or publicly exposed.",
            parameters: {
              service_id:     { type: "string",  required: true,  description: "Sdwan::Service id" },
              name:           { type: "string",  required: false, description: "New display name" },
              protocol:       { type: "string",  required: false, enum: ::Sdwan::Service::PROTOCOLS,
                                                   description: "https | http | tcp | tls" },
              status:         { type: "string",  required: false, enum: ::Sdwan::Service::STATUSES,
                                                   description: "active | disabled" },
              backend_vip_id: { type: "string",  required: false, description: "New overlay backend VIP id" },
              backend_host:   { type: "string",  required: false, description: "New static backend host/IP" },
              backend_port:   { type: "integer", required: false, description: "New backend port" },
              edge_mode:      { type: "string",  required: false, enum: ::Sdwan::Service::EDGE_MODES,
                                                   description: "Path B TLS-carrying TCP: passthrough | terminate" },
              client_auth:    { type: "string",  required: false, enum: ::Sdwan::Service::CLIENT_AUTH_MODES,
                                                   description: "Path B mTLS enforcement: none | required (required needs edge_mode terminate)" }
            }
          },
          "system_delete_service" => {
            description: "Delete an Sdwan::Service. Regenerates the reverse proxy if the service was locally exposed (removing its /svc/<slug> route).",
            parameters: {
              service_id: { type: "string", required: true, description: "Sdwan::Service id" }
            }
          },
          "system_unexpose_service_local" => {
            description: "Disable a service's local /svc/<slug> exposure (fail-safe off — no approval needed) and regenerate the reverse proxy. The Sdwan::Service record is kept; re-expose with system_expose_service_local.",
            parameters: {
              service_id: { type: "string", required: true, description: "Sdwan::Service id" }
            }
          },
          "system_set_service_backends" => {
            description: "Set a service's load-balanced backend set DECLARATIVELY: the `backends` list becomes the set (members are matched by address + port and updated in place, members absent from the list are removed, an empty list returns the service to its single legacy backend). Optionally sets the per-service load-balancer overrides (metadata.load_balancer: health_check_enabled/path/interval/timeout; a null value clears that override). Regenerates the reverse proxy when the service is exposed. Approval-gated under #{SERVICE_BACKENDS_CATEGORY}: unless policy auto-approves, the call returns a pending envelope (deferred_operation_id) and the set is written when the approval is released. Draining EVERY member takes the service out of rotation (the writer skips it); to keep serving from the original backend while you rebuild the set, keep it listed as an active member.",
            parameters: {
              service_id:    { type: "string", required: true, description: "Sdwan::Service id" },
              backends:      { type: "array",  required: true, items: { type: "object" },
                               description: "Desired members, each { backend_host | backend_vip_id, backend_port (1-65535, required), weight (1-1000, default 1), status (active | draining, default active) }. Empty array clears the set." },
              load_balancer: { type: "object", required: false,
                               description: "Per-service overrides: { health_check_enabled: boolean, health_check_path: string, health_check_interval: e.g. \"10s\", health_check_timeout: e.g. \"3s\" }. Keys given are merged; null removes a key. Health checking is opt-in — a check on the wrong path takes the whole service dark." }
            }
          }
        }
      end

      protected

      def call(params)
        action = params[:action]
        known = ACTION_EXECUTORS.key?(action) || INLINE_ACTIONS.key?(action)
        return error_result("Unknown action: #{action}") unless known
        return error_result("permission denied: #{required_perm_for(action)} required") unless action_permitted?(action)

        if ACTION_EXECUTORS.key?(action)
          run_executor(action, params)
        else
          send(INLINE_ACTIONS.fetch(action), params)
        end
      rescue ActiveRecord::RecordNotFound => e
        error_result(e.message)
      rescue ActiveRecord::RecordInvalid => e
        error_result(e.record.errors.full_messages.join("; "))
      rescue ::Sdwan::ServiceExposureWriter::WriteError => e
        # The DB flip (create/update/delete/unexpose) already committed by
        # this point — only the reverse-proxy regen failed. Surface it as a
        # clean error instead of a raw exception, and flag that the stale
        # on-disk YAML may still be routing the old state until a regen
        # succeeds (system_reverse_proxy_compose, or retry this action).
        error_result("service change saved but reverse-proxy regen failed (stale route may still be live): #{e.message}")
      end

      # Hoists the per-action permission check so a GATED action — which
      # never reaches #call — is authorized exactly as an ungated one is
      # (BaseTool#execute consults this before the gate). Same seam as
      # SystemFleetTool#authorization_error.
      def authorization_error(params)
        action = routed_action_name(params)
        return nil if action_permitted?(action)

        error_result("permission denied: #{required_perm_for(action)} required")
      end

      # The backend-set verb's gate context: VALIDATE FIRST (service in
      # account scope, well-formed members, known override keys), then pack
      # the replay through the generic seam. Both raises are the ones
      # BaseTool#run_through_autonomy_gate converts to an error envelope, so a
      # payload that could only ever fail never parks an approval an operator
      # has to dispose of.
      def set_service_backends_gate_context(params)
        svc = account_services.find(params[:service_id])
        members = normalize_backend_specs(params[:backends])
        normalize_load_balancer_overrides(params[:load_balancer])

        deferred_tool_call_context(params).merge(
          description: "Set the backend set of service '#{svc.slug}' " \
                       "(#{members.size} member#{members.size == 1 ? '' : 's'}" \
                       "#{params[:load_balancer].nil? ? '' : ', with load-balancer overrides'})"
        )
      end

      private

      # ── Sdwan::Service inline CRUD + lifecycle ──────────────────────────
      # Mirrors SdwanTool's resource-CRUD shape (find/serialize/success_result).
      # Exposure semantics (local_enabled, auth mode, and public_enabled — Path
      # B, campaign 019f3458 increment 5) are deliberately NOT mutable here —
      # see the class header's ownership rule. edge_mode/client_auth ARE
      # mutable here: they are inert TLS-transport plumbing (same class as
      # protocol/backend_port) with zero effect until a service is actually
      # public_enabled, which no tool can flip yet (queued gap, not silently
      # bypassable through this CRUD surface).

      def create_service(params)
        svc = account_services.create!(
          slug:           params[:slug],
          name:           params[:name],
          protocol:       params[:protocol].presence || "https",
          backend_vip_id: params[:backend_vip_id],
          backend_host:   params[:backend_host],
          backend_port:   params[:backend_port],
          status:         params[:status].presence || "active",
          # presence-or-default (not the column default) — an explicit nil
          # here would fail the model's inclusion validation, same reason
          # status/protocol already follow this pattern.
          edge_mode:      params[:edge_mode].presence || "passthrough",
          client_auth:    params[:client_auth].presence || "none"
        )
        success_result(service: serialize_service(svc))
      end

      def list_services(params)
        scope = account_services
        scope = scope.where(status: params[:status]) if params[:status].present?
        scope = scope.where(local_enabled: params[:local_enabled]) unless params[:local_enabled].nil?
        scope = scope.where(public_enabled: params[:public_enabled]) unless params[:public_enabled].nil?
        # :id desc IS the old created_at desc on a UUIDv7 primary key, and it is
        # the only ordering a keyset cursor can make total on its own.
        paginated_result(:services, scope, params) { |s| serialize_service(s) }
      end

      def get_service(params)
        svc = account_services.find(params[:service_id])
        success_result(service: serialize_service(svc), backends: serialize_backends(svc),
                       load_balancer: svc.metadata.is_a?(Hash) ? svc.metadata["load_balancer"] : nil)
      end

      def update_service(params)
        svc = account_services.find(params[:service_id])
        updates = {}
        %i[name protocol status backend_vip_id backend_host backend_port edge_mode client_auth].each do |k|
          updates[k] = params[k] if params.key?(k) && !params[k].nil?
        end
        svc.update!(updates)
        regen_reverse_proxy! if svc.local_enabled? || svc.public_enabled?
        success_result(service: serialize_service(svc.reload))
      end

      def delete_service(params)
        svc = account_services.find(params[:service_id])
        was_exposed = svc.local_enabled? || svc.public_enabled?
        svc.destroy!
        regen_reverse_proxy! if was_exposed
        success_result(deleted: true, id: svc.id)
      end

      def unexpose_service_local(params)
        svc = account_services.find(params[:service_id])
        svc.update!(local_enabled: false)
        regen_reverse_proxy!
        success_result(service: serialize_service(svc.reload), local_exposure: "disabled")
      end

      # APO-3d — the declarative backend-set write. Reached ONLY through the
      # gate: BaseTool#execute never calls #call for this action until the
      # operation is approved (or policy proceeds), so this body is the single
      # writer on both branches.
      #
      # Members are matched by (address form, port): a listed member that
      # already exists is updated in place (weight/status), one that does not
      # is created, and every existing row absent from the list is destroyed.
      # An empty list therefore clears the set and the service falls back to
      # its legacy columns. One transaction, so a half-applied set cannot be
      # what Traefik dials.
      def set_service_backends(params)
        svc = account_services.find(params[:service_id])
        members = normalize_backend_specs(params[:backends])
        overrides = normalize_load_balancer_overrides(params[:load_balancer])

        ::ActiveRecord::Base.transaction do
          existing = svc.backends.to_a
          kept = []
          members.each do |spec|
            row = existing.find { |candidate| same_backend?(candidate, spec) }
            if row
              row.update!(weight: spec[:weight], status: spec[:status])
            else
              row = svc.backends.create!(spec.merge(account_id: svc.account_id))
            end
            kept << row.id
          end
          existing.reject { |row| kept.include?(row.id) }.each(&:destroy!)

          apply_load_balancer_overrides!(svc, overrides) unless overrides.nil?
        end

        regen_reverse_proxy! if svc.local_enabled? || svc.public_enabled?
        svc.reload
        success_result(service: serialize_service(svc), backends: serialize_backends(svc),
                       load_balancer: svc.metadata.is_a?(Hash) ? svc.metadata["load_balancer"] : nil)
      rescue ArgumentError => e
        error_result(e.message)
      end

      # The member list, checked shape by shape. Raises ArgumentError — the
      # gate context and the write both call this, so a malformed list is
      # refused identically before the gate and on replay.
      def normalize_backend_specs(raw)
        raise ArgumentError, "backends is required (an array of members; [] clears the set)" unless raw.is_a?(Array)

        raw.each_with_index.map do |entry, index|
          member = entry.respond_to?(:to_h) ? entry.to_h.transform_keys(&:to_sym) : nil
          raise ArgumentError, "backends[#{index}] must be an object" unless member.is_a?(Hash)

          vip  = member[:backend_vip_id].presence
          host = member[:backend_host].presence
          if vip.present? == host.present?
            raise ArgumentError, "backends[#{index}]: exactly one of backend_host or backend_vip_id is required"
          end

          # Account-scoped, not merely well-formed. A service id alone is no
          # proof the caller may act on it (that is what #account_services
          # settles) and a VIP id is no different: an unscoped id would let a
          # caller holding system.ingress.manage in ITS account point its own
          # published service at another tenant's VIP address. Resolved here so
          # the refusal happens before the gate, in the same place as every
          # other shape error.
          if vip && !::Sdwan::VirtualIp.where(account_id: @account.id, id: vip).exists?
            raise ArgumentError, "backends[#{index}]: backend_vip_id #{vip} not found in this account"
          end

          port = Integer(member[:backend_port].to_s, exception: false)
          unless port&.between?(1, 65_535)
            raise ArgumentError, "backends[#{index}]: backend_port is required (1-65535)"
          end

          weight = member.key?(:weight) && !member[:weight].nil? ? Integer(member[:weight].to_s, exception: false) : ::Sdwan::ServiceBackend::DEFAULT_WEIGHT
          unless weight&.between?(::Sdwan::ServiceBackend::MIN_WEIGHT, ::Sdwan::ServiceBackend::MAX_WEIGHT)
            raise ArgumentError, "backends[#{index}]: weight must be #{::Sdwan::ServiceBackend::MIN_WEIGHT}-#{::Sdwan::ServiceBackend::MAX_WEIGHT}"
          end

          status = member[:status].presence&.to_s || "active"
          unless ::Sdwan::ServiceBackend::STATUSES.include?(status)
            raise ArgumentError, "backends[#{index}]: status must be one of #{::Sdwan::ServiceBackend::STATUSES.join(', ')}"
          end

          { backend_vip_id: vip, backend_host: host, backend_port: port, weight: weight, status: status }
        end
      end

      # nil when no overrides were supplied (leave metadata alone); else a
      # string-keyed hash restricted to LOAD_BALANCER_KEYS, nil values kept as
      # the "clear this key" signal.
      def normalize_load_balancer_overrides(raw)
        return nil if raw.nil?
        raise ArgumentError, "load_balancer must be an object" unless raw.respond_to?(:to_h)

        overrides = raw.to_h.transform_keys(&:to_s)
        unknown = overrides.keys - LOAD_BALANCER_KEYS
        if unknown.any?
          raise ArgumentError, "load_balancer: unknown key(s) #{unknown.join(', ')} " \
                               "(allowed: #{LOAD_BALANCER_KEYS.join(', ')})"
        end
        overrides
      end

      def apply_load_balancer_overrides!(svc, overrides)
        metadata = svc.metadata.is_a?(Hash) ? svc.metadata.deep_dup : {}
        current = metadata["load_balancer"].is_a?(Hash) ? metadata["load_balancer"] : {}
        merged = current.merge(overrides).reject { |_, value| value.nil? }
        if merged.empty?
          metadata.delete("load_balancer")
        else
          metadata["load_balancer"] = merged
        end
        svc.update!(metadata: metadata)
      end

      def same_backend?(row, spec)
        return false unless row.backend_port == spec[:backend_port]
        return row.backend_vip_id == spec[:backend_vip_id] if spec[:backend_vip_id].present?

        row.backend_host == spec[:backend_host]
      end

      def serialize_backends(svc)
        svc.backends.includes(:backend_vip).order(:created_at, :id).map do |row|
          { id: row.id, backend_vip_id: row.backend_vip_id, backend_host: row.backend_host,
            backend_port: row.backend_port, address: row.address, weight: row.weight,
            status: row.status }
        end
      end

      def account_services
        ::Sdwan::Service.where(account_id: @account.id)
      end

      # Re-emit this account's Traefik YAML (local /svc routers AND/OR public
      # Path B tcp.routers — Sdwan::ServiceExposureWriter renders both facets)
      # so a CRUD-driven change to an exposed service is reflected without
      # restart.
      def regen_reverse_proxy!
        ::Sdwan::ServiceExposureWriter.write!(account: @account)
      end

      def serialize_service(svc)
        {
          id:                        svc.id,
          slug:                      svc.slug,
          name:                      svc.name,
          protocol:                  svc.protocol,
          status:                    svc.status,
          backend_vip_id:            svc.backend_vip_id,
          backend_host:              svc.backend_host,
          backend_port:              svc.backend_port,
          backend_url:               svc.backend_url,
          local_enabled:             svc.local_enabled,
          local_auth_mode:           svc.local_auth_mode,
          local_required_permission: svc.local_required_permission,
          local_required_group:      svc.local_required_group,
          local_strip_prefix:        svc.local_strip_prefix,
          local_certificate_id:      svc.local_certificate_id,
          local_path:                svc.local_path_prefix,
          public_enabled:            svc.public_enabled,
          edge_mode:                 svc.edge_mode,
          client_auth:               svc.client_auth
        }
      end

      # The instance provenance travels with the call. Forwarding `user:` alone
      # dropped it — an instance principal has no User, so the executor read the
      # nil user as "in-process reconciler" and handed every tool it nests the
      # internal bypass, out of reach of the name grant and the destructive deny
      # overlay that authorized THIS call. (IMP-0e6b216de843)
      def run_executor(action, params)
        klass = ACTION_EXECUTORS.fetch(action).constantize
        inputs = executor_inputs(klass, params).merge(ACTION_EXECUTOR_OVERRIDES.fetch(action, {}))
        build_skill_executor(klass).execute(**inputs)
      end

      # Strip the routing-only :action key and forward only the params the
      # target executor actually declares as skill_descriptor inputs. Executor
      # `perform` signatures are strict (no **splat catch-all on every key), so
      # any undeclared extra param would otherwise raise ArgumentError that the
      # executor's error pipeline swallows into a silent failure (fix #3).
      def executor_inputs(klass, params)
        declared = klass.descriptor[:inputs]&.keys || []
        params.to_h
              .except(:action, "action")
              .transform_keys(&:to_sym)
              .slice(*declared)
      end

      # === Permission gating ===
      # Two bypasses, both EXPLICIT (IMP-54bf2643f542, sibling of the
      # SystemFleetTool fix IMP-9030413bc292 — its ladder carries the full note):
      #
      #   internal?            in-process system callers (autonomy reconcilers,
      #                        skill executors running without a user) that
      #                        opted in with `internal: true`.
      #   instance_authorized? an MCP instance principal (mTLS node cert, no
      #                        User) whose specific tool name already cleared
      #                        Mcp::Principal#may_invoke? — that per-tool grant
      #                        stands in for authorization. It is NAME-scoped
      #                        while this tool runs the action the caller
      #                        supplies, so treat it as provenance, not a fence.
      #
      # This used to be one implicit `@user.nil?` bypass, whose premise — that
      # MCP callers always carry a user — predates instance principals and is
      # false for them, so an instance skipped this map entirely. A nil user
      # with neither flag now fails CLOSED — which also stops the routed
      # executor (built below with `user: @user`) from being reached at all.
      def required_perm_for(action)
        ACTION_PERMISSIONS[action] || REQUIRED_PERMISSION
      end

      def action_permitted?(action)
        return true if internal?
        return true if instance_authorized?
        return false if @user.nil?
        return true unless @user.respond_to?(:has_permission?)

        @user.has_permission?(required_perm_for(action))
      end
    end
  end
end
