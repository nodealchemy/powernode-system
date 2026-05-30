# frozen_string_literal: true

module System
  module Storage
    # System::Storage::MountPathInferenceService — maps a mount_path to
    # an inferred StorageAssignment owner. Used by the owner-refactor
    # migration's backfill step and by the agent / operator surfaces
    # that want a sensible default when creating new assignments.
    #
    # Returns a hash with :kind (one of StorageAssignment::OWNER_KINDS)
    # and optionally :username (when kind == :service_user). Returns
    # { kind: :unresolved } when nothing matches.
    #
    # Rule order matters: more specific patterns first (e.g. /etc/nginx
    # before /etc/*) so the more-specific service binding wins. The
    # rules live in code (not config) because mount_path → service
    # mapping is a convention that humans encode; making it data would
    # mean the rules sit somewhere harder to audit and easier to
    # silently corrupt.
    #
    # Failure mode by design: unresolved (loud) rather than wrong-owner
    # (silent). When inference can't pick a winner, the caller decides:
    # the migration aborts loud, the operator UI / MCP surfaces the
    # ambiguity.
    class MountPathInferenceService
      INFERENCE_RULES = [
        # === Database services (70100..70199 reserved slots) ===
        { pattern: %r{\A/var/lib/postgresql(?:/|\z)},     kind: :service_user, username: "postgres" },
        { pattern: %r{\A/var/lib/mysql(?:/|\z)},          kind: :service_user, username: "mysql" },
        { pattern: %r{\A/var/lib/mariadb(?:/|\z)},        kind: :service_user, username: "mariadb" },
        { pattern: %r{\A/var/lib/redis(?:/|\z)},          kind: :service_user, username: "redis" },
        { pattern: %r{\A/var/lib/mongodb(?:/|\z)},        kind: :service_user, username: "mongodb" },
        { pattern: %r{\A/var/lib/elasticsearch(?:/|\z)},  kind: :service_user, username: "elasticsearch" },
        { pattern: %r{\A/var/lib/influxdb(?:/|\z)},       kind: :service_user, username: "influxdb" },
        { pattern: %r{\A/var/lib/memcached(?:/|\z)},      kind: :service_user, username: "memcached" },
        { pattern: %r{\A/var/lib/cassandra(?:/|\z)},      kind: :service_user, username: "cassandra" },
        { pattern: %r{\A/var/lib/cockroach(?:/|\z)},      kind: :service_user, username: "cockroachdb" },

        # === Web servers (70200..70299) ===
        { pattern: %r{\A/etc/nginx(?:/|\z)},              kind: :service_user, username: "nginx" },
        { pattern: %r{\A/var/lib/nginx(?:/|\z)},          kind: :service_user, username: "nginx" },
        { pattern: %r{\A/var/log/nginx(?:/|\z)},          kind: :service_user, username: "nginx" },
        { pattern: %r{\A/var/www(?:/|\z)},                kind: :service_user, username: "www-data" },
        { pattern: %r{\A/etc/traefik(?:/|\z)},            kind: :service_user, username: "traefik" },
        { pattern: %r{\A/var/lib/caddy(?:/|\z)},          kind: :service_user, username: "caddy" },
        { pattern: %r{\A/var/lib/haproxy(?:/|\z)},        kind: :service_user, username: "haproxy" },
        { pattern: %r{\A/var/lib/varnish(?:/|\z)},        kind: :service_user, username: "varnish" },

        # === Messaging (70300..70399) ===
        { pattern: %r{\A/var/lib/rabbitmq(?:/|\z)},       kind: :service_user, username: "rabbitmq" },
        { pattern: %r{\A/var/lib/nats(?:/|\z)},           kind: :service_user, username: "nats" },
        { pattern: %r{\A/var/lib/kafka(?:/|\z)},          kind: :service_user, username: "kafka" },
        { pattern: %r{\A/var/lib/pulsar(?:/|\z)},         kind: :service_user, username: "pulsar" },

        # === Observability (70400..70499) ===
        { pattern: %r{\A/var/lib/prometheus(?:/|\z)},     kind: :service_user, username: "prometheus" },
        { pattern: %r{\A/var/lib/grafana(?:/|\z)},        kind: :service_user, username: "grafana" },
        { pattern: %r{\A/var/lib/loki(?:/|\z)},           kind: :service_user, username: "loki" },
        { pattern: %r{\A/var/lib/tempo(?:/|\z)},          kind: :service_user, username: "tempo" },

        # === CI/CD (70500..70599) ===
        { pattern: %r{\A/var/lib/gitea(?:/|\z)},          kind: :service_user, username: "gitea" },
        { pattern: %r{\A/var/lib/jenkins(?:/|\z)},        kind: :service_user, username: "jenkins" },
        { pattern: %r{\A/var/lib/woodpecker(?:/|\z)},     kind: :service_user, username: "woodpecker" },

        # === Platform infra (70600..70699) ===
        { pattern: %r{\A/var/lib/vault(?:/|\z)},          kind: :service_user, username: "vault" },
        { pattern: %r{\A/var/lib/consul(?:/|\z)},         kind: :service_user, username: "consul" },
        { pattern: %r{\A/var/lib/etcd(?:/|\z)},           kind: :service_user, username: "etcd" },
        { pattern: %r{\A/var/lib/powernode(?:/|\z)},      kind: :service_user, username: "powernode" },

        # === Non-service owners — order matters: specific (/var/log/audit) before generic (/etc/*) ===
        { pattern: %r{\A/home/pnadmin(?:/|\z)},           kind: :operator },
        { pattern: %r{\A/srv/pnadmin(?:/|\z)},            kind: :operator },
        { pattern: %r{\A/var/log/(?:audit|secure|system)(?:/|\z)}, kind: :root },
        { pattern: %r{\A/etc/(?!nginx|traefik)},          kind: :root },
        { pattern: %r{\A/boot(?:/|\z)},                   kind: :root },
        { pattern: %r{\A/tmp(?:/|\z)},                    kind: :nobody },
        { pattern: %r{\A/var/tmp(?:/|\z)},                kind: :nobody }
      ].freeze

      # Returns a hash describing the inferred owner. Callers branch on
      # `:kind`. Keys present in the return:
      #
      #   { kind: :service_user, username: "postgres" }
      #   { kind: :operator }
      #   { kind: :nobody }
      #   { kind: :root }
      #   { kind: :unresolved }
      def self.infer(mount_path)
        return { kind: :unresolved } if mount_path.blank?

        rule = INFERENCE_RULES.find { |r| mount_path.to_s.match?(r[:pattern]) }
        return { kind: :unresolved } unless rule

        result = { kind: rule[:kind] }
        result[:username] = rule[:username] if rule[:username]
        result
      end

      # Convenience predicate: would this mount_path resolve to a
      # specific owner? Returns false for :unresolved.
      def self.resolvable?(mount_path)
        infer(mount_path)[:kind] != :unresolved
      end
    end
  end
end
