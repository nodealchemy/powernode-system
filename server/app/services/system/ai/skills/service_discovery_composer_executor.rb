# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Skill: make a service discoverable across the fleet — SDWAN-native.
      #
      # North-star composer for Phase 3 (Federation & Multi-Site) service
      # discovery. Discovery rides the SDWAN overlay end-to-end; there is no
      # k8s-native CoreDNS / NetworkPolicy seam. The one thing the overlay
      # cannot do — answer a name on the *public internet* — is delegated to
      # the existing ACME DNS adapters, and ONLY for internet-facing names.
      #
      # Composition shape (synchronous sibling/service calls, IDs threaded in
      # plain Ruby, reverse-order rollback):
      #
      #   1. SDWAN Virtual IP   — a stable overlay address fronting the
      #      backend peer (Sdwan::Executors::CreateVirtualIp). Advertisement
      #      across the fabric is automatic: the iBGP config compiler's
      #      `vip_cidrs_held_by` announces any active/pending VIP whose
      #      primary holder is the peer, so every other peer learns the
      #      route — that IS the in-overlay discovery substrate.
      #   2. Service catalog    — a VIP-backed Federation::ServiceOffering so
      #      federated peers can browse + subscribe to the service
      #      (Federation::ServiceCatalogService surfaces the catalog; the
      #      offering's backend_vip_id makes the advertised backend
      #      failover-aware).
      #   3. Local Traefik route — regenerate the subscriber-side dynamic
      #      config so any local ServiceSubscription rows materialize their
      #      routes (Federation::ServiceRouteWriter).
      #   4. External DNS (OPTIONAL, internet-facing only) — when the operator
      #      supplies a public DNS name + provider credential, resolve the
      #      VIP address and publish an A/AAAA/CNAME via the existing
      #      Acme::DnsClient adapter. No public-DNS = no DNS step.
      #
      # Step semantics:
      #   - VIP creation is a HARD requirement; failure aborts.
      #   - Catalog offering is a HARD requirement (the whole point is
      #     discoverability); failure aborts + rolls back the VIP.
      #   - Traefik regen is SOFT — a failure is collected as a warning and
      #     the skill still returns success (the writer is idempotent; the
      #     operator can re-run it). Routes only exist for active
      #     subscriptions, which may legitimately be zero at offer time.
      #   - External DNS is SOFT — a failure is a warning, not an abort (the
      #     overlay discovery + catalog already work without it).
      #
      # Reuse semantics:
      #   - VIP: reused when a VIP with the same name already exists in the
      #     network (idempotent re-runs don't pile up VIPs).
      #   - Offering: reused when an offering with the same slug already
      #     exists for the account (the slug is the catalog's natural key);
      #     its backend_vip_id is repointed at the (possibly reused) VIP.
      #
      # Rollback (reverse order): delete the DNS record (if created) → revert
      # the offering (delete if we created it, else detach the VIP) → delete
      # the VIP (if we created it). The Traefik regen has no discrete
      # resource to undo — it's a file the writer fully rewrites each run.
      class ServiceDiscoveryComposerExecutor < BaseSkillExecutor
        DNS_RECORD_TYPES = %w[A AAAA CNAME].freeze

        skill_descriptor(
          name: "service_discovery_composer",
          description: "Make a backend service discoverable across the fleet over the SDWAN overlay end-to-end — provisions a Virtual IP (auto-advertised via iBGP for in-overlay discovery), publishes a VIP-backed federation service-catalog offering for federated peers, regenerates the local Traefik routes, and OPTIONALLY publishes a public DNS record (A/AAAA/CNAME) for internet-facing names. Use this when an operator asks to 'make <service> discoverable', 'publish <service> to the service catalog', or 'advertise <service> to other sites'.",
          category: "devops",
          requires_approval: true,
          invocation_mode: "one_shot",
          domain: "system",
          tags: %w[sdwan federation discovery service-catalog dns],
          inputs: {
            service_name:     { type: "string", required: true,
                                description: "Human-readable name of the service (catalog display name)" },
            service_slug:     { type: "string", required: true,
                                description: "Lowercase-alphanumeric-hyphen slug — the catalog's natural key (also names the VIP). e.g. 'orders-api'" },
            sdwan_network_id: { type: "string", required: true,
                                description: "SDWAN network the VIP lives in" },
            backend_peer_id:  { type: "string", required: true,
                                description: "Sdwan::Peer that hosts the service; seated as the VIP's primary holder (and thus the iBGP advertiser)" },
            backend_port:     { type: "integer", required: true,
                                description: "Port the backend service listens on (advertised in the catalog offering)" },
            vip_cidr:         { type: "string", required: true,
                                description: "Operator-supplied host CIDR for the VIP (a /128 v6 or /32 v4) within the SDWAN network's /64" },
            protocol:         { type: "string", required: false, default: "https",
                                description: "Service protocol advertised in the catalog: one of https, http, tcp, tls" },
            grant_scopes:     { type: "array", required: false,
                                description: "Default FederationGrant scopes subscribers receive (subset of read, write, admin, migrate). Defaults to ['read']" },
            grant_ttl_days:   { type: "integer", required: false,
                                description: "Default grant TTL in days (>= 7). Defaults to the offering default" },
            traefik_dynamic_dir: { type: "string", required: false,
                                   description: "Override for the Traefik dynamic-config directory (defaults to /etc/traefik/dynamic)" },
            public_dns: { type: "object", required: false,
                          description: "INTERNET-FACING name only: { dns_credential_id, record_name, record_type? (A|AAAA|CNAME, default derived from the VIP family), record_content? (defaults to the VIP address for A/AAAA), ttl? }. Omit for overlay-only discovery." }
          },
          outputs: {
            service_slug:     :string,
            vip_id:           :string,
            vip_cidr:         :string,
            vip_address:      :string,
            offering_id:      :string,
            offering_slug:    :string,
            route_output_path: :string,
            route_count:      :integer,
            dns_record_id:    :string,
            dns_record_fqdn:  :string,
            public_dns_published: :boolean,
            steps_completed:  [ :string ],
            warnings:         [ :string ]
          },
          rollback: :rollback_service_discovery_composer,
          blast_radius: :medium
        )

        binds_to "System Topology Designer"

        # Rollback: reverse dependency order. DNS record → offering → VIP.
        # Each branch is independently guarded so a partial run rolls back
        # exactly what it created (created_offering / created_vip flags thread
        # through from the success payload). The Traefik regen has no discrete
        # resource — the writer rewrites the whole file each run.
        def rollback_service_discovery_composer(vip_id: nil, offering_id: nil,
                                                created_vip: false, created_offering: false,
                                                dns_record_id: nil, dns_rollback: nil,
                                                **_extras)
          errors = []

          # ── DNS record (if we published one) ──────────────────────────
          if dns_record_id.present? && dns_rollback.is_a?(Hash)
            ctx = symbolize(dns_rollback)
            begin
              credential = find_dns_credential(ctx[:dns_credential_id])
              raise ArgumentError, "DNS credential not found: #{ctx[:dns_credential_id]}" unless credential

              client = dns_client_for(credential)
              result = client.delete_record(ctx[:zone_id], dns_record_id)
              unless result.ok?
                errors << { resource: "dns_record", id: dns_record_id, error: result.error }
              end
            rescue StandardError => e
              errors << { resource: "dns_record", id: dns_record_id, error: e.message }
            end
          end

          # ── Offering: delete if created, else detach the VIP ──────────
          if offering_id.present?
            offering = ::System::Federation::ServiceOffering
                         .where(account_id: @account.id).find_by(id: offering_id)
            if offering
              begin
                if created_offering
                  offering.destroy!
                elsif offering.backend_vip_id == vip_id
                  # We only repointed an existing offering — null the VIP back
                  # out so the offering survives but no longer references a
                  # VIP we're about to delete.
                  offering.update!(backend_vip_id: nil)
                end
              rescue StandardError => e
                errors << { resource: "service_offering", id: offering_id, error: e.message }
              end
            end
          end

          # ── VIP (if we created it) ────────────────────────────────────
          if created_vip && vip_id.present?
            vip = ::Sdwan::VirtualIp.where(account_id: @account.id).find_by(id: vip_id)
            if vip
              begin
                vip.destroy!
              rescue StandardError => e
                errors << { resource: "sdwan_virtual_ip", id: vip_id, error: e.message }
              end
            end
          end

          { success: errors.empty?, errors: errors }
        end

        protected

        def perform(service_name:, service_slug:, sdwan_network_id:, backend_peer_id:,
                    backend_port:, vip_cidr:, protocol: "https", grant_scopes: nil,
                    grant_ttl_days: nil, traefik_dynamic_dir: nil, public_dns: nil, **_extra)
          proto = protocol.to_s.downcase
          unless ::System::Federation::ServiceOffering::PROTOCOLS.include?(proto)
            return failure("protocol must be one of: #{::System::Federation::ServiceOffering::PROTOCOLS.join(', ')}")
          end

          slug = service_slug.to_s.strip
          return failure("service_slug is required") if slug.empty?

          # Verify the network + backend peer belong to this account up front
          # so we never half-build discovery on a stranger's resources.
          network = ::Sdwan::Network.where(account_id: @account.id).find_by(id: sdwan_network_id)
          return failure("SDWAN network not found: #{sdwan_network_id}") unless network

          peer = ::Sdwan::Peer.where(account_id: @account.id,
                                     sdwan_network_id: sdwan_network_id).find_by(id: backend_peer_id)
          unless peer
            return failure("backend_peer_id #{backend_peer_id} is not a peer in network #{sdwan_network_id}")
          end

          steps    = []
          warnings = []

          # ── Step 1: Virtual IP (hard requirement; reuse-by-name) ───────
          vip_result = ensure_virtual_ip(
            network: network, slug: slug, vip_cidr: vip_cidr, holder_peer_id: peer.id
          )
          return vip_result unless vip_result[:success]

          vip          = vip_result[:vip]
          vip_id       = vip.id
          vip_cidr_out = vip.cidr
          vip_address  = address_from_cidr(vip.cidr)
          created_vip  = vip_result[:created]
          steps << vip_result[:step]

          # ── Step 2: catalog offering (hard requirement; reuse-by-slug) ─
          offering_result = ensure_offering(
            slug: slug, name: service_name, protocol: proto, backend_port: backend_port,
            vip: vip, grant_scopes: grant_scopes, grant_ttl_days: grant_ttl_days
          )
          unless offering_result[:success]
            # Roll back the VIP we created before aborting (only if WE made it).
            rollback_service_discovery_composer(vip_id: vip_id, created_vip: created_vip)
            return failure("service catalog offering failed: #{offering_result[:error]}")
          end

          offering          = offering_result[:offering]
          created_offering  = offering_result[:created]
          steps << offering_result[:step]

          # ── Step 3: local Traefik route regen (soft) ──────────────────
          route_output_path = nil
          route_count       = nil
          route_result = regenerate_routes(dynamic_dir: traefik_dynamic_dir)
          if route_result[:success]
            route_output_path = route_result[:output_path]
            route_count       = route_result[:route_count]
            steps << "regenerate_traefik_routes"
          else
            warnings << "traefik route regen failed: #{route_result[:error]}"
          end

          # ── Step 4: external DNS (soft; internet-facing only) ─────────
          dns_record_id   = nil
          dns_record_fqdn = nil
          dns_rollback    = nil
          dns_published   = false
          if public_dns.present?
            dns_result = publish_public_dns(
              public_dns: symbolize(public_dns), vip_address: vip_address, vip_cidr: vip.cidr
            )
            if dns_result[:success]
              dns_record_id   = dns_result[:record_id]
              dns_record_fqdn = dns_result[:fqdn]
              dns_rollback    = dns_result[:rollback]
              dns_published   = true
              steps << "publish_public_dns"
            else
              warnings << "public DNS publish failed: #{dns_result[:error]}"
            end
          end

          success(
            service_slug: slug,
            vip_id: vip_id,
            vip_cidr: vip_cidr_out,
            vip_address: vip_address,
            offering_id: offering.id,
            offering_slug: offering.slug,
            route_output_path: route_output_path,
            route_count: route_count,
            dns_record_id: dns_record_id,
            dns_record_fqdn: dns_record_fqdn,
            public_dns_published: dns_published,
            steps_completed: steps,
            warnings: warnings,
            # ── Rollback context (threaded into rollback_*) ─────────────
            created_vip: created_vip,
            created_offering: created_offering,
            dns_rollback: dns_rollback
          )
        end

        private

        # ── Step 1 helper: create or reuse a VIP by name in the network ──
        # Composes Sdwan::Executors::CreateVirtualIp (the canonical VIP
        # primitive). The executor's #perform only reads params[:network_id]
        # + params[:attributes]; the network row already scopes the account,
        # so deferred_operation can be nil here.
        def ensure_virtual_ip(network:, slug:, vip_cidr:, holder_peer_id:)
          vip_name = "discovery-#{slug}"

          existing = network.virtual_ips.find_by(name: vip_name)
          if existing
            # Idempotent re-run: ensure the backend peer is seated as the
            # primary holder so the iBGP advertisement still points at it.
            unless Array(existing.holder_peer_ids).first == holder_peer_id
              existing.update!(
                holder_peer_ids: ([ holder_peer_id ] + Array(existing.holder_peer_ids)).uniq,
                state: existing.state == "pending" ? "active" : existing.state
              )
            end
            return { success: true, vip: existing, created: false, step: "reuse_virtual_ip" }
          end

          result = ::Sdwan::Executors::CreateVirtualIp.execute(
            {
              network_id: network.id,
              attributes: {
                name: vip_name,
                cidr: vip_cidr,
                holder_peer_ids: [ holder_peer_id ],
                state: "active",
                anycast: false
              }
            },
            deferred_operation: nil
          )
          return failure("VIP creation failed: #{result[:error] || 'unknown error'}") unless result[:success]

          vip = ::Sdwan::VirtualIp.find(result.dig(:data, :vip_id))
          { success: true, vip: vip, created: true, step: "create_virtual_ip" }
        rescue ActiveRecord::RecordInvalid => e
          failure("VIP creation failed: #{e.message}")
        end

        # ── Step 2 helper: create or reuse a VIP-backed catalog offering ──
        # The offering is what makes the service discoverable to FEDERATED
        # peers (Federation::ServiceCatalogService.list_active_offerings reads
        # these). backend_vip_id makes the advertised backend failover-aware
        # (the catalog resolves backend_address via the VIP).
        def ensure_offering(slug:, name:, protocol:, backend_port:, vip:,
                            grant_scopes:, grant_ttl_days:)
          scopes = normalize_scopes(grant_scopes)
          ttl    = normalize_ttl(grant_ttl_days)

          existing = ::System::Federation::ServiceOffering
                       .find_by(account_id: @account.id, slug: slug)
          if existing
            attrs = {
              name: name,
              protocol: protocol,
              backend_port: backend_port,
              backend_vip_id: vip.id,
              default_grant_scopes: scopes
            }
            attrs[:default_grant_ttl_days] = ttl if ttl
            existing.update!(attrs)
            return { success: true, offering: existing, created: false, step: "reuse_offering" }
          end

          attrs = {
            account: @account,
            slug: slug,
            name: name,
            protocol: protocol,
            backend_port: backend_port,
            backend_vip_id: vip.id,
            status: "active",
            default_grant_scopes: scopes
          }
          attrs[:default_grant_ttl_days] = ttl if ttl

          offering = ::System::Federation::ServiceOffering.create!(**attrs)
          { success: true, offering: offering, created: true, step: "create_offering" }
        rescue ActiveRecord::RecordInvalid => e
          failure(e.message)
        end

        # ── Step 3 helper: regenerate the subscriber-side Traefik config ──
        def regenerate_routes(dynamic_dir:)
          args = { account: @account }
          args[:dynamic_dir] = dynamic_dir if dynamic_dir.present?
          result = ::Federation::ServiceRouteWriter.write!(**args)
          { success: true, output_path: result[:output_path], route_count: result[:route_count] }
        rescue StandardError => e
          { success: false, error: e.message }
        end

        # ── Step 4 helper: publish a PUBLIC-INTERNET DNS record ───────────
        # Thin wrapper over the existing Acme::DnsClient adapters. Resolves
        # the VIP address (A/AAAA) or honors an operator-supplied CNAME
        # target, finds the hosting zone, and creates the record. Returns a
        # rollback context (zone_id + credential) so teardown can delete it.
        def publish_public_dns(public_dns:, vip_address:, vip_cidr:)
          credential_id = public_dns[:dns_credential_id]
          record_name   = public_dns[:record_name].to_s.strip
          return { success: false, error: "public_dns.dns_credential_id is required" } if credential_id.blank?
          return { success: false, error: "public_dns.record_name is required" } if record_name.empty?

          record_type = (public_dns[:record_type].presence || default_record_type(vip_cidr)).to_s.upcase
          unless DNS_RECORD_TYPES.include?(record_type)
            return { success: false, error: "public_dns.record_type must be one of: #{DNS_RECORD_TYPES.join(', ')}" }
          end

          content = public_dns[:record_content].presence ||
                    (record_type == "CNAME" ? nil : vip_address)
          if content.blank?
            return { success: false, error: "public_dns.record_content is required for #{record_type} records" }
          end

          credential = find_dns_credential(credential_id)
          return { success: false, error: "DNS credential not found: #{credential_id}" } unless credential

          client = dns_client_for(credential)
          zone_id = resolve_zone_id(client: client, record_name: record_name)
          return { success: false, error: "no hosted zone found for #{record_name} on #{credential.provider}" } if zone_id.blank?

          ttl = (public_dns[:ttl] || 300).to_i
          result = client.create_record(
            zone_id, type: record_type, name: record_name, content: content, ttl: ttl
          )
          return { success: false, error: result.error } unless result.ok?

          {
            success: true,
            record_id: extract_dns_record_id(result.data),
            fqdn: record_name,
            rollback: { dns_credential_id: credential_id, zone_id: zone_id }
          }
        rescue StandardError => e
          { success: false, error: e.message }
        end

        # Look up an AcmeDnsCredential scoped to this account. Loaded ONCE per
        # DNS op (publish / rollback) and threaded into dns_client_for so the
        # credential is never re-fetched.
        def find_dns_credential(credential_id)
          ::System::AcmeDnsCredential.find_by(id: credential_id, account: @account)
        end

        # Build an Acme::DnsClient for an already-loaded credential. Pulls the
        # api_token from Vault via the same provider the records controller
        # uses, so secret material never leaves Vault → adapter.
        def dns_client_for(credential)
          plaintext = vault_provider.get_credential(
            credential_type: :acme_dns, credential_id: credential.id, record: credential
          )
          api_token = plaintext.is_a?(Hash) ? (plaintext["api_token"] || plaintext[:api_token]) : nil
          raise ArgumentError, "stored credential #{credential.id} has no api_token" if api_token.blank?

          ::Acme::DnsClient.for(provider: credential.provider, api_token: api_token)
        end

        def vault_provider
          @vault_provider ||= ::Security::VaultCredentialProvider.new(account_id: @account.id)
        end

        # Find the hosting zone for a record name: list the provider's zones and
        # pick the longest zone name the record is a suffix of (the standard
        # "closest parent zone" match).
        #
        # TODO(dns-zone-resolution): the DNS-01 challenge path (Acme::LegoClient /
        # the Acme::BaseDnsClient adapters) resolves the hosting zone the same
        # way but has no extracted, reusable helper today. When that logic is
        # promoted to a shared Acme::BaseDnsClient#find_zone_id (or equivalent),
        # delete resolve_zone_id/suffix_match? here and call the shared helper so
        # there is one closest-parent-zone implementation, not two.
        def resolve_zone_id(client:, record_name:)
          result = client.list_zones(per_page: 50)
          return nil unless result.ok?

          zones = Array(result.data)
          name  = record_name.downcase
          best  = zones
                    .map { |z| [ z["name"] || z[:name], z["id"] || z[:id] ] }
                    .select { |zname, zid| zname.present? && zid.present? && suffix_match?(name, zname.downcase) }
                    .max_by { |zname, _| zname.length }
          best&.last
        end

        def suffix_match?(record_name, zone_name)
          record_name == zone_name || record_name.end_with?(".#{zone_name}")
        end

        def extract_dns_record_id(data)
          return nil unless data.is_a?(Hash)

          data["id"] || data[:id] || data.dig("result", "id") || data.dig(:result, :id)
        end

        def default_record_type(vip_cidr)
          vip_cidr.to_s.include?(":") ? "AAAA" : "A"
        end

        def address_from_cidr(cidr)
          cidr.to_s.split("/", 2).first
        end

        def normalize_scopes(grant_scopes)
          scopes = Array(grant_scopes).map(&:to_s).reject(&:empty?)
          scopes.presence || %w[read]
        end

        def normalize_ttl(grant_ttl_days)
          return nil if grant_ttl_days.nil?

          ttl = grant_ttl_days.to_i
          min = ::System::Federation::ServiceOffering::MIN_GRANT_TTL_DAYS
          ttl < min ? min : ttl
        end

        # AI tool-call payloads arrive string-keyed from the MCP transport;
        # Ruby keyword/dig access wants symbols. Normalize at the boundary.
        def symbolize(h)
          return {} unless h.is_a?(Hash)

          h.each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
        end
      end
    end
  end
end
