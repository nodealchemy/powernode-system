# frozen_string_literal: true

# MCP tool surface for ingress + public service exposure + ACME provisioning.
#
# Mirrors SdwanTool / SystemFleetTool shape (REQUIRED_PERMISSION floor +
# per-action permission map + action switch), but each action is a thin
# routing layer over a System extension skill executor (one-shot composition).
#
# Actions:
#   - system_reverse_proxy_compose       → ReverseProxyComposeExecutor
#   - system_expose_service_publicly      → ExposeServicePubliclyExecutor
#   - system_acme_provision_certificate   → AcmeProvisionCertificateExecutor
#
# The executors own the actual work; this tool only validates permission,
# unwraps params into keyword args, and forwards to the executor's
# `execute(**)` (which returns `{ success:, data: }` / `{ success:, error: }`).
module Ai
  module Tools
    class SystemIngressTool < BaseTool
      REQUIRED_PERMISSION = "system.ingress.read"

      ACTION_PERMISSIONS = {
        "system_reverse_proxy_compose"      => "system.ingress.manage",
        "system_expose_service_publicly"    => "system.ingress.manage",
        "system_acme_provision_certificate" => "system.acme.manage"
      }.freeze

      # Maps each action to the executor class that implements it.
      ACTION_EXECUTORS = {
        "system_reverse_proxy_compose"      => "System::Ai::Skills::ReverseProxyComposeExecutor",
        "system_expose_service_publicly"    => "System::Ai::Skills::ExposeServicePubliclyExecutor",
        "system_acme_provision_certificate" => "System::Ai::Skills::AcmeCertificateProvisionExecutor"
      }.freeze

      def self.definition
        {
          name: "system_ingress",
          description: "Ingress + public service exposure + ACME certificate provisioning. Regenerates the reverse-proxy (Traefik) config for an issued certificate, exposes a service publicly end-to-end (VIP -> port mapping -> cert -> reverse proxy), and provisions ACME certificates. Parameters are the union of the per-action inputs (see action_definitions).",
          parameters: {
            action:             { type: "string",  required: true, description: "Action to perform" },
            certificate_id:     { type: "string",  required: false },
            service_hostname:   { type: "string",  required: false },
            service_protocol:   { type: "string",  required: false },
            sdwan_network_id:   { type: "string",  required: false },
            sdwan_hub_peer_id:  { type: "string",  required: false },
            target_peer_id:     { type: "string",  required: false },
            target_instance_id: { type: "string",  required: false },
            backend_port:       { type: "integer", required: false },
            common_name:        { type: "string",  required: false },
            sans:               { type: "array",   required: false },
            issuer:             { type: "string",  required: false },
            challenge_type:     { type: "string",  required: false },
            dns_credential_id:  { type: "string",  required: false },
            acme_email:         { type: "string",  required: false },
            tls_issuer:         { type: "string",  required: false }
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
              service_protocol:   { type: "string",  required: true,  description: "http | https" },
              sdwan_network_id:   { type: "string",  required: true,  description: "Sdwan::Network to host the VIP" },
              sdwan_hub_peer_id:  { type: "string",  required: true,  description: "Sdwan::Peer acting as the DNAT hub" },
              backend_port:       { type: "integer", required: true,  description: "Backend service port to route public traffic to" },
              target_peer_id:     { type: "string",  required: false, description: "Sdwan::Peer hosting the backend (mutually exclusive with target_instance_id)" },
              target_instance_id: { type: "string",  required: false, description: "System::NodeInstance hosting the backend (mutually exclusive with target_peer_id)" },
              tls_issuer:         { type: "string",  required: false, description: "ACME issuer (default letsencrypt-prod)" },
              challenge_type:     { type: "string",  required: false, description: "ACME challenge (default dns-01)" },
              dns_credential_id:  { type: "string",  required: false, description: "System::AcmeDnsCredential id (for dns-01)" }
            }
          },
          "system_acme_provision_certificate" => {
            description: "Provision (issue) an ACME TLS certificate for a hostname; the issued cert is stored as a System::AcmeCertificate.",
            parameters: {
              common_name:       { type: "string", required: true,  description: "Primary CN / FQDN for the certificate" },
              issuer:            { type: "string", required: true,  description: "letsencrypt-prod | letsencrypt-staging | internal-ca" },
              challenge_type:    { type: "string", required: true,  description: "dns-01 | http-01 | tls-alpn-01" },
              sans:              { type: "array",  required: false, description: "Additional Subject Alternative Names (FQDNs)" },
              dns_credential_id: { type: "string", required: false, description: "System::AcmeDnsCredential id (required for dns-01)" },
              acme_email:        { type: "string", required: false, description: "ACME registration contact email" }
            }
          }
        }
      end

      protected

      def call(params)
        action = params[:action]
        return error_result("Unknown action: #{action}") unless ACTION_EXECUTORS.key?(action)
        return error_result("permission denied: #{required_perm_for(action)} required") unless action_permitted?(action)

        run_executor(action, params)
      rescue ActiveRecord::RecordNotFound => e
        error_result(e.message)
      rescue ActiveRecord::RecordInvalid => e
        error_result(e.record.errors.full_messages.join("; "))
      end

      private

      def run_executor(action, params)
        klass = ACTION_EXECUTORS.fetch(action).constantize
        inputs = executor_inputs(params)
        klass.new(account: @account, agent: @agent, user: @user).execute(**inputs)
      end

      # Strip the routing-only :action key; forward every other supplied param
      # as a keyword arg. Executors validate their own required inputs.
      def executor_inputs(params)
        params.to_h.except(:action, "action").transform_keys(&:to_sym)
      end

      def required_perm_for(action)
        ACTION_PERMISSIONS[action] || REQUIRED_PERMISSION
      end

      def action_permitted?(action)
        return true if @user.nil?
        return true unless @user.respond_to?(:has_permission?)

        @user.has_permission?(required_perm_for(action))
      end
    end
  end
end
