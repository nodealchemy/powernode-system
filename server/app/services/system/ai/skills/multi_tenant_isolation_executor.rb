# frozen_string_literal: true

module System
  module Ai
    module Skills
      # 3b-3 — multi_tenant_isolation (SDWAN-native composition).
      #
      # Stands up a fully-isolated network slice for ONE tenant inside the
      # executing account, composed entirely from existing SDWAN production
      # services. No k8s NetworkPolicy, no VLAN, no CoreDNS — isolation and
      # forwarding live on the SDWAN overlay (WireGuard + per-network VRF +
      # iBGP + nftables + OVN ACLs).
      #
      # Composition shape (IDs threaded inline, plain Ruby):
      #
      #   1. Sdwan::Executors::CreateNetwork (routing_protocol: "ibgp")
      #        → separate VRF + isolated RIB. Each network gets a distinct
      #          `network_handle` → a dedicated VRF master device
      #          (`sdwan-<handle>`), so the tenant's iBGP RIB never shares a
      #          forwarding table with any other tenant's network. Composed
      #          through the canonical `Sdwan::Executors::CreateNetwork`
      #          capability so account-scoping + default attributes live in
      #          one place (mirroring how the OVN steps compose their sibling
      #          executors and how ServiceDiscoveryComposerExecutor composes
      #          Sdwan::Executors::CreateVirtualIp).
      #   2. Sdwan::PrefixAllocator.allocate_network_cidr!
      #        → invoked transitively by the Network create callback; carves a
      #          non-overlapping /64 from the account's /48 (rejection-sampled
      #          against sibling tenant networks). The resulting CIDR is the
      #          tenant's blast-radius boundary and seeds the firewall + ACL
      #          selectors below.
      #   3. N × Sdwan::Executors::CreateFirewallRule  (nftables)
      #        → composed through the canonical
      #          `Sdwan::Executors::CreateFirewallRule` capability
      #          (`network.firewall_rules.create!(attrs)`). Two rules per
      #          tenant: an explicit allow for the tenant's own /64 (intra-
      #          tenant east-west) at high priority, then a default-deny
      #          wildcard at low priority. Compiles to `table inet
      #          powernode_sdwan` on every peer in the network.
      #   4. SdwanOvnComposeTopologyExecutor  (sibling executor)
      #        → one OVN logical switch named for the tenant, scoped to the
      #          tenant CIDR. Heavyweight-profile intra-host L2 domain.
      #   5. SdwanOvnApplyAclExecutor  (sibling executor)
      #        → tenant-CIDR OVN ACLs on that switch: allow intra-tenant
      #          (ip src/dst in tenant CIDR), drop everything sourced outside
      #          the tenant CIDR. nftables (inter-host, step 3) and OVN ACLs
      #          (intra-host, step 5) cover the two non-overlapping scopes.
      #
      # Every persisted artifact carries account_id == @account.id; nothing
      # is shared across tenants except the account-level OvnDeployment (one
      # per account by DB unique index — reused, never duplicated).
      #
      # Rollback (reverse order): OVN ACLs → OVN switch → firewall rules →
      # network. Destroying the network cascades to firewall_rules via
      # dependent: :destroy, but we tear them down explicitly first to keep
      # audit-trail granularity and to mirror the rollback-ordering
      # convention in ConfigureSdwanForProjectExecutor.
      #
      # Phase 3 (Federation & Multi-Site) — slice 3b-3.
      class MultiTenantIsolationExecutor < BaseSkillExecutor
        # Accepts any IPv6 CIDR. PrefixAllocator emits fd…::/64 ULAs, but an
        # operator may supply an fc00::/7 ULA or a delegated global-unicast
        # tenant CIDR — anchoring to "fd" would wrongly reject those valid
        # inputs. IPv4 form is accepted for operators carrying a legacy tenant
        # CIDR over the overlay; both feed the OVN match family selector below.
        IPV6_CIDR = %r{\A[0-9a-f:]+/\d{1,3}\z}i
        IPV4_CIDR = %r{\A(?:\d{1,3}\.){3}\d{1,3}/\d{1,2}\z}

        # nftables firewall rule priorities — explicit allow must evaluate
        # before the default-deny wildcard (lower number = higher priority,
        # per Sdwan::FirewallRule.ordered → order(:priority, :name)).
        ALLOW_PRIORITY = 100
        DENY_PRIORITY  = 1000

        # OVN ACL priorities — higher evaluated first (per OVN's documented
        # tiebreaker, surfaced through Sdwan::OvnAcl).
        ACL_ALLOW_PRIORITY = 2000
        ACL_DENY_PRIORITY  = 1000

        skill_descriptor(
          name: "multi_tenant_isolation",
          description: "Provision a fully-isolated SDWAN network slice for a single tenant inside the account: a dedicated overlay network with its own VRF + isolated iBGP RIB (no shared routing table), a non-overlapping /64 (Sdwan::PrefixAllocator), default-deny nftables firewall rules scoped to the tenant CIDR, an OVN logical switch, and tenant-CIDR OVN ACLs. Composes Sdwan::Network + Sdwan::PrefixAllocator + Sdwan::FirewallRule + SdwanOvnComposeTopologyExecutor + SdwanOvnApplyAclExecutor. SDWAN-native — no k8s NetworkPolicy, no VLAN. Use when an operator asks to 'isolate tenant <X>', 'give <tenant> its own segregated network', or 'stand up a blast-radius boundary for <tenant>'.",
          category: "federation",
          requires_approval: true,
          inputs: {
            tenant_key: { type: "string", required: true,
                          description: "Stable tenant identifier within the account (slug-safe; used to name the network, firewall rules, OVN switch, and ACLs). e.g. 'acme-prod'." },
            network_name: { type: "string", required: false,
                            description: "Display name for the tenant's Sdwan::Network (defaults to 'tenant-<tenant_key>')." },
            tenant_cidr: { type: "string", required: false,
                           description: "Explicit tenant CIDR for the firewall + ACL selectors. When omitted, the /64 auto-allocated for the new network (PrefixAllocator) is used — the recommended path." },
            nb_db_endpoint: { type: "string", required: false,
                              description: "OVN NB DB endpoint (e.g. tcp:127.0.0.1:6641) — required only when the account has no Sdwan::OvnDeployment yet." },
            sb_db_endpoint: { type: "string", required: false,
                              description: "OVN SB DB endpoint (e.g. tcp:127.0.0.1:6642) — required only when the account has no Sdwan::OvnDeployment yet." },
            ovn_switch_name: { type: "string", required: false,
                               description: "Override the OVN logical switch name (defaults to 'ls-tenant-<tenant_key>')." },
            dry_run: { type: "boolean", required: false, default: false,
                       description: "Plan only — no Sdwan rows are persisted." }
          },
          outputs: {
            dry_run: :boolean,
            tenant_key: :string,
            tenant_cidr: :string,
            planned_actions: [ :object ],
            outputs: {
              sdwan_network_id: :string,
              sdwan_network_handle: :string,
              vrf_name: :string,
              tenant_cidr: :string,
              firewall_rule_ids: [ :string ],
              ovn_deployment_id: :string,
              ovn_logical_switch_id: :string,
              ovn_acl_ids: [ :string ],
              ovn_acl_allocations: [ :object ]
            },
            failures: [ :object ],
            partial: :boolean
          },
          rollback: :rollback_multi_tenant_isolation,
          blast_radius: :high
        )

        binds_to "System Topology Designer"

        # Rollback in reverse dependency order: OVN ACLs → OVN switch →
        # firewall rules → network. The OVN steps delegate to the sibling
        # executors' own rollbacks so reuse semantics (don't destroy a
        # pre-existing account deployment, leave reused ACLs alone) are
        # honored. Errors are collected, not raised — a half-torn-down
        # tenant must still surface every resource it couldn't reclaim.
        def rollback_multi_tenant_isolation(ovn_acl_allocations: [], ovn_logical_switch_id: nil,
                                            ovn_deployment_id: nil, created_ovn_deployment: false,
                                            firewall_rule_ids: [], sdwan_network_id: nil,
                                            **_extras)
          errors = []

          # 1. OVN ACLs — reuse the sibling's rollback (skips reused rows).
          if Array(ovn_acl_allocations).any?
            acl_rb = ovn_acl_executor.rollback_sdwan_ovn_apply_acl(allocations: ovn_acl_allocations)
            errors.concat(Array(acl_rb[:errors])) unless acl_rb[:success]
          end

          # 2. OVN logical switch (+ deployment only if this run created it)
          #    — reuse the compose executor's rollback for correct ordering.
          if ovn_logical_switch_id.present?
            switch_rb = ovn_compose_executor.rollback_sdwan_ovn_compose_topology(
              ovn_deployment_id: ovn_deployment_id,
              logical_switch_ids: [ ovn_logical_switch_id ],
              logical_switch_port_ids: [],
              created_deployment: created_ovn_deployment
            )
            errors.concat(Array(switch_rb[:errors])) unless switch_rb[:success]
          end

          # 3. Firewall rules.
          Array(firewall_rule_ids).reverse_each do |rule_id|
            rule = ::Sdwan::FirewallRule.where(account_id: @account.id).find_by(id: rule_id)
            next unless rule

            begin
              rule.destroy!
            rescue StandardError => e
              errors << { resource: "sdwan_firewall_rule", id: rule_id, error: e.message }
            end
          end

          # 4. Network (cascades to any remaining firewall_rules).
          if sdwan_network_id.present?
            network = ::Sdwan::Network.where(account_id: @account.id).find_by(id: sdwan_network_id)
            if network
              begin
                network.destroy!
              rescue StandardError => e
                errors << { resource: "sdwan_network", id: sdwan_network_id, error: e.message }
              end
            end
          end

          { success: errors.empty?, errors: errors }
        end

        protected

        def perform(tenant_key:, network_name: nil, tenant_cidr: nil,
                    nb_db_endpoint: nil, sb_db_endpoint: nil,
                    ovn_switch_name: nil, dry_run: false, **_extras)
          key = tenant_key.to_s.strip
          return failure("tenant_key is required") if key.empty?

          net_name    = network_name.to_s.strip.presence || "tenant-#{key}"
          switch_name = ovn_switch_name.to_s.strip.presence || "ls-tenant-#{key}"

          # If an explicit tenant CIDR is supplied, validate it up front so we
          # fail before persisting anything. When omitted, we use the /64
          # PrefixAllocator carves for the new network (resolved post-create).
          explicit_cidr = tenant_cidr.to_s.strip.presence
          if explicit_cidr && !valid_cidr?(explicit_cidr)
            return failure("tenant_cidr must be an IPv4 or IPv6 CIDR (e.g. fd00:abcd:1::/64 or 10.20.0.0/16)")
          end

          existing_deployment = ::Sdwan::OvnDeployment.for_account(@account).first
          if existing_deployment.nil? &&
             (nb_db_endpoint.to_s.strip.empty? || sb_db_endpoint.to_s.strip.empty?)
            return failure("nb_db_endpoint and sb_db_endpoint are required when the account has no Sdwan::OvnDeployment yet")
          end

          if dry_run
            return success(
              dry_run: true,
              tenant_key: key,
              tenant_cidr: explicit_cidr,
              planned_actions: build_plan(net_name: net_name, switch_name: switch_name,
                                          tenant_cidr: explicit_cidr,
                                          creating_deployment: existing_deployment.nil?),
              outputs: {
                sdwan_network_id: nil,
                sdwan_network_handle: nil,
                vrf_name: nil,
                tenant_cidr: explicit_cidr,
                firewall_rule_ids: [],
                ovn_deployment_id: existing_deployment&.id,
                ovn_logical_switch_id: nil,
                ovn_acl_ids: [],
                ovn_acl_allocations: []
              },
              failures: [],
              partial: false
            )
          end

          run_execute(key: key, net_name: net_name, switch_name: switch_name,
                      explicit_cidr: explicit_cidr,
                      nb_db_endpoint: nb_db_endpoint, sb_db_endpoint: sb_db_endpoint,
                      existing_deployment: existing_deployment)
        end

        private

        # rubocop:disable Metrics/MethodLength, Metrics/AbcSize -- linear
        # composition-of-services pipeline mirroring the canonical
        # ConfigureSdwanForProjectExecutor#run_execute. Splitting it would
        # scatter the inline ID threading that makes the data flow legible.
        def run_execute(key:, net_name:, switch_name:, explicit_cidr:,
                        nb_db_endpoint:, sb_db_endpoint:, existing_deployment:)
          planned_actions = []
          failures = []

          # ── Step 1: dedicated, VRF-isolated overlay network ──────────────
          # routing_protocol: "ibgp" gives the tenant its own RIB; the
          # per-network handle yields a distinct VRF master device so no two
          # tenants share a kernel routing table. PrefixAllocator carves the
          # non-overlapping /64 transitively in the create callback. Composed
          # through Sdwan::Executors::CreateNetwork (the canonical capability).
          network =
            begin
              create_tenant_network(key: key, net_name: net_name)
            rescue StandardError => e
              failures << { step: "create_network", error: e.message }
              return finalize(planned_actions: planned_actions, failures: failures,
                              tenant_key: key, tenant_cidr: explicit_cidr,
                              sdwan_network: nil, tenant_cidr_resolved: explicit_cidr,
                              firewall_rule_ids: [], ovn_deployment_id: existing_deployment&.id,
                              created_ovn_deployment: false, ovn_logical_switch_id: nil,
                              ovn_acl_ids: [], ovn_acl_allocations: [])
            end

          tenant_cidr = explicit_cidr.presence || network.cidr_64
          planned_actions << { step: "create_network", network_id: network.id,
                               handle: network.network_handle, vrf_name: network.vrf_name_for,
                               tenant_cidr: tenant_cidr, routing_protocol: "ibgp" }

          # ── Step 2: nftables firewall rules scoped to the tenant CIDR ────
          firewall_rule_ids = []
          create_firewall_rules(network: network, key: key, tenant_cidr: tenant_cidr,
                                planned_actions: planned_actions, failures: failures,
                                firewall_rule_ids: firewall_rule_ids)

          # ── Step 3: OVN logical switch (sibling compose executor) ────────
          switch_result = ovn_compose_executor.execute(
            switches: [ { name: switch_name, cidr: ovn_switch_cidr(tenant_cidr) } ],
            nb_db_endpoint: nb_db_endpoint,
            sb_db_endpoint: sb_db_endpoint
          )
          unless switch_result[:success]
            failures << { step: "compose_ovn_switch", error: switch_result[:error] }
            return finalize(planned_actions: planned_actions, failures: failures,
                            tenant_key: key, tenant_cidr: explicit_cidr,
                            sdwan_network: network, tenant_cidr_resolved: tenant_cidr,
                            firewall_rule_ids: firewall_rule_ids,
                            ovn_deployment_id: existing_deployment&.id,
                            created_ovn_deployment: false, ovn_logical_switch_id: nil,
                            ovn_acl_ids: [], ovn_acl_allocations: [])
          end

          switch_out          = switch_result[:data][:outputs]
          ovn_deployment_id   = switch_out[:ovn_deployment_id]
          created_deployment  = switch_out[:created_deployment]
          logical_switch_id   = Array(switch_out[:logical_switch_ids]).first
          planned_actions << { step: "compose_ovn_switch", logical_switch_id: logical_switch_id,
                               ovn_deployment_id: ovn_deployment_id,
                               created_deployment: created_deployment }

          if logical_switch_id.blank?
            # The compose executor succeeded but the switch row didn't land
            # (e.g. name collision recorded as a per-switch failure). Surface
            # its failures and stop before applying ACLs to a nil switch.
            failures.concat(Array(switch_result[:data][:failures]))
            return finalize(planned_actions: planned_actions, failures: failures,
                            tenant_key: key, tenant_cidr: explicit_cidr,
                            sdwan_network: network, tenant_cidr_resolved: tenant_cidr,
                            firewall_rule_ids: firewall_rule_ids,
                            ovn_deployment_id: ovn_deployment_id,
                            created_ovn_deployment: created_deployment,
                            ovn_logical_switch_id: nil,
                            ovn_acl_ids: [], ovn_acl_allocations: [])
          end

          # ── Step 4: tenant-CIDR OVN ACLs (sibling apply-acl executor) ────
          acl_result = ovn_acl_executor.execute(
            logical_switch_id: logical_switch_id,
            acls: tenant_acls(key: key, tenant_cidr: tenant_cidr)
          )
          ovn_acl_ids = []
          ovn_acl_allocations = []
          if acl_result[:success]
            acl_out = acl_result[:data][:outputs]
            ovn_acl_ids = Array(acl_out[:ovn_acl_ids])
            ovn_acl_allocations = Array(acl_out[:allocations])
            failures.concat(Array(acl_result[:data][:failures]))
            planned_actions << { step: "apply_ovn_acls", acl_count: ovn_acl_ids.size }
          else
            failures << { step: "apply_ovn_acls", error: acl_result[:error] }
          end

          finalize(planned_actions: planned_actions, failures: failures,
                   tenant_key: key, tenant_cidr: explicit_cidr,
                   sdwan_network: network, tenant_cidr_resolved: tenant_cidr,
                   firewall_rule_ids: firewall_rule_ids,
                   ovn_deployment_id: ovn_deployment_id,
                   created_ovn_deployment: created_deployment,
                   ovn_logical_switch_id: logical_switch_id,
                   ovn_acl_ids: ovn_acl_ids, ovn_acl_allocations: ovn_acl_allocations)
        end
        # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

        # Compose Sdwan::Executors::CreateNetwork — the canonical network
        # creation capability. The executor derives its account from
        # deferred_operation.account, so we hand it a lightweight stand-in
        # carrying @account (the skill executor has no DeferredOperation in
        # the synchronous mission-runner composition path). The executor
        # returns { network_id:, name: }; we refetch the row to read the
        # callback-assigned handle / VRF name / allocated /64.
        def create_tenant_network(key:, net_name:)
          result = ::Sdwan::Executors::CreateNetwork.execute(
            { attributes: {
              name: net_name,
              description: "Tenant isolation slice for '#{key}' (multi_tenant_isolation)",
              routing_protocol: "ibgp",
              settings: { "tenant_key" => key, "isolation" => "dedicated_vrf" }
            } },
            deferred_operation: composition_deferred_operation
          )
          ::Sdwan::Network.find(result[:data][:network_id])
        end

        # Two nftables rules: explicit allow for intra-tenant traffic (the
        # tenant's own /64) at high priority, then a default-deny wildcard.
        # The `cidr` selector kind targets the whole tenant prefix; the
        # `all` wildcard denies everything not matched above. Both rules are
        # composed through Sdwan::Executors::CreateFirewallRule.
        def create_firewall_rules(network:, key:, tenant_cidr:, planned_actions:,
                                  failures:, firewall_rule_ids:)
          firewall_rule_specs(key, tenant_cidr).each do |attributes|
            rule = create_firewall_rule(network: network, failures: failures, attributes: attributes)
            next unless rule

            firewall_rule_ids << rule.id
            planned_actions << { step: "create_firewall_rule", rule_id: rule.id,
                                 name: rule.name, action: attributes[:action] }
          end
        end

        # The two tenant nftables rules (attribute hashes), composed in order by
        # the caller through Sdwan::Executors::CreateFirewallRule: an explicit
        # intra-tenant allow (the tenant's own /64, high priority) and a default
        # ingress deny (wildcard, lower priority).
        def firewall_rule_specs(key, tenant_cidr)
          [
            { account_id: @account.id, name: "tenant-#{key}-allow-intra",
              priority: ALLOW_PRIORITY, action: "accept", direction: "both", protocol: "any",
              src_selector: { "cidr" => tenant_cidr }, dst_selector: { "cidr" => tenant_cidr },
              enabled: true },
            { account_id: @account.id, name: "tenant-#{key}-deny-default",
              priority: DENY_PRIORITY, action: "drop", direction: "ingress", protocol: "any",
              src_selector: { "all" => true }, enabled: true }
          ]
        end

        # Compose Sdwan::Executors::CreateFirewallRule — the canonical rule
        # creation capability (`network.firewall_rules.create!(attrs)`). The
        # executor returns { rule_id:, network_id: }; we refetch the row so
        # the caller can read its persisted name for the planned-actions log.
        # Failures are collected (keyed by the attempted rule name), not
        # raised, so a partial firewall set still surfaces every rule it
        # couldn't create — mirroring the per-step failure convention.
        def create_firewall_rule(network:, attributes:, failures:)
          result = ::Sdwan::Executors::CreateFirewallRule.execute(
            { network_id: network.id, attributes: attributes },
            deferred_operation: composition_deferred_operation
          )
          ::Sdwan::FirewallRule.find(result[:data][:rule_id])
        rescue StandardError => e
          failures << { step: "create_firewall_rule", name: attributes[:name], error: e.message }
          nil
        end

        # Tenant-CIDR OVN ACLs: allow intra-tenant (src in tenant CIDR) at
        # high priority; drop everything else inbound at lower priority.
        # ip4/ip6 chosen by the CIDR family so the match expression parses.
        def tenant_acls(key:, tenant_cidr:)
          fam = cidr_family(tenant_cidr)
          [
            { name: "tenant-#{key}-allow-intra", direction: "to-lport", priority: ACL_ALLOW_PRIORITY,
              match: "#{fam}.src == #{tenant_cidr}", action: "allow-related" },
            { name: "tenant-#{key}-deny-cross", direction: "to-lport", priority: ACL_DENY_PRIORITY,
              match: "#{fam}.src != #{tenant_cidr}", action: "drop" }
          ]
        end

        def finalize(planned_actions:, failures:, tenant_key:, tenant_cidr:,
                     sdwan_network:, tenant_cidr_resolved:, firewall_rule_ids:,
                     ovn_deployment_id:, created_ovn_deployment:, ovn_logical_switch_id:,
                     ovn_acl_ids:, ovn_acl_allocations:)
          created = tenant_resources_created?(sdwan_network, firewall_rule_ids, ovn_logical_switch_id, ovn_acl_ids)
          outputs = finalize_outputs(
            sdwan_network: sdwan_network, tenant_cidr_resolved: tenant_cidr_resolved,
            firewall_rule_ids: firewall_rule_ids, ovn_deployment_id: ovn_deployment_id,
            created_ovn_deployment: created_ovn_deployment, ovn_logical_switch_id: ovn_logical_switch_id,
            ovn_acl_ids: ovn_acl_ids, ovn_acl_allocations: ovn_acl_allocations
          )
          success(dry_run: false, tenant_key: tenant_key, tenant_cidr: tenant_cidr_resolved,
                  planned_actions: planned_actions, outputs: outputs, failures: failures,
                  partial: failures.any? && created)
        end

        # True when this run created any tenant resource — drives the `partial`
        # flag (failures alongside real progress) in the success envelope.
        def tenant_resources_created?(sdwan_network, firewall_rule_ids, ovn_logical_switch_id, ovn_acl_ids)
          sdwan_network.present? || firewall_rule_ids.any? ||
            ovn_logical_switch_id.present? || ovn_acl_ids.any?
        end

        # Success/partial outputs payload. created_ovn_deployment is carried so
        # the rollback path knows whether to tear the account OVN deployment
        # down (only when this run created it).
        def finalize_outputs(sdwan_network:, tenant_cidr_resolved:, firewall_rule_ids:,
                             ovn_deployment_id:, created_ovn_deployment:, ovn_logical_switch_id:,
                             ovn_acl_ids:, ovn_acl_allocations:)
          {
            sdwan_network_id: sdwan_network&.id, sdwan_network_handle: sdwan_network&.network_handle,
            vrf_name: sdwan_network&.vrf_name_for, tenant_cidr: tenant_cidr_resolved,
            firewall_rule_ids: firewall_rule_ids, ovn_deployment_id: ovn_deployment_id,
            created_ovn_deployment: created_ovn_deployment, ovn_logical_switch_id: ovn_logical_switch_id,
            ovn_acl_ids: ovn_acl_ids, ovn_acl_allocations: ovn_acl_allocations
          }
        end

        def build_plan(net_name:, switch_name:, tenant_cidr:, creating_deployment:)
          steps = [
            { step: "create_network", name: net_name, routing_protocol: "ibgp",
              tenant_cidr: tenant_cidr || "<auto-allocated /64>" },
            { step: "create_firewall_rule", action: "accept", scope: "intra-tenant" },
            { step: "create_firewall_rule", action: "drop", scope: "default-deny" }
          ]
          steps << { step: "create_ovn_deployment" } if creating_deployment
          steps << { step: "compose_ovn_switch", name: switch_name }
          steps << { step: "apply_ovn_acls", scope: "tenant-cidr" }
          steps
        end

        # OVN logical switch CIDR is bounded at 64 chars and only meaningful
        # for v6/v4 prefixes; pass it through when it fits, else leave nil
        # (the switch still works as an L2 domain without OVN-served DHCP).
        def ovn_switch_cidr(tenant_cidr)
          return nil if tenant_cidr.blank?
          return nil if tenant_cidr.length > 64

          tenant_cidr
        end

        def cidr_family(cidr)
          cidr.to_s.match?(IPV4_CIDR) ? "ip4" : "ip6"
        end

        def valid_cidr?(cidr)
          cidr.match?(IPV6_CIDR) || cidr.match?(IPV4_CIDR)
        end

        # Sibling executors are memoized so a single run + its rollback share
        # one instance (the apply-acl rollback reads no per-instance state,
        # but reusing the same @account/@agent/@user wiring is correct).
        def ovn_compose_executor
          @ovn_compose_executor ||=
            SdwanOvnComposeTopologyExecutor.new(account: @account, agent: @agent, user: @user)
        end

        def ovn_acl_executor
          @ovn_acl_executor ||=
            SdwanOvnApplyAclExecutor.new(account: @account, agent: @agent, user: @user)
        end

        # Sdwan::Executors::CreateNetwork derives its account from
        # `deferred_operation&.account`; the skill executor runs synchronously
        # inside the mission runner and has no real DeferredOperation, so we
        # hand the composed executor a lightweight stand-in carrying @account.
        # CreateNetwork only reads `.account` off it (the `.merge(account:)`
        # that sets the network's required `belongs_to :account`); the
        # firewall-rule executor passes attributes straight through.
        CompositionContext = Struct.new(:account)

        def composition_deferred_operation
          @composition_deferred_operation ||= CompositionContext.new(@account)
        end
      end
    end
  end
end
