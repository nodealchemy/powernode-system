# frozen_string_literal: true

# The agent-side SDWAN endpoints. The pull side (#config) is the architectural
# pivot from the original task-dispatch design: agents fetch their per-peer
# desired-state on every heartbeat, mirroring how /node_api/config/authorized_keys
# already works. The push side (#report) is how the agent reports actual
# tunnel state — handshake age, peer reachability — back to the platform.
#
# Authentication is via the instance JWT carried on every node_api request
# (handled by the parent NodeApi::BaseController).
#
# Slice 1 of the SDWAN plan.
module Api
  module V1
    module System
      module NodeApi
        class SdwanController < BaseController
          # GET /api/v1/system/node_api/config/sdwan
          # Returns one compiled-peer-view per network this instance belongs to.
          # The agent applies these via wgctrl-go on each heartbeat tick.
          #
          # NOTE: action MUST NOT be named `config`. AbstractController::Logger
          # delegates `controller.logger` → `controller.config.logger`, and
          # an action method named `config` shadows that delegate, sending
          # the controller into infinite recursion the moment Rails tries to
          # log anything during render. Route maps GET /config/sdwan → this
          # action via routes.rb.
          def show_config
            instance = current_instance
            peers = ::Sdwan::Peer.includes(:network, :keys)
                                 .where(node_instance_id: instance.id)

            views = peers.map do |peer|
              # include_private_key: true is the whole reason this endpoint
              # exists — the agent needs the private half to drive `wg setconf`.
              # The operator-facing topology endpoint sets it to false so the
              # secret never leaves Vault on the operator path.
              #
              # Federation prefixes are resolved ONCE per network for the
              # request (see federation_resolver). A host with N peers — often
              # all on the same network — would otherwise re-run identical
              # account-scoped FederationPrefixResolver queries inside each
              # TopologyCompiler. The injected resolver memoizes per network so
              # the compiled output is identical while the DB work happens once.
              compiled = ::Sdwan::TopologyCompiler.compile_for_peer(
                peer,
                federation_resolver: request_federation_resolver,
                include_private_key: true
              )
              compiled.merge(network_id: peer.sdwan_network_id, network_cidr_64: peer.network.cidr_64)
            end

            render_success(
              instance_id: instance.id,
              networks: views,
              compiled_at: Time.current.iso8601,
              # Phase N0 — Ed25519 public keys the agent will accept when
              # verifying MC envelopes. Scoped to constellations belonging
              # to this instance's account.
              constellations: trusted_constellations_for(instance),
              # Phase N1a — per-host VRF assignment list, consumed
              # directly by vrf_applier. Includes only assignments in
              # compilable state (active or draining).
              vrf_assignments: vrf_assignments_for(instance),
              # Phase O1 — per-host bridge list, consumed directly by
              # the agent's BridgeApplier. Includes only compilable
              # rows (active or draining).
              host_bridges: ::Sdwan::TopologyCompiler.host_bridges_for(instance),
              # Phase O3 — OVN control-plane endpoints for heavyweight
              # hosts whose account has an active OvnDeployment. nil
              # for lightweight hosts; agent's manager.go treats nil
              # as "OVN not enabled, skip the OVN reconcile step".
              ovn_control: ::Sdwan::TopologyCompiler.ovn_control_for(instance),
              # Phase 3 — the compiled OVN Northbound plan (ls-add /
              # lsp-add / lsp-set-addresses / acl-add) the agent's
              # OvnNbApplier replays against the central NB DB. Top-level
              # (host-scoped) because the agent reads `desired.OvnNbPlan`
              # separately from ovn_control. nil for lightweight hosts or
              # accounts with no active OvnDeployment. Previously absent —
              # the agent's NB applier existed and ran every tick but the
              # server never served the plan, so OVN logical switches +
              # isolation ACLs were never replayed on-host.
              ovn_nb_plan: ::Sdwan::TopologyCompiler.ovn_nb_plan_for(instance)
            )
          end

          # POST /api/v1/system/node_api/status/sdwan
          # Body: { peers: [{ peer_id, last_handshake_at, rx_bytes, tx_bytes, status }, ...] }
          # The agent reports observed handshake state per peer; we persist
          # last_handshake_at and recompute peer.status using the active /
          # degraded / disconnected windows defined on Sdwan::Peer.
          def report
            instance = current_instance
            reports = Array(params[:peers])

            updated = reports.map do |r|
              # The agent retries this heartbeat on failure, so a non-object
              # element (e.g. a bare string) must be skipped, not raise a
              # TypeError on r[:peer_id] and 500 the whole report.
              next nil unless r.respond_to?(:key?)

              peer = ::Sdwan::Peer.where(node_instance_id: instance.id).find_by(id: r[:peer_id])
              next nil unless peer

              if r[:last_handshake_at].present?
                peer.update_column(:last_handshake_at, parse_time(r[:last_handshake_at]))
              end
              peer.recompute_status_from_handshake!
              { peer_id: peer.id, status: peer.status }
            end.compact

            render_success(reported: updated.size, peers: updated)
          end

          # POST /api/v1/system/node_api/status/bgp
          # Body: {
          #   networks: [
          #     {
          #       network_id: "<uuid>",
          #       router_id: "1.2.3.4",
          #       local_as: 4231866913,
          #       sessions: [
          #         { neighbor_address: "fdf8:...", state: "established",
          #           uptime_seconds: 3600, prefixes_received: 5,
          #           prefixes_sent: 3, last_error: "" }, ...
          #       ]
          #     }, ...
          #   ]
          # }
          # The agent's frr_observer polls `vtysh -c "show bgp summary json"`
          # on each tick and POSTs the deltas. The platform upserts
          # Sdwan::BgpSession rows keyed on (peer, neighbor_address) — these
          # are the canonical "live state" rows the routing dashboard reads.
          #
          # Slice 9f of the SDWAN plan.
          def report_bgp
            instance = current_instance
            networks = Array(params[:networks])

            local_peers = ::Sdwan::Peer.where(node_instance_id: instance.id).to_a
            peer_by_network = local_peers.index_by(&:sdwan_network_id)

            written = ::Sdwan::BgpSessionWriter.new(
              instance: instance,
              peer_by_network: peer_by_network,
              networks_payload: networks
            ).write!

            render_success(reported: written, networks_seen: networks.size)
          end

          private

          # A federation resolver scoped to this request that memoizes the
          # resolved entries per network. Matches the TopologyCompiler
          # `federation_resolver:` lambda contract (`->(network)`), so it
          # drops in transparently and returns byte-identical results to the
          # default Sdwan::FederationPrefixResolver — the only difference is
          # that peers sharing a network resolve the (account-scoped) prefix
          # set once instead of once per peer.
          def request_federation_resolver
            @request_federation_resolver ||=
              begin
                cache = {}
                lambda do |network|
                  key = network&.id
                  next ::Sdwan::FederationPrefixResolver.resolve(network) if key.nil?

                  cache[key] ||= ::Sdwan::FederationPrefixResolver.resolve(network)
                end
              end
          end

          def parse_time(raw)
            Time.parse(raw.to_s)
          rescue ArgumentError
            Time.current
          end

          # Phase N0 — trusted constellation pubkeys for this instance.
          # Currently scoped to the instance's account; cross-account
          # federation trust will extend this in N2 when constellations
          # become first-class.
          def trusted_constellations_for(instance)
            ::Sdwan::ConstellationSigningKey
              .where(account_id: instance.account_id)
              .map do |key|
                {
                  handle: key.handle,
                  public_key_b64: key.public_key_b64
                }
              end
          end

          # Phase N1a — per-host VRF assignments, one entry per network
          # this instance has joined. The agent's vrf_applier consumes
          # this list directly; ordering is irrelevant.
          def vrf_assignments_for(instance)
            assignments = ::Sdwan::HostVrfAssignment
                            .where(node_instance_id: instance.id, state: %w[active draining])
                            .includes(:network)
                            .to_a

            # One query for this instance's peer addresses (grouped by network)
            # instead of net.peers.where(...).pluck per assignment — this runs on
            # the agent heartbeat config pull, so the per-assignment query was an
            # N+1 repeated across the fleet.
            addrs_by_network = ::Sdwan::Peer
                                 .where(node_instance_id: instance.id)
                                 .pluck(:sdwan_network_id, :assigned_address)
                                 .group_by(&:first)
                                 .transform_values { |rows| rows.map { |(_nid, addr)| addr.to_s.split("/").first } }

            assignments.map do |hva|
              net = hva.network
              {
                vrf_name: hva.vrf_name,
                table_id: hva.table_id,
                network_handle: net.network_handle,
                # Phase N1a follow-up — derive bound_iface from the
                # HVA's short_id (single source of truth) so the
                # WG iface name matches the disambiguated VRF name.
                bound_iface: hva.wg_iface_name,
                source_addrs: addrs_by_network.fetch(hva.sdwan_network_id, [])
              }
            end
          end
        end
      end
    end
  end
end
