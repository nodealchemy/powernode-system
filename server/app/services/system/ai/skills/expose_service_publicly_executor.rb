# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Skill: expose a backend service to the public internet end-to-end.
      #
      # North-star orchestrator #1 — chains the four primitives an operator
      # would otherwise wire by hand into one approval-gated skill:
      #
      #   1. SDWAN Virtual IP   — a stable overlay address that fronts the
      #      backend instance/peer (system_sdwan_create_virtual_ip).
      #   2. Hub port mapping   — a DNAT rule on the public hub peer that
      #      forwards 443 (https) / 80 (http) to the VIP + backend port
      #      (system_sdwan_create_port_mapping).
      #   3. ACME certificate   — a TLS cert for the service hostname, via
      #      the sibling AcmeCertificateProvisionExecutor.
      #   4. Reverse-proxy regen — fold the new cert into the proxy config,
      #      via the sibling ReverseProxyComposeExecutor.
      #
      # IDs thread between steps: the VIP id becomes the port mapping's
      # target_virtual_ip_id; the issued certificate_id drives the
      # reverse-proxy regen. The first two steps are hard requirements — a
      # failure there aborts with `failure(...)`. Cert provisioning and
      # proxy regen degrade gracefully: a failure there is collected as a
      # warning and the skill still returns `success` with the IDs created
      # so far (the operator can re-run cert/proxy independently).
      #
      # Reuse semantics:
      #   - VIP: reused when a VIP with the same name already exists in the
      #     network (idempotent re-runs don't pile up VIPs).
      #   - Cert: reused when a valid, unexpired cert for the hostname
      #     already exists (no needless ACME round-trips).
      class ExposeServicePubliclyExecutor < BaseSkillExecutor
        PROTOCOLS = %w[http https].freeze

        skill_descriptor(
          name: "expose_service_publicly",
          description: "Expose a backend service to the public internet end-to-end — provisions an SDWAN Virtual IP, a hub DNAT port mapping (443 for https / 80 for http), an ACME TLS certificate for the hostname, and regenerates the reverse proxy. Use this when an operator asks to 'make <service> reachable from the internet at <hostname>', 'put a public endpoint in front of <instance>', or otherwise publish an internal service with TLS.",
          category: "devops",
          requires_approval: true,
          inputs: {
            service_hostname:  { type: "string",  required: true,
                                 description: "Public DNS hostname the service will answer on, e.g. app.example.com" },
            service_protocol:  { type: "string",  required: true,
                                 description: "Public-facing protocol: http or https" },
            sdwan_network_id:  { type: "string",  required: true,
                                 description: "SDWAN network the VIP + port mapping live in" },
            sdwan_hub_peer_id: { type: "string",  required: true,
                                 description: "Publicly-reachable hub peer that terminates the public port" },
            vip_cidr:          { type: "string",  required: true,
                                 description: "Operator-supplied host CIDR for the VIP (typically a /128 v6 or /32 v4) within the SDWAN network's /64" },
            target_peer_id:     { type: "string", required: false,
                                  description: "Backend peer to front (provide exactly one of target_peer_id / target_instance_id)" },
            target_instance_id: { type: "string", required: false,
                                  description: "Backend NodeInstance to front (provide exactly one of target_peer_id / target_instance_id)" },
            backend_port:      { type: "integer", required: true,
                                 description: "Port the backend service listens on (the DNAT target_port)" },
            tls_issuer:        { type: "string",  required: false, default: "letsencrypt-prod",
                                 description: "ACME issuer slug for the certificate" },
            challenge_type:    { type: "string",  required: false, default: "dns-01",
                                 description: "ACME challenge type (dns-01 / http-01)" },
            dns_credential_id: { type: "string",  required: false,
                                 description: "Credential id for the DNS provider (dns-01 challenges)" }
          },
          outputs: {
            service_hostname:   :string,
            vip_id:             :string,
            vip_cidr:           :string,
            port_mapping_id:    :string,
            certificate_id:     :string,
            certificate_status: :string,
            public_endpoints:   [ :string ],
            steps_completed:    [ :string ],
            warnings:           [ :string ]
          }
        )

        binds_to "System Concierge"

        protected

        def perform(service_hostname:, service_protocol:, sdwan_network_id:, sdwan_hub_peer_id:,
                    vip_cidr:, backend_port:, target_peer_id: nil, target_instance_id: nil,
                    tls_issuer: "letsencrypt-prod", challenge_type: "dns-01",
                    dns_credential_id: nil, **_extra)
          protocol = service_protocol.to_s.downcase
          unless PROTOCOLS.include?(protocol)
            return failure("service_protocol must be one of: #{PROTOCOLS.join(', ')}")
          end

          # Exactly one backend target — XOR.
          if target_peer_id.present? == target_instance_id.present?
            return failure("provide exactly one of target_peer_id or target_instance_id")
          end

          # Resolve the backend target to a concrete holder peer. A VIP with no
          # holder fronts nothing, so we refuse to create one (fix #4).
          if target_instance_id.present?
            resolved_peer = resolve_instance_to_peer(
              network_id: sdwan_network_id, instance_id: target_instance_id
            )
            return resolved_peer unless resolved_peer[:success]

            target_peer_id = resolved_peer[:peer_id]
          end

          # For https exposures the certificate step is a hard requirement.
          # Validate dns-01 prerequisites up front so we fail fast and clearly
          # rather than after creating a VIP + port mapping (fix #2).
          if protocol == "https" && challenge_type.to_s == "dns-01" && dns_credential_id.blank?
            return failure("dns_credential_id is required for https exposures using the dns-01 challenge")
          end

          steps    = []
          warnings = []

          # ── Step 1: Virtual IP (reuse-by-name) ─────────────────────────
          vip_result = ensure_virtual_ip(
            network_id: sdwan_network_id,
            hostname: service_hostname,
            vip_cidr: vip_cidr,
            target_peer_id: target_peer_id
          )
          return vip_result unless vip_result[:success]

          vip_id   = vip_result[:vip_id]
          vip_cidr = vip_result[:vip_cidr]
          steps << vip_result[:step]

          # ── Step 2: hub port mapping (hard requirement) ────────────────
          listen_port = protocol == "https" ? 443 : 80
          pm_result = create_port_mapping(
            network_id: sdwan_network_id,
            hub_peer_id: sdwan_hub_peer_id,
            hostname: service_hostname,
            listen_port: listen_port,
            target_virtual_ip_id: vip_id,
            target_port: backend_port
          )
          unless pm_result[:success]
            return failure("port mapping creation failed: #{pm_result[:error]}")
          end

          port_mapping_id = pm_result[:port_mapping_id]
          steps << "create_port_mapping"

          # ── Step 3: ACME certificate ──────────────────────────────────
          # https: the cert is a hard requirement — a failure aborts the whole
          # expose (no TLS means the public endpoint is broken). http: skip the
          # cert step entirely (no TLS to provision) (fix #2).
          certificate_id     = nil
          certificate_status = nil
          if protocol == "https"
            cert_result = ensure_certificate(
              hostname: service_hostname,
              issuer: tls_issuer,
              challenge_type: challenge_type,
              dns_credential_id: dns_credential_id
            )
            unless cert_result[:success]
              return failure("certificate provisioning failed: #{cert_result[:error]}")
            end

            certificate_id     = cert_result[:certificate_id]
            certificate_status = cert_result[:certificate_status]
            steps << cert_result[:step]

            # ── Step 4: reverse-proxy regen (hard requirement for https) ──
            proxy_result = regenerate_reverse_proxy(certificate_id: certificate_id)
            unless proxy_result[:success]
              return failure("reverse proxy regen failed: #{proxy_result[:error]}")
            end

            steps << "reverse_proxy_regen"
          end

          success(
            service_hostname: service_hostname,
            vip_id: vip_id,
            vip_cidr: vip_cidr,
            port_mapping_id: port_mapping_id,
            certificate_id: certificate_id,
            certificate_status: certificate_status,
            public_endpoints: [ "#{protocol}://#{service_hostname}" ],
            steps_completed: steps,
            warnings: warnings
          )
        end

        private

        # ── Backend resolution: NodeInstance → holder Sdwan::Peer (fix #4) ──
        # target_instance_id only fronts a real address if it resolves to a
        # peer we can seat as the VIP holder. Sdwan::Peer belongs_to a
        # NodeInstance, so we look the peer up within the target network +
        # account. No peer ⇒ reject (never create a holderless VIP).
        def resolve_instance_to_peer(network_id:, instance_id:)
          peer = ::Sdwan::Peer
                   .where(account_id: @account.id, sdwan_network_id: network_id,
                          node_instance_id: instance_id)
                   .first
          unless peer
            return failure("target_instance_id #{instance_id} has no SDWAN peer in network #{network_id}; " \
                           "attach the instance to the network first or pass target_peer_id")
          end

          { success: true, peer_id: peer.id }
        end

        # ── Step 1 helper: create or reuse a VIP by name in the network ──
        def ensure_virtual_ip(network_id:, hostname:, vip_cidr:, target_peer_id:)
          vip_name = "expose-#{hostname}"

          existing = ::Sdwan::VirtualIp
                       .joins(:network)
                       .where(system_sdwan_networks: { account_id: @account.id })
                       .find_by(sdwan_network_id: network_id, name: vip_name)
          if existing
            return { success: true, vip_id: existing.id, vip_cidr: existing.cidr,
                     step: "reuse_virtual_ip" }
          end

          params = {
            action: "system_sdwan_create_virtual_ip",
            network_id: network_id,
            name: vip_name,
            cidr: vip_cidr,
            anycast: false
          }
          # When fronting a specific backend peer, seat it as the primary
          # holder so the VIP resolves to a real address.
          params[:holder_peer_ids] = [ target_peer_id ] if target_peer_id.present?

          result = tool(::Ai::Tools::SdwanTool).execute(params: params)
          unless result[:success]
            return failure("VIP creation failed: #{result[:error]}")
          end

          payload = result[:data] || {}
          vip = payload[:virtual_ip] || payload["virtual_ip"] || payload
          { success: true,
            vip_id: vip[:id] || vip["id"] || payload[:virtual_ip_id] || payload["virtual_ip_id"],
            vip_cidr: vip[:cidr] || vip["cidr"] || payload[:cidr] || payload["cidr"],
            step: "create_virtual_ip" }
        end

        # ── Step 2 helper: hub DNAT port mapping ─────────────────────────
        def create_port_mapping(network_id:, hub_peer_id:, hostname:, listen_port:,
                                target_virtual_ip_id:, target_port:)
          result = tool(::Ai::Tools::SdwanTool).execute(params: {
            action: "system_sdwan_create_port_mapping",
            network_id: network_id,
            hub_peer_id: hub_peer_id,
            name: "expose-#{hostname}-#{listen_port}",
            listen_port: listen_port,
            protocol: "tcp",
            target_virtual_ip_id: target_virtual_ip_id,
            target_port: target_port,
            enabled: true
          })
          return { success: false, error: result[:error] } unless result[:success]

          payload = result[:data] || {}
          pm = payload[:port_mapping] || payload["port_mapping"] || payload
          { success: true,
            port_mapping_id: pm[:id] || pm["id"] || payload[:port_mapping_id] || payload["port_mapping_id"] }
        end

        # ── Step 3 helper: reuse a valid cert or provision a new one ─────
        def ensure_certificate(hostname:, issuer:, challenge_type:, dns_credential_id:)
          existing = ::System::AcmeCertificate
                       .where(account_id: @account.id, common_name: hostname, status: "valid")
                       .where("expires_at IS NULL OR expires_at > ?", Time.current)
                       .order(expires_at: :desc)
                       .first
          if existing
            return { success: true, certificate_id: existing.id,
                     certificate_status: existing.status, step: "reuse_certificate" }
          end

          result = AcmeCertificateProvisionExecutor
                     .new(account: @account, agent: @agent, user: @user)
                     .execute(
                       common_name: hostname,
                       issuer: issuer,
                       challenge_type: challenge_type,
                       dns_credential_id: dns_credential_id
                     )
          return { success: false, error: result[:error] } unless result[:success]

          payload = result[:data] || {}
          { success: true,
            certificate_id: extract_certificate_id(payload),
            certificate_status: payload[:certificate_status] || payload["certificate_status"] ||
                                payload[:status] || payload["status"],
            step: "provision_certificate" }
        end

        def extract_certificate_id(payload)
          payload[:certificate_id] || payload["certificate_id"] ||
            payload.dig(:certificate, :id) || payload.dig("certificate", "id") ||
            payload[:id] || payload["id"]
        end

        # ── Step 4 helper: reverse-proxy regen for the issued cert ───────
        def regenerate_reverse_proxy(certificate_id:)
          result = ReverseProxyComposeExecutor
                     .new(account: @account, agent: @agent, user: @user)
                     .execute(certificate_id: certificate_id)
          return { success: false, error: result[:error] } unless result[:success]

          { success: true }
        rescue StandardError => e
          { success: false, error: e.message }
        end
      end
    end
  end
end
