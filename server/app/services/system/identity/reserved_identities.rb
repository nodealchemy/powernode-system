# frozen_string_literal: true

module System
  module Identity
    # Curated map of well-known daemon names to platform-stable UIDs/GIDs.
    # Used by the allocator's fast path so that the SAME daemon always
    # gets the SAME numeric ID across every Powernode install, anywhere.
    #
    # Why category-based slots rather than distro-derived offsets:
    # Debian, RHEL, and container-image conventions all disagree on the
    # "right" UID for things like postgres (102 vs 26 vs 999), and many
    # daemons share UIDs in the dense 100-199 range purely based on
    # install order. Categorical slots give every entry a mnemonic
    # 10-aligned offset, eliminate collision risk, and leave huge gaps
    # for future additions without renumbering.
    #
    # Allocation range: 70000..99999. Reserved entries occupy 70100..70999.
    # The sequential-allocation pool starts at 71000 — entries here are
    # NEVER reused for new names, so the reserved table can grow without
    # disturbing previously-allocated sequential IDs.
    #
    # Exception: the BASELINE category (below) reserves ids OUTSIDE the
    # 70xxx range entirely (e.g. pnadmin at 1000) — these are agent
    # baseline accounts, not allocator-managed daemons. They're folded
    # into USERS/GROUPS/all_reserved_ids purely for cross-check
    # completeness; nothing treats 70100..70999 as the exhaustive set of
    # reserved values.
    #
    # To add a new well-known daemon: pick the next free 10-aligned slot
    # in the appropriate category. Both Ruby (USERS/GROUPS) and
    # extensions/system/agent/internal/etcidentity/reserved.go must stay
    # in sync — the rake task `mcp:generate_reserved_identities_go`
    # regenerates the Go file from this constant.
    module ReservedIdentities
      # Sequential allocation starts here. Anything below this is either
      # a reserved entry from the table below or unused.
      SEQUENTIAL_FLOOR = 71_000

      # 70100..70199 — databases & datastores
      DATABASES = {
        "postgres"      => 70_110,
        "mysql"         => 70_120,
        "mariadb"       => 70_121,
        "mongodb"       => 70_130,
        "redis"         => 70_140,
        "memcached"     => 70_150,
        "cassandra"     => 70_160,
        "elasticsearch" => 70_170,
        "influxdb"      => 70_180,
        "cockroachdb"   => 70_190
      }.freeze

      # 70200..70299 — web servers & reverse proxies
      WEB_SERVERS = {
        "nginx"   => 70_210,
        "www-data" => 70_220,   # apache / generic www
        "caddy"   => 70_230,
        "traefik" => 70_240,
        "haproxy" => 70_250,
        "varnish" => 70_260
      }.freeze

      # 70300..70399 — message brokers & queues
      MESSAGING = {
        "rabbitmq" => 70_310,
        "nats"     => 70_320,
        "kafka"    => 70_330,
        "pulsar"   => 70_340
      }.freeze

      # 70400..70499 — observability
      OBSERVABILITY = {
        "prometheus" => 70_410,
        "grafana"    => 70_420,
        "loki"       => 70_430,
        "tempo"      => 70_440,
        "jaeger"     => 70_450,
        "vector"     => 70_460,
        "fluentbit"  => 70_470
      }.freeze

      # 70500..70599 — CI/CD & source control
      CICD = {
        "gitea"      => 70_510,
        "jenkins"    => 70_520,
        "woodpecker" => 70_530,
        "drone"      => 70_540
      }.freeze

      # 70600..70699 — secrets, identity, & platform infra
      PLATFORM = {
        "vault"     => 70_610,
        "consul"    => 70_620,
        "etcd"      => 70_630,
        "powernode" => 70_690   # the platform's own service account
      }.freeze

      # 70700..70799 — application servers / runtimes
      APP_RUNTIMES = {
        "tomcat"    => 70_710,
        "wildfly"   => 70_720,
        "puma"      => 70_730,
        "unicorn"   => 70_740,
        "gunicorn"  => 70_750
      }.freeze

      # Baseline/system fixed-uid accounts — NOT part of the 70xxx
      # allocator range at all. These are hardcoded into the agent's
      # etcidentity.Baseline() (agent/internal/etcidentity/baseline.go)
      # and rendered to every node's /etc/passwd before the platform has
      # been contacted even once (first-boot bootstrap). They are listed
      # here ONLY so the platform's uid/gid map is complete and the
      # allocator + validators can cross-check against them — nothing in
      # this table causes a ServiceUser/ServiceGroup row to be created at
      # these ids (System::ServiceUser::UID_MIN/GID_MIN start at 70_000,
      # well above 1000, so these values are never candidates for
      # sequential allocation, they just need to be excluded from it).
      #
      # Do NOT add sequentially-allocated module users here (e.g. a
      # `pnrunner` that some module allocates via the 70xxx pool) —
      # reserving a name that's actually assigned sequentially is
      # fragile: reallocation would invalidate any id baked into this
      # table, whereas the runtime reconcile (UserAllocator/GroupAllocator)
      # already handles those correctly without a fixed entry.
      BASELINE = {
        "pnadmin" => 1_000
      }.freeze

      USERS = [
        DATABASES, WEB_SERVERS, MESSAGING, OBSERVABILITY,
        CICD, PLATFORM, APP_RUNTIMES, BASELINE
      ].reduce({}, :merge).freeze

      # Group reservations mirror users by default — every reserved user
      # gets a same-name primary group at the same numeric value. The
      # allocator falls back to sequential allocation for groups whose
      # name doesn't appear in USERS (e.g. supplementary groups like
      # `ssl-cert` that aren't tied to a single daemon).
      GROUPS = USERS.dup.freeze

      def self.uid_for(username)
        USERS[username.to_s]
      end

      def self.gid_for(groupname)
        GROUPS[groupname.to_s]
      end

      def self.all_reserved_ids
        USERS.values.to_set
      end
    end
  end
end
