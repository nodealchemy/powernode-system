# frozen_string_literal: true

module Api
  module V1
    module System
      module Platform
        # Aggregate platform-health snapshot for the
        # /app/system/compute/platform/health dashboard panel. Pulls
        # per-subsystem signals (rails, worker, redis, postgres, traefik,
        # sdwan, federation, sidekiq cron) and returns a flat envelope
        # the frontend renders as cards.
        #
        # No new persistence layer — everything is aggregated live from
        # existing models + Redis/PG stats. Safe to call repeatedly
        # (~30s polling target from the UI).
        #
        # Plan reference: Decentralized Federation §I + P7.2.
        class HealthController < ApplicationController
          before_action :authenticate_request

          def show
            return forbidden unless current_user&.has_permission?("system.platform.health.read")

            render_success(
              health: {
                rails:        rails_health,
                worker:       worker_health,
                redis:        redis_health,
                postgres:     postgres_health,
                acme:         acme_health,
                sdwan:        sdwan_health,
                federation:   federation_health,
                generated_at: Time.current.iso8601
              }
            )
          end

          private

          def forbidden
            render_error("Forbidden", status: :forbidden)
          end

          # ── Rails API ────────────────────────────────────────────────────
          def rails_health
            uptime_seconds = process_uptime_seconds
            {
              status: "ok",
              uptime_seconds: uptime_seconds,
              uptime_human: humanize_duration(uptime_seconds),
              db_connected: db_connected?,
              rails_env: Rails.env,
              ruby_version: RUBY_VERSION
            }
          rescue StandardError => e
            { status: "down", error: e.message }
          end

          # Returns Rails process uptime in seconds. Reads /proc/self/stat
          # field 22 (starttime in clock ticks since boot) and subtracts
          # from current monotonic time. Falls back to 0 if /proc is
          # unavailable (non-Linux dev).
          def process_uptime_seconds
            return @process_uptime_seconds if defined?(@process_uptime_seconds)
            return (@process_uptime_seconds = 0) unless File.exist?("/proc/self/stat")

            stat = File.read("/proc/self/stat")
            # Field 22 is starttime (clock ticks since boot). Skip past
            # the process name (in parens) so we don't trip on names
            # containing spaces.
            after_name = stat.sub(/\A\d+ \([^)]*\) /, "")
            fields = after_name.split(" ")
            starttime_ticks = fields[19].to_i # 22 - 3 (pid, comm, state) = 19 0-indexed
            ticks_per_sec   = `getconf CLK_TCK`.to_i
            ticks_per_sec   = 100 if ticks_per_sec.zero?

            uptime_seconds = File.read("/proc/uptime").split(" ").first.to_f
            process_age_ticks = (uptime_seconds * ticks_per_sec) - starttime_ticks
            @process_uptime_seconds = (process_age_ticks / ticks_per_sec).to_i
          rescue StandardError
            @process_uptime_seconds = 0
          end

          def db_connected?
            ActiveRecord::Base.connection.execute("SELECT 1")
            true
          rescue StandardError
            false
          end

          # ── Worker (Sidekiq) ─────────────────────────────────────────────
          # Worker state is reported by the standalone worker process via
          # the worker_api → server bridge. We read the most recent
          # FleetEvent or fall back to summarizing what we can see from
          # cached cron metadata.
          def worker_health
            # Best-effort: most platform deployments run Sidekiq stats
            # against the same Redis the server uses for caching. If the
            # gem isn't available in the server's path, the values fall
            # back to "unknown".
            stats = begin
              require "sidekiq/api"
              s = Sidekiq::Stats.new
              {
                processed: s.processed,
                failed: s.failed,
                enqueued: s.enqueued,
                scheduled: s.scheduled_size,
                retry_size: s.retry_size,
                dead_size: s.dead_size,
                processes: s.processes_size,
                default_queue_latency: s.default_queue_latency&.round(2)
              }
            rescue LoadError, StandardError
              {}
            end

            last_seen = ::Worker.where(is_system: false).maximum(:last_seen_at) if defined?(::Worker)
            status =
              if stats[:processes]&.positive?
                "ok"
              elsif stats[:enqueued]&.positive? || stats[:processed]&.positive?
                # Stats visible but no live process — degraded
                "degraded"
              else
                "unknown"
              end

            {
              status: status,
              stats: stats,
              last_seen_at: last_seen&.iso8601
            }
          rescue StandardError => e
            { status: "down", error: e.message }
          end

          # ── Redis ────────────────────────────────────────────────────────
          def redis_health
            cache_ok = Rails.cache.write("__platform_health_probe", Time.current.iso8601, expires_in: 5.seconds)
            roundtrip = Rails.cache.read("__platform_health_probe")
            {
              status: cache_ok && roundtrip.present? ? "ok" : "degraded",
              cache_store: Rails.cache.class.name,
              probe_at: Time.current.iso8601
            }
          rescue StandardError => e
            { status: "down", error: e.message }
          end

          # ── Postgres ─────────────────────────────────────────────────────
          def postgres_health
            conn = ActiveRecord::Base.connection
            db_size = conn.execute("SELECT pg_database_size(current_database()) AS bytes").first["bytes"].to_i
            active_conns = conn.execute(
              "SELECT count(*) AS n FROM pg_stat_activity WHERE state = 'active'"
            ).first["n"].to_i

            {
              status: "ok",
              database: conn.current_database,
              size_bytes: db_size,
              size_human: humanize_bytes(db_size),
              active_connections: active_conns
            }
          rescue StandardError => e
            { status: "down", error: e.message }
          end

          # ── ACME / Traefik ───────────────────────────────────────────────
          def acme_health
            return { status: "unknown" } unless defined?(::System::AcmeCertificate)

            certs = ::System::AcmeCertificate.where(account: current_account)
            valid = certs.where(status: "valid")
            expiring_30d = valid.where("expires_at < ?", 30.days.from_now).count
            expiring_7d  = valid.where("expires_at < ?", 7.days.from_now).count
            failed       = certs.where(status: "failed").count

            status =
              if expiring_7d.positive? || failed.positive?
                "degraded"
              else
                "ok"
              end

            {
              status: status,
              count: certs.count,
              by_status: certs.group(:status).count,
              expiring_within_30d: expiring_30d,
              expiring_within_7d: expiring_7d,
              failed_count: failed,
              nearest_expiry_at: valid.minimum(:expires_at)&.iso8601
            }
          rescue StandardError => e
            { status: "down", error: e.message }
          end

          # ── SDWAN ────────────────────────────────────────────────────────
          def sdwan_health
            return { status: "unknown" } unless defined?(::Sdwan::VirtualIp)

            vips = ::Sdwan::VirtualIp.where(account: current_account)
            assignments = if defined?(::Sdwan::VirtualIpAssignment)
                            ::Sdwan::VirtualIpAssignment.joins(:virtual_ip)
                                                        .where(sdwan_virtual_ips: { account_id: current_account.id })
            end
            networks = ::Sdwan::Network.where(account: current_account) if defined?(::Sdwan::Network)
            bgp_total = bgp_established = nil
            if defined?(::Sdwan::BgpSession)
              bgp_total = ::Sdwan::BgpSession.count
              bgp_established = ::Sdwan::BgpSession.established.count
            end

            bgp_status =
              if bgp_total.nil? || bgp_total.zero?
                "ok"
              elsif bgp_established == bgp_total
                "ok"
              else
                "degraded"
              end

            {
              status: bgp_status,
              networks_count: networks&.count || 0,
              virtual_ips: { count: vips.count, assigned: assignments&.count || 0 },
              bgp: { total: bgp_total, established: bgp_established }
            }
          rescue StandardError => e
            { status: "down", error: e.message }
          end

          # ── Federation ───────────────────────────────────────────────────
          def federation_health
            return { status: "unknown" } unless defined?(::System::FederationPeer)

            peers = ::System::FederationPeer.where(account: current_account, peer_kind: "platform")
            stale = peers.heartbeat_stale.count
            active = peers.active_status.count
            degraded = peers.degraded.count
            total = peers.count

            status =
              if total.zero?
                "ok"
              elsif degraded.positive? || stale.positive?
                "degraded"
              else
                "ok"
              end

            {
              status: status,
              total: total,
              active: active,
              degraded: degraded,
              suspended: peers.suspended.count,
              heartbeat_stale: stale,
              last_handshake_at: peers.maximum(:last_handshake_at)&.iso8601
            }
          rescue StandardError => e
            { status: "down", error: e.message }
          end

          # ── Helpers ──────────────────────────────────────────────────────
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
