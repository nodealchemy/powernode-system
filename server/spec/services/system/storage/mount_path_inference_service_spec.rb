# frozen_string_literal: true

require "rails_helper"

RSpec.describe ::System::Storage::MountPathInferenceService, type: :service do
  describe ".infer" do
    # Table-driven coverage: one expectation per inference rule.
    SERVICE_USER_CASES = {
      "/var/lib/postgresql"           => "postgres",
      "/var/lib/postgresql/16/main"   => "postgres",
      "/var/lib/mysql"                => "mysql",
      "/var/lib/mariadb"              => "mariadb",
      "/var/lib/redis"                => "redis",
      "/var/lib/mongodb/data"         => "mongodb",
      "/var/lib/elasticsearch"        => "elasticsearch",
      "/var/lib/influxdb"             => "influxdb",
      "/var/lib/cassandra"            => "cassandra",
      "/var/lib/memcached"            => "memcached",
      "/var/lib/cockroach/data"       => "cockroachdb",
      "/etc/nginx"                    => "nginx",
      "/etc/nginx/conf.d"             => "nginx",
      "/var/lib/nginx/cache"          => "nginx",
      "/var/log/nginx"                => "nginx",
      "/var/www"                      => "www-data",
      "/var/www/html"                 => "www-data",
      "/etc/traefik"                  => "traefik",
      "/var/lib/caddy"                => "caddy",
      "/var/lib/haproxy"              => "haproxy",
      "/var/lib/varnish"              => "varnish",
      "/var/lib/rabbitmq"             => "rabbitmq",
      "/var/lib/nats"                 => "nats",
      "/var/lib/kafka"                => "kafka",
      "/var/lib/pulsar"               => "pulsar",
      "/var/lib/prometheus"           => "prometheus",
      "/var/lib/grafana"              => "grafana",
      "/var/lib/loki"                 => "loki",
      "/var/lib/tempo"                => "tempo",
      "/var/lib/gitea"                => "gitea",
      "/var/lib/jenkins"              => "jenkins",
      "/var/lib/woodpecker"           => "woodpecker",
      "/var/lib/vault"                => "vault",
      "/var/lib/consul"               => "consul",
      "/var/lib/etcd"                 => "etcd",
      "/var/lib/powernode"            => "powernode"
    }.freeze

    SERVICE_USER_CASES.each do |path, expected_username|
      it "infers service_user '#{expected_username}' for #{path}" do
        result = described_class.infer(path)
        expect(result[:kind]).to eq(:service_user)
        expect(result[:username]).to eq(expected_username)
      end
    end

    {
      "/home/operator"          => :operator,
      "/home/operator/workdir"  => :operator,
      "/srv/operator/data"      => :operator,
      "/var/log/audit"          => :root,
      "/var/log/secure"         => :root,
      "/etc/systemd"            => :root,
      "/boot/grub"              => :root,
      "/tmp"                    => :nobody,
      "/var/tmp/scratch"        => :nobody
    }.each do |path, expected_kind|
      it "infers #{expected_kind} for #{path}" do
        expect(described_class.infer(path)[:kind]).to eq(expected_kind)
      end
    end

    %w[/random/place /srv/some/app /opt/customstuff /mnt/data].each do |path|
      it "returns :unresolved for unmatched path #{path}" do
        expect(described_class.infer(path)).to eq(kind: :unresolved)
      end
    end

    it "returns :unresolved for blank mount_path" do
      expect(described_class.infer("")).to eq(kind: :unresolved)
      expect(described_class.infer(nil)).to eq(kind: :unresolved)
    end

    it "prefers more-specific rules over generic /etc/* fallback" do
      # /etc/nginx → nginx (specific), NOT /etc/* → root
      expect(described_class.infer("/etc/nginx/sites-enabled")[:kind]).to eq(:service_user)
      expect(described_class.infer("/etc/nginx/sites-enabled")[:username]).to eq("nginx")
      # /etc/something-else → root (generic)
      expect(described_class.infer("/etc/cron.d")[:kind]).to eq(:root)
    end
  end

  describe ".resolvable?" do
    it "is true for matched paths and false for unresolved" do
      expect(described_class.resolvable?("/var/lib/postgresql")).to be true
      expect(described_class.resolvable?("/etc/nginx")).to be true
      expect(described_class.resolvable?("/random/junk")).to be false
      expect(described_class.resolvable?("")).to be false
    end
  end
end
