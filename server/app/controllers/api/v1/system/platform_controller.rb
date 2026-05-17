# frozen_string_literal: true

module Api
  module V1
    module System
      # Operator-facing aggregate read for the /app/system/compute/platform
      # dashboard. v1: returns counts + a summary block per sub-domain so
      # the dashboard header can render an at-a-glance without each
      # sub-panel making its own fetch.
      #
      # Plan reference: Decentralized Federation §I + P7.
      class PlatformController < ApplicationController
        before_action :authenticate_request

        def overview
          return forbidden unless current_user&.has_permission?("system.platform.read")
          render_success(
            overview: {
              peers:        peers_summary,
              children:     children_summary,
              services:     services_summary,
              migrations:   migrations_summary,
              certificates: certificates_summary,
              generated_at: Time.current.iso8601
            }
          )
        end

        private

        def forbidden
          render_error("Forbidden", status: :forbidden)
        end

        def peers_summary
          return { count: 0, by_status: {} } unless defined?(::System::FederationPeer)
          peers = ::System::FederationPeer.where(account: current_account).platform_peers
          {
            count: peers.count,
            by_status: peers.group(:status).count,
            last_handshake_at: peers.maximum(:last_handshake_at)&.iso8601
          }
        end

        def children_summary
          return { count: 0 } unless defined?(::System::FederationPeer)
          children = ::System::FederationPeer.where(account: current_account, spawn_role: "parent")
          {
            count: children.count,
            by_spawn_mode: children.group(:spawn_mode).count,
            by_status: children.group(:status).count
          }
        end

        def services_summary
          offerings  = scoped_count(::System::Federation::ServiceOffering)
          subs       = scoped_count(::System::Federation::ServiceSubscription)
          {
            offerings: offerings,
            subscriptions: subs
          }
        rescue StandardError
          { offerings: 0, subscriptions: 0 }
        end

        def migrations_summary
          return { count: 0 } unless defined?(::System::Migration)
          migrations = ::System::Migration.where(account: current_account)
          {
            count: migrations.count,
            by_status: migrations.group(:status).count
          }
        rescue StandardError
          { count: 0 }
        end

        def certificates_summary
          return { count: 0 } unless defined?(::System::AcmeCertificate)
          certs = ::System::AcmeCertificate.where(account: current_account)
          near_expiry = certs.where(status: "valid")
                             .where("expires_at < ?", 30.days.from_now)
                             .count
          {
            count: certs.count,
            by_status: certs.group(:status).count,
            near_expiry: near_expiry
          }
        rescue StandardError
          { count: 0 }
        end

        def scoped_count(klass)
          return 0 unless klass
          klass.where(account: current_account).count
        rescue StandardError
          0
        end
      end
    end
  end
end
