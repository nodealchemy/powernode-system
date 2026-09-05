# frozen_string_literal: true

module System
  module Platform
    # THE single composite platform-health producer.
    #
    # Offer 01a07024-d980. Three verbs used to answer "is the platform
    # healthy?" and they disagreed. On 2026-09-05 04:48Z
    # `platform_maintenance action=health_check` returned overall "ok" in the
    # same minute `platform_resilience op=failover_check` returned 11 (now 12)
    # NodeInstances in status "error", and an hour later the account Concierge
    # read `activity_monitor get_system_health` and told an operator "there are
    # no node instances in error status".
    #
    # None of those three was lying about what it measured. health_check built
    # four subsystem entries — rails, postgres, acme, federation — and
    # `rails_health` was the literal `{ status: "ok" }`. A constant that can
    # never be anything else is not a measurement; it is a claim, and it
    # outvoted every real observation in the aggregate because "ok" was the
    # default the aggregate fell through to.
    #
    # ── THE ORACLE RULE (the whole point of this class) ──────────────────
    #
    # A subsystem this probe could not observe reports `not_measured`, NEVER
    # `ok`. `not_measured` does not count as healthy when computing `overall`,
    # and it is visibly distinct in the payload (its own top-level list, its
    # own overall value `unknown`). The rule has a corollary that is easy to
    # get backwards: an observed refusal IS an observation. A connection
    # refused, a timeout, a 503 — those are `down`, because we asked and the
    # answer was no. `not_measured` is reserved for the case where the question
    # could not be put at all: no endpoint configured, a dependency of the
    # probe itself unavailable, or the probe raising something unexpected.
    #
    # The mirror of that rule: an OBSERVED-EMPTY scope is `ok`, not
    # `not_measured`. Zero federation peers, zero certificates, zero node
    # instances — we asked and the answer was "none", which is an answer.
    # Blindness is not emptiness and this class never conflates them.
    #
    # ── RANKING ──────────────────────────────────────────────────────────
    #
    #   down > degraded > not_measured > ok
    #
    # `down` outranks `not_measured` deliberately: a thing we watched fail is
    # more actionable than a thing we could not see. `not_measured` outranks
    # `ok` just as deliberately: that is the ordering whose absence produced
    # the wrong answer above.
    #
    # ── THRESHOLDS ───────────────────────────────────────────────────────
    #
    # Every window and timeout is read from SiteSetting so an operator can tune
    # it without a deploy. Numeric fallbacks are named constants here (they are
    # thresholds, not hostnames). Endpoint URLs have NO fallback on purpose: a
    # hardcoded hostname is forbidden, and an unconfigured endpoint is exactly
    # the `not_measured` case rather than something to guess at.
    class CompositeHealthProbe
      OK            = "ok"
      DEGRADED      = "degraded"
      DOWN          = "down"
      NOT_MEASURED  = "not_measured"

      # The overall a run reports when the worst thing it saw was its own
      # blindness. Distinct from `degraded`, and pointedly not `ok`.
      UNKNOWN = "unknown"

      RANK = { OK => 0, NOT_MEASURED => 1, DEGRADED => 2, DOWN => 3 }.freeze
      OVERALL_FOR_RANK = { 0 => OK, 1 => UNKNOWN, 2 => DEGRADED, 3 => DOWN }.freeze

      # Declared in the order an operator reads them: the platform's own
      # process first, then its stores, then the things it talks to, then the
      # fleet it manages. Every one of these appears in every payload.
      SUBSYSTEMS = %i[
        rails
        postgres
        redis
        sidekiq
        worker_web
        reverse_proxy
        mcp_endpoint
        fleet_tick
        ai_providers
        fleet_instances
        acme
        sdwan
        federation
      ].freeze

      SETTING_PREFIX = "system.platform_health"

      # Numeric defaults, used only when the operator has set nothing.
      DEFAULT_TICK_STALENESS_SECONDS   = 900   # 15m — a tick lane silent longer than this is not running
      DEFAULT_PROBE_TIMEOUT_SECONDS    = 5     # a health endpoint that needs longer is already degraded
      DEFAULT_INSTANCE_SILENCE_SECONDS = 900   # heartbeat gap before an instance counts as silent
      DEFAULT_PROVIDER_WINDOW_SECONDS  = 3600  # lookback for provider reachability evidence

      # Connectivity failures are OBSERVATIONS of down, not probe failures.
      # Anything outside this set escapes to the runner and lands as
      # not_measured — which is what "a probe raised" means.
      CONNECTIVITY_ERRORS = [
        Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::ETIMEDOUT,
        SocketError, Timeout::Error, Net::OpenTimeout, Net::ReadTimeout
      ].freeze

      attr_reader :account, :source

      def initialize(account:, source: nil)
        @account = account
        @source = source
      end

      # Run every probe and aggregate. Never raises for a subsystem failure —
      # a raising probe becomes that subsystem's `not_measured` entry, because
      # one unreachable dependency must not cost the operator the other nine
      # answers.
      def call
        subsystems = SUBSYSTEMS.index_with { |name| measure(name) }
        by_status = SUBSYSTEMS.group_by { |name| subsystems.fetch(name)[:status] }

        {
          overall: overall_for(subsystems),
          subsystems: subsystems,
          down: by_status.fetch(DOWN, []),
          degraded: by_status.fetch(DEGRADED, []),
          not_measured: by_status.fetch(NOT_MEASURED, []),
          generated_at: Time.current.iso8601
        }
      end

      # Run, then persist the run. Persistence failure must not swallow the
      # answer: an operator asking about health during a database incident
      # still gets the reading, with the write failure named in it.
      def call_and_persist!
        result = call
        snapshot = persist(result)
        result.merge(snapshot_id: snapshot&.id, persisted: snapshot.present?)
      end

      private

      def measure(name)
        entry = send(:"probe_#{name}")
        entry[:status] = NOT_MEASURED unless RANK.key?(entry[:status])
        entry
      rescue StandardError => e
        # A probe that blew up told us nothing about its subsystem. It did not
        # tell us the subsystem is fine.
        Rails.logger.warn("[CompositeHealthProbe] #{name} probe raised: #{e.class}: #{e.message}")
        { status: NOT_MEASURED, reason: "probe raised", error: "#{e.class}: #{e.message}" }
      end

      def overall_for(subsystems)
        worst = subsystems.values.map { |e| RANK.fetch(e[:status], RANK[NOT_MEASURED]) }.max
        OVERALL_FOR_RANK.fetch(worst || 0)
      end

      def persist(result)
        ::System::PlatformHealthSnapshot.create!(
          account: account,
          overall: result[:overall],
          subsystems: result[:subsystems],
          down_count: result[:down].size,
          degraded_count: result[:degraded].size,
          not_measured_count: result[:not_measured].size,
          source: source,
          captured_at: Time.current
        )
      rescue StandardError => e
        Rails.logger.error("[CompositeHealthProbe] snapshot write failed: #{e.class}: #{e.message}")
        nil
      end

      # ── settings ────────────────────────────────────────────────────────

      def setting(key)
        ::SiteSetting.get("#{SETTING_PREFIX}.#{key}")
      end

      def seconds_setting(key, default)
        value = setting(key)
        value.presence ? value.to_i : default
      end

      def url_setting(key)
        # No default. A hostname belongs in the database, and an absent one is
        # a not_measured, never a guess.
        setting(key).presence
      end

      def probe_timeout
        seconds_setting("probe_timeout_seconds", DEFAULT_PROBE_TIMEOUT_SECONDS)
      end

      # ── probes ──────────────────────────────────────────────────────────

      # We are running inside this process, so "is Rails up" is answerable
      # by construction — but that alone is the constant this class exists to
      # delete, so the entry reports something that can actually come back
      # wrong (pending migrations) and states how it was observed.
      def probe_rails
        migrations = migration_state

        # Migration state unreadable means we learned nothing about whether
        # this process is serving the schema it expects. That is exactly the
        # not_measured case, and reporting "ok" here would be a smaller version
        # of the constant this class exists to delete.
        unless migrations
          return { status: NOT_MEASURED, reason: "migration state unreadable",
                   observed_via: "in_process", env: Rails.env, ruby: RUBY_VERSION }
        end

        {
          status: migrations[:pending].zero? ? OK : DEGRADED,
          observed_via: "in_process",
          env: Rails.env,
          ruby: RUBY_VERSION,
          pending_migrations: migrations[:pending]
        }
      end

      # Counted against the same MigrationContext Rails' own
      # PendingMigrationError uses, so this entry agrees with what the app
      # would refuse to boot on. Returns nil when the state cannot be read.
      def migration_state
        context = ::ActiveRecord::Base.connection_pool.migration_context
        applied = context.get_all_versions.to_set
        { pending: context.migrations.count { |m| !applied.include?(m.version) } }
      rescue StandardError => e
        Rails.logger.warn("[CompositeHealthProbe] migration state unreadable: #{e.class}: #{e.message}")
        nil
      end

      def probe_postgres
        started = monotonic
        ::ActiveRecord::Base.connection.execute("SELECT 1")
        pool = ::ActiveRecord::Base.connection_pool.stat

        {
          status: OK,
          observed_via: "SELECT 1",
          response_time_ms: elapsed_ms(started),
          pool_size: pool[:size],
          pool_busy: pool[:busy]
        }
      rescue ::ActiveRecord::ConnectionNotEstablished, ::ActiveRecord::StatementInvalid,
             *CONNECTIVITY_ERRORS => e
        { status: DOWN, observed_via: "SELECT 1", error: "#{e.class}: #{e.message}" }
      end

      def probe_redis
        started = monotonic
        client = ::Powernode::Redis.new_client
        client.ping
        info = begin
          client.info
        rescue StandardError
          {}
        end

        {
          status: OK,
          observed_via: "PING",
          response_time_ms: elapsed_ms(started),
          used_memory: info["used_memory_human"],
          connected_clients: info["connected_clients"]&.to_i
        }
      rescue *redis_error_classes => e
        { status: DOWN, observed_via: "PING", error: "#{e.class}: #{e.message}" }
      end

      # Sidekiq runs in the standalone worker app, not here, and this app must
      # stay Sidekiq-free — so liveness is read from the process registry
      # Sidekiq keeps in the worker's Redis database rather than through the
      # gem. If Redis itself is unreachable the answer is not_measured: we
      # learned nothing about Sidekiq, only about Redis.
      def probe_sidekiq
        client = ::Powernode::Redis.new_worker_client
        processes = client.smembers("processes")
        queues = begin
          client.smembers("queues")
        rescue StandardError
          []
        end

        {
          status: processes.any? ? OK : DOWN,
          observed_via: "worker redis process registry",
          process_count: processes.size,
          queues: queues
        }
      rescue *redis_error_classes => e
        { status: NOT_MEASURED, reason: "worker redis unreachable — Sidekiq state unobservable",
          error: "#{e.class}: #{e.message}" }
      end

      def probe_worker_web
        started = monotonic
        body = ::WorkerTransport.new(open_timeout: probe_timeout, read_timeout: probe_timeout)
                                .get("/health")
        reported = body.is_a?(Hash) ? body["status"] : nil

        {
          status: reported.to_s == "ok" ? OK : DEGRADED,
          observed_via: "GET /health",
          response_time_ms: elapsed_ms(started),
          reported_status: reported,
          redis: body.is_a?(Hash) ? body["redis"] : nil,
          backend_api: body.is_a?(Hash) ? body["backend_api"] : nil
        }
      rescue ::WorkerTransport::ConnectionError, ::WorkerTransport::TimeoutError => e
        { status: DOWN, observed_via: "GET /health", error: "#{e.class}: #{e.message}" }
      rescue ::WorkerTransport::HttpError => e
        { status: DOWN, observed_via: "GET /health", http_status: e.status, error: e.message }
      end

      def probe_reverse_proxy
        http_endpoint_probe(
          url: url_setting("reverse_proxy_health_url"),
          setting_key: "#{SETTING_PREFIX}.reverse_proxy_health_url"
        )
      end

      def probe_mcp_endpoint
        http_endpoint_probe(
          url: url_setting("mcp_health_url"),
          setting_key: "#{SETTING_PREFIX}.mcp_health_url"
        )
      end

      # Shared shape for the two endpoint probes whose target is operator
      # configuration. An unset target is the not_measured case by definition:
      # there is nothing to ask.
      def http_endpoint_probe(url:, setting_key:)
        if url.blank?
          return {
            status: NOT_MEASURED,
            reason: "no health endpoint configured",
            configure_with: setting_key
          }
        end

        started = monotonic
        response = get_http(url)
        code = response.code.to_i

        {
          status: (200..399).cover?(code) ? OK : DOWN,
          observed_via: "GET #{url}",
          http_status: code,
          response_time_ms: elapsed_ms(started)
        }
      rescue *CONNECTIVITY_ERRORS => e
        { status: DOWN, observed_via: "GET #{url}", error: "#{e.class}: #{e.message}" }
      end

      def get_http(url)
        uri = URI.parse(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = probe_timeout
        http.read_timeout = probe_timeout
        http.request(Net::HTTP::Get.new(uri.request_uri.presence || "/"))
      end

      # When did the autonomy loop last complete a tick. A lane that stopped
      # running is the failure this catches: nothing errors, the fleet simply
      # stops being reconciled, and every other subsystem still reads fine.
      def probe_fleet_tick
        last = ::System::FleetEvent.where(account: account, kind: "fleet.tick_complete")
                                   .order(emitted_at: :desc).first

        unless last&.emitted_at
          return {
            status: NOT_MEASURED,
            reason: "no fleet.tick_complete has ever been recorded for this account"
          }
        end

        staleness = seconds_setting("tick_staleness_seconds", DEFAULT_TICK_STALENESS_SECONDS)
        age = (Time.current - last.emitted_at).to_i

        {
          status: age > staleness ? DEGRADED : OK,
          observed_via: "fleet.tick_complete",
          last_tick_at: last.emitted_at.iso8601,
          age_seconds: age,
          staleness_threshold_seconds: staleness
        }
      end

      # Reachability without sending traffic of our own. A provider is only
      # observable through the calls the platform already made: if nothing ran
      # in the window there is no evidence either way, and this says so instead
      # of reporting the provider fine.
      def probe_ai_providers
        providers = ::Ai::Provider.where(account_id: account.id, is_active: true)
                                  .includes(:provider_credentials)
        return { status: NOT_MEASURED, reason: "no active providers configured" } if providers.empty?

        window = seconds_setting("provider_window_seconds", DEFAULT_PROVIDER_WINDOW_SECONDS).seconds.ago
        rows = providers.map { |provider| provider_row(provider, window) }

        measured = rows.reject { |r| r[:status] == NOT_MEASURED }
        status =
          if measured.empty?           then NOT_MEASURED
          elsif measured.all? { |r| r[:status] == DOWN } then DOWN
          elsif measured.any? { |r| r[:status] != OK }   then DEGRADED
          else OK
          end

        {
          status: status,
          observed_via: "recent agent execution outcomes",
          window_seconds: seconds_setting("provider_window_seconds", DEFAULT_PROVIDER_WINDOW_SECONDS),
          total: rows.size,
          providers: rows
        }
      end

      def provider_row(provider, window)
        has_credential = provider.provider_credentials.any? { |c| c.is_active? && c.account_id == account.id }
        executions = ::Ai::AgentExecution.where(agent: ::Ai::Agent.where(provider: provider))
                                         .where("created_at >= ?", window)
        total = executions.count
        failed = executions.where(status: "failed").count

        row = {
          name: provider.name,
          provider_type: provider.provider_type,
          has_active_credential: has_credential,
          executions_in_window: total,
          failed_in_window: failed
        }

        # No credential is a configuration fact we CAN see, so it is degraded
        # rather than unobservable. No traffic is genuinely unobservable.
        return row.merge(status: DEGRADED, reason: "no active credential") unless has_credential
        return row.merge(status: NOT_MEASURED, reason: "no executions in window") if total.zero?

        row.merge(status: failed == total ? DOWN : (failed.positive? ? DEGRADED : OK))
      end

      # The subsystem whose absence produced the wrong answer. Counted from the
      # instance rows themselves, in one grouped query.
      def probe_fleet_instances
        scope = ::System::NodeInstance.joins(:node).where(system_nodes: { account_id: account.id })
        by_status = scope.group(:status).count
        total = by_status.values.sum

        # Observed empty, not unobserved — see the class doc.
        if total.zero?
          return { status: OK, observed_via: "node instance status + heartbeat",
                   total: 0, error_count: 0, silent_count: 0, by_status: {} }
        end

        error_count = by_status.fetch("error", 0)
        silence = seconds_setting("instance_silence_seconds", DEFAULT_INSTANCE_SILENCE_SECONDS)
        silent_count = scope.where(status: ::System::NodeInstance::ACTIVE_STATUSES)
                            .where("last_heartbeat_at IS NULL OR last_heartbeat_at < ?", silence.seconds.ago)
                            .count

        status =
          if error_count == total then DOWN
          elsif error_count.positive? || silent_count.positive? then DEGRADED
          else OK
          end

        {
          status: status,
          observed_via: "node instance status + heartbeat",
          total: total,
          error_count: error_count,
          silent_count: silent_count,
          silence_threshold_seconds: silence,
          by_status: by_status
        }
      end

      # ── acme / sdwan / federation ───────────────────────────────────────
      #
      # These three carry over from the two producers this class replaces (the
      # old four-entry health_check and Api::V1::System::Platform::HealthController).
      # A composite that covered less than what it supersedes could not be the
      # single truth, so they are here rather than dropped.
      #
      # Both predecessors returned `{ status: "unknown" }` when the model was
      # not loaded. That instinct was right and is preserved as `not_measured`
      # — an absent capability is unobservable, not healthy.

      def probe_acme
        return { status: NOT_MEASURED, reason: "AcmeCertificate not loaded" } unless defined?(::System::AcmeCertificate)

        certs = ::System::AcmeCertificate.where(account: account)
        by_status = certs.group(:status).count
        valid = certs.where(status: "valid")
        expiring_30d = valid.where("expires_at < ?", 30.days.from_now).count
        expiring_7d  = valid.where("expires_at < ?", 7.days.from_now).count
        failed = by_status.fetch("failed", 0)

        {
          status: (expiring_7d.positive? || failed.positive?) ? DEGRADED : OK,
          observed_via: "certificate rows",
          total: by_status.values.sum,
          by_status: by_status,
          expiring_within_30d: expiring_30d,
          expiring_within_7d: expiring_7d,
          failed_count: failed,
          nearest_expiry_at: valid.minimum(:expires_at)&.iso8601
        }
      end

      def probe_sdwan
        return { status: NOT_MEASURED, reason: "Sdwan::VirtualIp not loaded" } unless defined?(::Sdwan::VirtualIp)

        vips = ::Sdwan::VirtualIp.where(account: account)
        assigned = if defined?(::Sdwan::VirtualIpAssignment)
                     ::Sdwan::VirtualIpAssignment.joins(:virtual_ip)
                       .where(system_sdwan_virtual_ips: { account_id: account.id }).count
                   end
        networks = defined?(::Sdwan::Network) ? ::Sdwan::Network.where(account: account).count : nil
        bgp_total = bgp_established = nil
        if defined?(::Sdwan::BgpSession)
          bgp_total = ::Sdwan::BgpSession.count
          bgp_established = ::Sdwan::BgpSession.established.count
        end

        # No BGP sessions is an observed-empty control plane, not a broken one.
        status = if bgp_total.nil? || bgp_total.zero? || bgp_established == bgp_total
                   OK
                 else
                   DEGRADED
                 end

        {
          status: status,
          observed_via: "BGP session state",
          networks_count: networks,
          virtual_ip_count: vips.count,
          virtual_ips_assigned: assigned,
          bgp: { total: bgp_total, established: bgp_established }
        }
      end

      def probe_federation
        return { status: NOT_MEASURED, reason: "FederationPeer not loaded" } unless defined?(::System::FederationPeer)

        peers = ::System::FederationPeer.where(account: account, peer_kind: "platform")
        total = peers.count
        stale = peers.heartbeat_stale.count
        degraded = peers.degraded.count

        {
          status: (stale.positive? || degraded.positive?) ? DEGRADED : OK,
          observed_via: "peer heartbeat + status",
          total: total,
          active: peers.active_status.count,
          degraded_peers: degraded,
          suspended: peers.suspended.count,
          heartbeat_stale: stale,
          last_handshake_at: peers.maximum(:last_handshake_at)&.iso8601
        }
      end

      # ── helpers ─────────────────────────────────────────────────────────

      # Resolved lazily: the redis gem's error tree is only loaded once a
      # client has been required, and naming the constants at class-body time
      # would couple this file's load order to it.
      def redis_error_classes
        classes = CONNECTIVITY_ERRORS.dup
        classes << ::Redis::BaseError if defined?(::Redis::BaseError)
        classes
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def elapsed_ms(started)
        ((monotonic - started) * 1000).round(2)
      end
    end
  end
end
