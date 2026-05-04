# frozen_string_literal: true

# Account-level SDWAN routing/iBGP control plane. Owns:
#   GET  /routing            → AccountBgp + summary across all networks
#   POST /routing/bgp        → allocate (or return existing) AccountBgp
#   GET  /routing/sessions   → live BGP session matrix across all networks
#
# Per-network routing concerns (mode toggle, lan_subnets, learned routes)
# stay on the network controller; this one is the account-wide birds-eye.
#
# Slice 9c of the SDWAN plan.
module Api
  module V1
    module System
      module Sdwan
        class RoutingController < ::Api::V1::System::BaseController
          before_action :set_account

          def show
            require_permission("sdwan.routing.read")
            account_bgp = ::Sdwan::AccountBgp.find_by(account_id: @account.id)
            networks = ::Sdwan::Network.where(account_id: @account.id)

            render_success(
              account_bgp: serialize_account_bgp(account_bgp),
              summary: {
                total_networks: networks.count,
                ibgp_networks:  networks.where(routing_protocol: "ibgp").count,
                static_networks: networks.where(routing_protocol: "static").count,
                established_sessions: ::Sdwan::BgpSession
                                         .joins(:network)
                                         .where(sdwan_networks: { account_id: @account.id })
                                         .established.count,
                total_sessions: ::Sdwan::BgpSession
                                   .joins(:network)
                                   .where(sdwan_networks: { account_id: @account.id })
                                   .count
              }
            )
          end

          def allocate_as
            require_permission("sdwan.routing.manage")
            existing = ::Sdwan::AccountBgp.find_by(account_id: @account.id)
            if existing
              return render_success(account_bgp: serialize_account_bgp(existing), allocated: false)
            end

            new_row = ::Sdwan::Bgp::AsNumberAllocator.allocate!(account: @account)
            render_success({ account_bgp: serialize_account_bgp(new_row), allocated: true },
                           status: :created)
          rescue ::Sdwan::Bgp::AsNumberAllocator::CapacityExhausted => e
            render_error(e.message, status: :unprocessable_entity)
          end

          def sessions
            require_permission("sdwan.routing.read")
            scope = ::Sdwan::BgpSession.joins(:network)
                                       .where(sdwan_networks: { account_id: @account.id })
            scope = scope.where(sdwan_networks: { id: params[:network_id] }) if params[:network_id].present?
            scope = scope.where(state: params[:state]) if params[:state].present?

            sessions = scope.order(updated_at: :desc).limit(500).to_a
            render_success(
              sessions: sessions.map { |s| serialize_session(s) },
              count: sessions.size
            )
          end

          private

          def serialize_account_bgp(row)
            return nil if row.nil?

            {
              id: row.id,
              as_number: row.as_number,
              router_id_strategy: row.router_id_strategy,
              default_local_pref: row.default_local_pref,
              enabled: row.enabled,
              created_at: row.created_at&.iso8601
            }
          end

          def serialize_session(s)
            {
              id: s.id,
              peer_id: s.sdwan_peer_id,
              network_id: s.sdwan_network_id,
              neighbor_peer_id: s.neighbor_peer_id,
              neighbor_address: s.neighbor_address,
              state: s.state,
              uptime_seconds: s.uptime_seconds,
              prefixes_received: s.prefixes_received,
              prefixes_sent: s.prefixes_sent,
              last_state_change_at: s.last_state_change_at&.iso8601,
              last_observed_at: s.last_observed_at&.iso8601,
              last_error: s.last_error
            }
          end
        end
      end
    end
  end
end
