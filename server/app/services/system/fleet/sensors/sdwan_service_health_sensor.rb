# frozen_string_literal: true

# IMP-c7d663f24a0b — the first SDWAN sensor that observes SERVICE-level
# connectivity rather than infrastructure.
#
# The other five SDWAN sensors (drift, reachability, BGP health, VIP
# reachability, credential expiry) all answer "is the pipe up?". None answers
# "is the thing at the end of the pipe serving?" — so a published service
# could be dead for a day while every infra sensor read green. This
# reproduces, inside SDWAN, the platform readiness-map finding that infra is
# sensed comprehensively and workloads not at all.
#
# The telemetry that closes the gap was already in the database and consumed
# by nothing: Sdwan::FlowSample rows are decoded IPFIX 5-tuples with
# byte/packet counters, written by Sdwan::IpfixIngestService, whose only other
# code reference was a has_many declaration.
#
# TWO signals:
#
#   system.sdwan_service_silent    — an active service whose backend VIP+port
#                                    saw NO flows in the window, AND whose VIP
#                                    holder peer handshook recently. Both
#                                    halves matter: traffic-absent alone
#                                    double-alarms with SdwanVipReachability
#                                    on every infra failure. Requiring a fresh
#                                    handshake narrows it to the case no other
#                                    sensor covers — pipe up, app down.
#
#   system.sdwan_portmap_orphaned  — an enabled DNAT rule whose target no
#                                    longer resolves (VIP released / holder
#                                    drained / target peer lost its address).
#                                    The compiler silently skips such a rule,
#                                    so it can sit enabled and dead forever.
#
# ABSENCE OF TELEMETRY IS NOT EVIDENCE OF SILENCE. If the account has no
# active IPFIX collector, or the collectors have delivered nothing at all in
# the window, the SILENCE half emits nothing and stamps nothing. Inferring
# "every service is dead" from "the flow pipeline is down" would turn one
# collector outage into a fleet-wide false alarm — the same class of defect
# as a telemetry stub reporting 0 instead of "unavailable".
#
# That gate covers the silence half ONLY. Orphaned port mappings are derived
# from database state alone (a target VIP with no holder, a target peer with
# no address) and have nothing to do with IPFIX, so gating them on telemetry
# would leave that half permanently inert on every account that never
# configured a collector — and collectors are optional operator-run sidecars,
# so that is most of them.
#
# Window and freshness thresholds are DB-driven (Account#settings, then
# SiteSetting), not constants; the constants below are only the fallback when
# neither is configured.
module System
  module Fleet
    module Sensors
      class SdwanServiceHealthSensor < BaseSensor
        # How far back to look for flows correlated to a service backend.
        DEFAULT_FLOW_WINDOW_SECONDS = 900          # 15 minutes
        # How fresh a VIP holder's WG handshake must be for us to claim the
        # pipe is up. Mirrors SdwanVipReachabilitySensor::UNREACHABLE_WINDOW —
        # beyond it, that sensor owns the alarm and this one stays quiet.
        DEFAULT_HANDSHAKE_FRESH_SECONDS = 300      # 5 minutes
        # A service younger than this has not had time to see traffic; the
        # grace period keeps a just-published service from alarming instantly.
        DEFAULT_SERVICE_GRACE_SECONDS = 900        # 15 minutes

        # Deployment-wide SiteSetting keys: "<SETTING_PREFIX>.<name>".
        SETTING_PREFIX = "system.sdwan.service_health"
        # Per-account override keys on Account#settings:
        # "<ACCOUNT_SETTING_PREFIX>_<name>" (flat, matching that column's
        # existing single-level convention).
        ACCOUNT_SETTING_PREFIX = "sdwan_service_health"

        def sense
          return [] unless models_loaded?

          # Orphan detection first, and UNCONDITIONALLY: it reads only the
          # DNAT rows and their targets. Only the silence claim needs the
          # flow pipeline to be demonstrably alive — see the header note on
          # why the two halves are gated separately.
          signals = port_mapping_signals
          signals += service_signals if telemetry_live?
          signals
        end

        private

        def models_loaded?
          defined?(::Sdwan::Service) && defined?(::Sdwan::FlowSample) &&
            defined?(::Sdwan::PortMapping) && defined?(::Sdwan::IpfixCollector)
        end

        def flow_window_seconds
          @flow_window_seconds ||= setting_seconds("flow_window_seconds",
                                                   DEFAULT_FLOW_WINDOW_SECONDS)
        end

        def handshake_fresh_seconds
          @handshake_fresh_seconds ||= setting_seconds("handshake_fresh_seconds",
                                                       DEFAULT_HANDSHAKE_FRESH_SECONDS)
        end

        def service_grace_seconds
          @service_grace_seconds ||= setting_seconds("service_grace_seconds",
                                                     DEFAULT_SERVICE_GRACE_SECONDS)
        end

        # Per-account first — this is a multi-tenant control plane and the
        # sensor is account-scoped, so one tenant's wider window must not
        # move everyone else's threshold. Mirrors
        # DiskImagePublicationFailureStreakSensor#streak_threshold, the
        # in-repo precedent for an account-tunable sensor threshold. Falls
        # back to the deployment-wide SiteSetting, then to the constant.
        #
        # SiteSetting.get returns nil for an unset key and casts by the row's
        # declared type, so a string-typed row still needs #to_i. A
        # non-positive configured value is treated as unset rather than
        # collapsing the window to zero (which would mark everything silent).
        def setting_seconds(suffix, fallback)
          raw = account.settings&.dig("#{ACCOUNT_SETTING_PREFIX}_#{suffix}").presence ||
                ::SiteSetting.get("#{SETTING_PREFIX}.#{suffix}")
          value = raw.to_i
          value.positive? ? value : fallback
        end

        def window_start
          @window_start ||= flow_window_seconds.seconds.ago
        end

        # The flow pipeline must be demonstrably alive for "no flows to this
        # service" to mean anything. Both halves are required: a configured
        # collector proves intent, delivered samples prove the path works.
        def telemetry_live?
          return false unless ::Sdwan::IpfixCollector.for_account(account).active.exists?

          ::Sdwan::FlowSample.for_account(account).since(window_start).exists?
        end

        def service_signals
          ::Sdwan::Service.where(account_id: account.id, status: "active")
                          .includes(:backend_vip)
                          .find_each.filter_map { |service| evaluate_service(service) }
        end

        def evaluate_service(service)
          address = service.backend_address.to_s.presence
          return nil if address.nil?

          last_seen = last_flow_at(address, service.backend_port)

          if last_seen
            stamp(service, health_state: "serving", last_observed_flow_at: last_seen)
            return nil
          end

          # Traffic is absent. Only call that "silent" when we can also show
          # the pipe was up — otherwise the infra sensors own this failure and
          # we would be the second alarm for one cause.
          #
          # What we cannot prove reverts to "unknown"; it must NOT keep the
          # "serving" an earlier tick stamped. The column's whole contract
          # (see the migration + Service::HEALTH_STATES) is that an
          # unobserved service is not a healthy one, and a service that
          # stopped being observed is exactly that — leaving "serving" on it
          # would make the read model assert the one thing it promised never
          # to fabricate. `stamp` is a no-op when the value is unchanged, so
          # a service that is simply quiet does not churn the row.
          unless reportable_silence?(service)
            stamp(service, health_state: "unknown")
            return nil
          end

          stamp(service, health_state: "silent")
          silent_signal(service, address)
        end

        # Silence is a REPORTABLE claim only when the service has had time to
        # see traffic at all and the overlay path to it is demonstrably up.
        def reportable_silence?(service)
          return false if service.created_at > service_grace_seconds.seconds.ago

          pipe_up?(service)
        end

        # Newest correlated flow, or nil. Deliberately NOT filtered by IANA
        # protocol: every Sdwan::Service protocol (https/http/tcp/tls) rides
        # TCP today, but an HTTP/3 backend answers the same VIP+port over UDP,
        # and excluding it would report a live service as silent.
        #
        # One query per service rather than one grouped query for the whole
        # sweep, deliberately: `dst_ip` is a Postgres `inet`, so this compares
        # ADDRESSES (both sides parsed), and `fd00:BEEF::0001` matches the
        # stored `fd00:beef::1`. Grouping would force the comparison into text
        # space (`host(dst_ip)`), where an operator's non-canonical VIP CIDR
        # silently correlates to nothing and every service reads as silent.
        def last_flow_at(address, port)
          ::Sdwan::FlowSample.for_account(account)
                             .since(window_start)
                             .where(dst_ip: address, dst_port: port)
                             .maximum(:observed_at)
        end

        # "Pipe up" is only PROVABLE for a VIP-backed service, where the
        # holder peer's WG handshake tells us the overlay path exists. A
        # static backend_host has no holder to interrogate, so we cannot
        # separate "app down" from "network down" and stay silent rather than
        # guess — the conservative half of the AND in the header note.
        def pipe_up?(service)
          vip = service.backend_vip
          return false if vip.nil?

          holder_ids = Array(vip.holder_peer_ids)
          return false if holder_ids.empty?

          ::Sdwan::Peer.where(id: holder_ids)
                       .where("last_handshake_at >= ?", handshake_fresh_seconds.seconds.ago)
                       .exists?
        end

        def silent_signal(service, address)
          signal(
            kind: "system.sdwan_service_silent",
            severity: severity_for_silence(service),
            payload: {
              "service_id" => service.id,
              "slug" => service.slug,
              "name" => service.name,
              "protocol" => service.protocol,
              "backend_address" => address,
              "backend_port" => service.backend_port,
              "backend_vip_id" => service.backend_vip_id,
              "flow_window_seconds" => flow_window_seconds,
              "last_observed_flow_at" => service.last_observed_flow_at&.iso8601,
              "locally_exposed" => service.local_enabled,
              "publicly_exposed" => service.public_enabled,
              # No automated remediation: a service that stopped serving needs
              # investigation, not a blind restart of overlay plumbing that
              # this sensor has just PROVEN to be healthy.
              "remediation_action" => nil
            },
            fingerprint: "sdwan_service_silent:#{service.id}"
          )
        end

        # An exposed service is a louder failure than an internal one, and a
        # service never once observed is a weaker claim than one that was
        # demonstrably serving and then stopped.
        def severity_for_silence(service)
          return :medium if service.last_observed_flow_at.nil?
          return :high if service.local_enabled || service.public_enabled

          :medium
        end

        def port_mapping_signals
          ::Sdwan::PortMapping.where(account_id: account.id, enabled: true)
                              .includes(:target_peer, :target_virtual_ip)
                              .find_each.filter_map do |mapping|
            next nil if mapping.resolved_target_address.present?

            orphan_signal(mapping)
          end
        end

        def orphan_signal(mapping)
          signal(
            kind: "system.sdwan_portmap_orphaned",
            severity: :medium,
            payload: {
              "port_mapping_id" => mapping.id,
              "name" => mapping.name,
              "network_id" => mapping.sdwan_network_id,
              "hub_peer_id" => mapping.sdwan_peer_id,
              "listen_port" => mapping.listen_port,
              "protocol" => mapping.protocol,
              "target_peer_id" => mapping.target_peer_id,
              "target_virtual_ip_id" => mapping.target_virtual_ip_id,
              "reason" => mapping.target_virtual_ip_id.present? ? "vip_has_no_holder" : "target_peer_unaddressed",
              "remediation_action" => nil
            },
            fingerprint: "sdwan_portmap_orphaned:#{mapping.id}"
          )
        end

        # Durable read model for dashboards and for the severity decision
        # above. update_column deliberately skips validations, callbacks and
        # updated_at: this is an observation stamp, not an operator edit, and
        # it must not churn the record's updated_at on every tick. Mirrors
        # InstanceStateDriftSensor's last_sync_attempted_at/last_synced_at
        # stamps — the established in-repo precedent for a sensor recording
        # what it observed.
        def stamp(service, health_state:, last_observed_flow_at: nil)
          service.update_column(:health_state, health_state) if service.health_state != health_state
          return if last_observed_flow_at.nil?
          return if service.last_observed_flow_at == last_observed_flow_at

          service.update_column(:last_observed_flow_at, last_observed_flow_at)
        end
      end
    end
  end
end
