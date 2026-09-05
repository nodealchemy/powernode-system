# frozen_string_literal: true

module Api
  module V1
    module System
      module Platform
        # Aggregate platform-health snapshot for the
        # /app/system/compute/platform/health dashboard panel.
        #
        # ── WHY THIS IS A THIN ADAPTER NOW ────────────────────────────────
        #
        # This endpoint used to carry its OWN copy of every subsystem probe.
        # That made it the fourth producer of "is the platform healthy?" on a
        # platform that already had three, and it disagreed with them the same
        # way they disagreed with each other (offer 01a07024-d980):
        #
        #   * `rails_health` returned the literal `{ status: "ok" }` — a value
        #     that could never come back anything else, on the card an operator
        #     looks at first.
        #   * there was no fleet-instance subsystem at all, so the panel could
        #     render every card green while NodeInstances sat in status
        #     "error". That is the dashboard version of the Concierge telling
        #     an operator "there are no node instances in error status" while
        #     12 were.
        #   * `worker_health` tried `require "sidekiq/api"` inside the Rails
        #     app. The server is deliberately Sidekiq-free (no such gem in
        #     server/Gemfile), so that require has always raised LoadError, the
        #     stats hash has always been empty, and the Worker Pool card has
        #     always read "unknown / — live". Removed: the composite reads the
        #     Sidekiq process registry out of the worker's Redis instead, which
        #     answers the question without the dependency.
        #
        # Every status now comes from System::Platform::CompositeHealthProbe,
        # which is the single producer. This controller only ADAPTS that output
        # to the response contract the frontend already consumes.
        #
        # ── THE CONTRACT ──────────────────────────────────────────────────
        #
        # frontend/src/features/system/types/platform-health.types.ts pins
        # `SubsystemStatus = 'ok' | 'degraded' | 'down' | 'unknown'`, and
        # HealthPanel's StatusPill indexes a Record keyed by exactly those four
        # and dereferences the result with NO default. A fifth value is not a
        # cosmetic problem — it is a TypeError that blanks the whole panel.
        #
        # So the probe's `not_measured` is mapped onto the contract's existing
        # `unknown`, which already means "we do not know" and already renders
        # as a grey HelpCircle. The precise value travels beside it in an
        # ADDITIVE `measurement` field, which the current renderer ignores and
        # a future one can use. Nothing is removed from the response; the new
        # keys (overall, fleet_instances, worker_web, reverse_proxy,
        # mcp_endpoint, fleet_tick, ai_providers, and the down/degraded/
        # not_measured name lists) are additions.
        #
        # ── PRESENTATION ENRICHMENT ───────────────────────────────────────
        #
        # A few fields the cards render are decoration the probe does not
        # measure: process uptime, database size, active connection count, the
        # cache store's class name. Those are gathered here and are NEVER
        # status-bearing — if an enrichment query fails the card loses a
        # number, and the subsystem keeps whatever status the probe gave it. A
        # formatting failure must not be able to manufacture an outage.
        #
        # Plan reference: Decentralized Federation §I + P7.2.
        class HealthController < ApplicationController
          before_action :authenticate_request

          # `not_measured` is the probe's word; `unknown` is the contract's.
          # Same meaning, and only one of them is renderable.
          WIRE_STATUS = { "not_measured" => "unknown" }.freeze

          def show
            return forbidden unless current_user&.has_permission?("system.platform.health.read")

            # `call`, not `call_and_persist!`. The panel polls every 30s; an
            # operator invoking the MCP verb is a discrete event worth a row,
            # a poll is not, and persisting one would write thousands of rows
            # a day per open tab.
            result = ::System::Platform::CompositeHealthProbe
                     .new(account: current_account, source: "platform_health_dashboard")
                     .call

            render_success(health: envelope(result))
          end

          private

          def forbidden
            render_error("Forbidden", status: :forbidden)
          end

          def envelope(result)
            subsystems = result[:subsystems]

            {
              # Additive: the old response had no aggregate at all, which is
              # part of why nobody noticed the cards disagreeing.
              overall: wire_status(result[:overall]),

              # The seven legacy keys, in their original order.
              rails:      rails_entry(subsystems[:rails], subsystems[:postgres]),
              worker:     worker_entry(subsystems[:sidekiq]),
              redis:      redis_entry(subsystems[:redis]),
              postgres:   postgres_entry(subsystems[:postgres]),
              acme:       acme_entry(subsystems[:acme]),
              sdwan:      sdwan_entry(subsystems[:sdwan]),
              federation: federation_entry(subsystems[:federation]),

              # Additive subsystems. `fleet_instances` is the one whose absence
              # let this panel report green during a fleet incident.
              fleet_instances: entry(subsystems[:fleet_instances]),
              worker_web:      entry(subsystems[:worker_web]),
              reverse_proxy:   entry(subsystems[:reverse_proxy]),
              mcp_endpoint:    entry(subsystems[:mcp_endpoint]),
              fleet_tick:      entry(subsystems[:fleet_tick]),
              ai_providers:    entry(subsystems[:ai_providers]),

              # Additive: name the subsystems at each status so blindness is
              # readable without walking every card.
              down:         result[:down],
              degraded:     result[:degraded],
              not_measured: result[:not_measured],

              generated_at: result[:generated_at]
            }
          end

          # Adapts one probe entry to the wire: renderable status, plus the
          # precise measurement word when the probe could not observe.
          def entry(probe_entry)
            probe_entry = (probe_entry || {}).dup
            raw = probe_entry[:status].to_s
            probe_entry[:status] = wire_status(raw)
            probe_entry[:measurement] = raw if raw == "not_measured"
            probe_entry
          end

          def wire_status(status)
            WIRE_STATUS.fetch(status.to_s, status.to_s)
          end

          # ── legacy-shaped entries ────────────────────────────────────────

          # `db_connected` is the Postgres probe's verdict rather than a second
          # SELECT 1 — one connectivity check, one answer, no way for the two
          # to disagree on the same page.
          def rails_entry(probe_entry, postgres_entry)
            uptime = enrich { process_uptime_seconds }

            entry(probe_entry).merge(
              rails_env: probe_entry&.dig(:env) || Rails.env,
              ruby_version: probe_entry&.dig(:ruby) || RUBY_VERSION,
              uptime_seconds: uptime,
              uptime_human: humanize_duration(uptime),
              db_connected: postgres_entry&.dig(:status).to_s == "ok"
            )
          end

          # The card wants a `stats` hash. The probe reports what it can see of
          # Sidekiq from the worker Redis process registry; queue-depth
          # counters are not observable from this process and are simply
          # absent rather than guessed at.
          def worker_entry(probe_entry)
            last_seen = enrich { ::Worker.where(is_system: false).maximum(:last_seen_at) if defined?(::Worker) }

            entry(probe_entry).merge(
              stats: { processes: probe_entry&.dig(:process_count) }.compact,
              last_seen_at: last_seen&.iso8601
            )
          end

          # The next three rename probe fields onto the names the cards read.
          # The probe keeps a flat payload for its own consumers; naming the
          # contract shape is this adapter's whole job, and getting it wrong
          # is silent — the card renders a fallback dash rather than erroring.

          def acme_entry(probe_entry)
            entry(probe_entry).merge(count: probe_entry&.dig(:total))
          end

          def sdwan_entry(probe_entry)
            entry(probe_entry).merge(
              virtual_ips: {
                count: probe_entry&.dig(:virtual_ip_count),
                assigned: probe_entry&.dig(:virtual_ips_assigned)
              }
            )
          end

          def federation_entry(probe_entry)
            entry(probe_entry).merge(degraded: probe_entry&.dig(:degraded_peers))
          end

          def redis_entry(probe_entry)
            entry(probe_entry).merge(
              cache_store: Rails.cache.class.name,
              probe_at: Time.current.iso8601
            )
          end

          def postgres_entry(probe_entry)
            metrics = enrich { postgres_metrics } || {}
            entry(probe_entry).merge(metrics)
          end

          # ── presentation enrichment (never status-bearing) ───────────────

          # Runs a decoration query and swallows its failure. The caller merges
          # whatever came back; a nil merges as an absent field, and the
          # subsystem keeps the status the PROBE gave it.
          def enrich
            yield
          rescue StandardError => e
            Rails.logger.warn("[PlatformHealth] enrichment failed: #{e.class}: #{e.message}")
            nil
          end

          def postgres_metrics
            conn = ActiveRecord::Base.connection
            size = conn.execute("SELECT pg_database_size(current_database()) AS bytes").first["bytes"].to_i
            active = conn.execute(
              "SELECT count(*) AS n FROM pg_stat_activity WHERE state = 'active'"
            ).first["n"].to_i

            {
              database: conn.current_database,
              size_bytes: size,
              size_human: humanize_bytes(size),
              active_connections: active
            }
          end

          # Rails process uptime in seconds, from /proc/self/stat field 22
          # (starttime in clock ticks since boot). Returns 0 where /proc is
          # unavailable (non-Linux dev).
          def process_uptime_seconds
            return @process_uptime_seconds if defined?(@process_uptime_seconds)
            return (@process_uptime_seconds = 0) unless File.exist?("/proc/self/stat")

            stat = File.read("/proc/self/stat")
            # Skip past the process name (in parens) so a name containing
            # spaces does not shift the field offsets.
            after_name = stat.sub(/\A\d+ \([^)]*\) /, "")
            fields = after_name.split(" ")
            starttime_ticks = fields[19].to_i # field 22, minus pid/comm/state
            ticks_per_sec = `getconf CLK_TCK`.to_i
            ticks_per_sec = 100 if ticks_per_sec.zero?

            boot_uptime = File.read("/proc/uptime").split(" ").first.to_f
            process_age_ticks = (boot_uptime * ticks_per_sec) - starttime_ticks
            @process_uptime_seconds = (process_age_ticks / ticks_per_sec).to_i
          rescue StandardError
            @process_uptime_seconds = 0
          end

          def humanize_duration(seconds)
            return "—" if seconds.nil? || seconds.negative?

            d, r = seconds.divmod(86_400)
            h, r = r.divmod(3_600)
            m, _ = r.divmod(60)
            parts = []
            parts << "#{d}d" if d.positive?
            parts << "#{h}h" if h.positive?
            parts << "#{m}m" if m.positive? || parts.empty?
            parts.join(" ")
          end

          def humanize_bytes(bytes)
            return "—" if bytes.nil?

            units = %w[B KB MB GB TB]
            unit_idx = 0
            value = bytes.to_f
            while value >= 1_024 && unit_idx < units.size - 1
              value /= 1_024
              unit_idx += 1
            end
            "#{value.round(1)} #{units[unit_idx]}"
          end
        end
      end
    end
  end
end
