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

        # Orphaned DNAT rules itemised per tick before the sweep summarises the
        # rest. Mirrors InstanceStateDriftSensor::MAX_PER_TICK.
        MAX_ORPHANS_PER_TICK = 50

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
          # why the two halves are gated separately. The service sweep runs
          # unconditionally too, because it must STAMP on every tick even when
          # it emits nothing; skipping it on a telemetry-dead tick is what let
          # a stale "serving" outlive the telemetry that justified it.
          port_mapping_signals + service_signals
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

        # A configured active collector proves intent. It is only a
        # PRECONDITION, never the whole gate — see #network_telemetry_live?.
        def collectors_active?
          return @collectors_active if defined?(@collectors_active)

          @collectors_active = ::Sdwan::IpfixCollector.for_account(account).active.exists?
        end

        # Liveness must be scoped to the SERVICE'S OWN path, not the account.
        # An account-wide "any sample arrived" check defends only the
        # all-collectors-down case, which is not the case this guard exists
        # for: with two sites, site B's exporter dying while site A keeps
        # delivering leaves the account-wide check true, so every site-B
        # service with a fresh handshake would stamp silent and alarm — the
        # fleet-wide false alarm this sensor promises not to raise, one scope
        # down.
        #
        # Scoped to the VIP's HOLDER PEERS rather than the network prefix.
        # Sdwan::IpfixCollector carries no network/site association (account,
        # host, port, sampling_rate, state — nothing else), so there is no
        # collector→site join; and VirtualIp#cidr is validated for FORMAT only,
        # never for containment in its network's cidr_64, so a prefix test
        # would rest on an invariant nothing enforces. The holders are exactly
        # the machines that serve this VIP, so seeing their addresses in the
        # flow record is the narrowest true statement available: this
        # service's own host is still being exported, and nothing arrived for
        # its port. That IS "pipe up, app down", now with telemetry to back it.
        def holders_observed?(addresses)
          key = addresses.sort
          @holder_observed ||= {}
          return @holder_observed[key] if @holder_observed.key?(key)

          @holder_observed[key] =
            ::Sdwan::FlowSample.for_account(account)
                               .since(window_start)
                               .where("src_ip IN (:a) OR dst_ip IN (:a)", a: addresses)
                               .exists?
        end

        def silence_provable?(service)
          return false unless collectors_active?

          vip = service.backend_vip
          return false if vip.nil?

          # Same inet-cast hazard as the service backend: assigned_address is a
          # free-text column, so anything unparseable is dropped rather than
          # handed to Postgres.
          addresses = ::Sdwan::Peer.where(id: Array(vip.holder_peer_ids))
                                   .pluck(:assigned_address)
                                   .filter_map { |a| parse_address(a) }
          return false if addresses.empty?

          holders_observed?(addresses)
        end

        def service_signals
          sweep_stale_health_claims!

          ::Sdwan::Service.where(account_id: account.id, status: "active")
                          .includes(:backend_vip)
                          .find_each.filter_map { |service| evaluate_service(service) }
        end

        # A health claim only describes an ACTIVE service. Disabling one used
        # to freeze whatever it last held, so a disabled service sat in
        # Service.silent forever and a disabled-while-serving one kept
        # asserting health nothing was still checking.
        def sweep_stale_health_claims!
          ::Sdwan::Service.where(account_id: account.id)
                          .where(health_state: %w[serving silent])
                          .where.not(status: "active")
                          .update_all(health_state: "unknown")
        end

        def evaluate_service(service)
          address = correlatable_address(service)

          # Not an address we can match against an inet column — and never
          # will be. Distinct from "unknown" on purpose (Service::HEALTH_STATES).
          if address.nil?
            stamp(service, health_state: "unobservable")
            return nil
          end

          last_seen = last_flow_at(address, service.backend_port)

          # POSITIVE evidence needs no coverage gate: an observed flow proves
          # the service is serving regardless of how well we cover its overlay.
          # Only the NEGATIVE inference below has to justify itself.
          if last_seen
            stamp(service, health_state: "serving", last_observed_flow_at: last_seen)
            return nil
          end

          unless silence_provable?(service)
            stamp(service, health_state: "unknown")
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

        # The backend address ONLY when it is something an inet column can be
        # compared against. `backend_host` is a free-text string column whose
        # sole validation is that one of host/VIP is present, so a hostname is
        # an ordinary value there — and `where(dst_ip: "backend.example.com")`
        # does not quietly match nothing, it raises
        # ActiveRecord::StatementInvalid (PG::InvalidTextRepresentation) on the
        # inet cast. FleetAutonomyService rescues per sensor, so that raise
        # would not break the tick; it would do something quieter and worse —
        # mark this sensor failed and discard ALL its signals, including the
        # orphan half, on EVERY tick, for as long as one hostname-backed
        # service exists on the account. A sensor permanently inert on a whole
        # account is exactly the failure this one was written to end.
        def correlatable_address(service)
          parse_address(service.backend_address)
        end

        # Bare address string, or nil when it is not one an inet column can be
        # compared against. Every value reaching a `dst_ip`/`src_ip` comparison
        # goes through here.
        def parse_address(raw)
          value = raw.to_s.split("/").first.presence
          return nil if value.nil?

          IPAddr.new(value)
          value
        rescue IPAddr::InvalidAddressError, ArgumentError
          nil
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

        # Capped, because orphans arrive in HERDS. Draining a hub peer strands
        # every DNAT rule behind it at once, so an uncapped sweep emits one
        # notification per rule every DEDUP_TTL — a 200-rule account is 200
        # notifications per 10 minutes, and unlike the silence half this one
        # runs on every account whether or not it ever configured IPFIX. The
        # cap follows InstanceStateDriftSensor::MAX_PER_TICK; the difference is
        # that a starved orphan is not lost, it is summarised by the tail
        # signal below, which is what makes truncation honest rather than
        # silent data loss.
        def port_mapping_signals
          orphans = ::Sdwan::PortMapping.where(account_id: account.id, enabled: true)
                                        .includes(:target_peer, :target_virtual_ip)
                                        .find_each.lazy
                                        .select { |m| m.resolved_target_address.blank? }
                                        .first(MAX_ORPHANS_PER_TICK + 1)

          overflowed = orphans.size > MAX_ORPHANS_PER_TICK
          emitted = overflowed ? orphans.first(MAX_ORPHANS_PER_TICK) : orphans

          signals = emitted.map { |mapping| orphan_signal(mapping) }
          signals << orphan_overflow_signal(emitted.size) if overflowed
          signals
        end

        # Deliberately reports "more than N", not a total: the sweep stops at
        # the cap, so it has not counted the remainder and must not invent one.
        def orphan_overflow_signal(emitted_count)
          signal(
            kind: "system.sdwan_portmap_orphaned",
            severity: :medium,
            payload: {
              "overflow" => true,
              "emitted_count" => emitted_count,
              "summary" => "more than #{emitted_count} enabled DNAT rules have unresolvable targets; " \
                           "only the first #{emitted_count} are itemised this tick",
              "remediation_action" => nil
            },
            fingerprint: "sdwan_portmap_orphaned_overflow:#{account.id}"
          )
        end

        # The target that failed to resolve. Only TWO reasons are reachable,
        # and that is a schema guarantee rather than an assumption:
        #
        #   target_peer_id / target_virtual_ip_id both carry FKs declared with
        #   no on_delete clause, i.e. RESTRICT — Postgres refuses to delete a
        #   peer or VIP while a port mapping still references it. So a
        #   populated FK ALWAYS dereferences; "the target row was deleted" is
        #   not a state this table can hold.
        #
        #   sdwan_port_mappings_exactly_one_target is a check constraint and
        #   pg_constraint reports convalidated = true, so every row already
        #   satisfies it. "No target configured at all" cannot occur either.
        #
        # A review flagged the two-branch form as mislabelling deleted-target
        # and no-target rows. Those rows cannot exist; branches for them would
        # be dead code asserting a failure mode the database prevents, so the
        # distinction stays at the two states that can actually occur.
        def orphan_reason(mapping)
          return "vip_has_no_holder" if mapping.target_virtual_ip_id.present?

          "target_peer_unaddressed"
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
              "reason" => orphan_reason(mapping),
              "remediation_action" => nil
            },
            fingerprint: "sdwan_portmap_orphaned:#{mapping.id}"
          )
        end

        # Durable read model. Its only consumer today is this sensor itself —
        # severity_for_silence reads last_observed_flow_at, and the stamps keep
        # the columns honest across ticks. Nothing serialises health_state to
        # an API or UI yet and Service.silent has no caller; the operator-facing
        # surface is the signal, not the column. Said plainly here so the next
        # reader does not infer a dashboard that was never built.
        #
        # update_column deliberately skips validations, callbacks and
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
