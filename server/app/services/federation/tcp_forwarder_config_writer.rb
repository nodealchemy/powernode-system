# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"

module Federation
  # Subscriber-side writer: generates the on-node config for the
  # powernode-tcp-forwarder agent daemon (Go package
  # extensions/system/agent/internal/tcpfwd) from active, SITE-LOCAL
  # System::Federation::ServiceSubscription rows -- the ones
  # ServiceRouteWriter deliberately excludes because they never go
  # through Traefik (see ServiceRouteWriter's class comment + P4.6.7).
  #
  # Output shape (must match tcpfwd/doc.go + config.go#Validate
  # exactly -- this Ruby writer and the Go loader are two independent
  # implementations of the same contract):
  #
  #   {
  #     "forwards": [
  #       {
  #         "listen": "127.0.0.1:5432",
  #         "backend": "[fd00:b0b::20]:5432",
  #         "protocol": "tcp",
  #         "subscription_id": "<uuid>"
  #       }
  #     ]
  #   }
  #
  # One JSON file per site (not per-account-in-a-shared-dir like
  # Traefik's dynamic config) -- a tcpfwd daemon runs on the
  # subscriber's own node, so there is exactly one canonical on-node
  # path. DEFAULT_CONFIG_PATH/CONFIG_PATH_ENV_VAR is that contract;
  # the agent side does not consume it yet (see finding below).
  #
  # Empty-set semantics: zero active site-local subscriptions still
  # produces {"forwards": []} (config.go#Validate accepts an empty
  # list) rather than deleting/omitting the file -- the daemon side
  # treats "config missing" as a startup error but "config present
  # with zero forwards" as a valid (idle) steady state.
  #
  # Known finding (increment 3, confirmed by grep): as of this
  # writing, package tcpfwd has zero references anywhere in the agent
  # tree outside internal/tcpfwd/ itself -- no `service` subcommand
  # wiring, no config-path constant. The daemon is not yet started by
  # `powernode-agent service`. Wiring it in is increment-4+ territory;
  # this writer only needs to emit a spec-correct file at a sensible,
  # env-overridable path for that future consumer.
  #
  # Plan reference: Decentralized Federation §L.5 + P4.6.7.
  class TcpForwarderConfigWriter
    class WriteError < StandardError; end

    # Canonical on-node path the (not-yet-wired) powernode-tcp-forwarder
    # daemon will read from. Override via CONFIG_PATH_ENV_VAR for
    # non-standard installs/tests.
    DEFAULT_CONFIG_PATH = "/etc/powernode/tcpfwd/forwards.json"
    CONFIG_PATH_ENV_VAR = "POWERNODE_TCPFWD_CONFIG_PATH"

    class << self
      def write!(account:, config_path: resolved_default_path)
        new(account: account, config_path: config_path).write!
      end

      def resolved_default_path
        ENV[CONFIG_PATH_ENV_VAR].presence || DEFAULT_CONFIG_PATH
      end
    end

    def initialize(account:, config_path:)
      @account = account
      @config_path = config_path
    end

    def write!
      subs = active_site_local_subs
      config = render_config(subs)

      FileUtils.mkdir_p(File.dirname(@config_path))
      atomic_write(JSON.pretty_generate(config))

      { output_path: @config_path, forward_count: subs.size }
    rescue StandardError => e
      raise WriteError, "TcpForwarderConfigWriter failed: #{e.class}: #{e.message}"
    end

    # Renders the forwards config hash. Public for testability (no
    # filesystem side effects), mirroring ServiceRouteWriter#render_yaml.
    def render_config(subs)
      { "forwards" => subs.map { |sub| render_forward(sub) } }
    end

    private

    def active_site_local_subs
      ::System::Federation::ServiceSubscription
        .where(account: @account, status: "active")
        .select(&:site_local?)
    end

    def render_forward(sub)
      {
        "listen" => listen_address(sub.local_hostname),
        "backend" => backend_address(sub.backend_vip, sub.backend_port),
        # v1 forwarder supports TCP only (config.go#Validate rejects
        # anything else) -- hard-coded regardless of the subscription's
        # own `protocol` attribute, which describes the ORIGINAL
        # offering (site-local subs can be created with a non-tcp
        # protocol since ServiceSubscription#public_protocol_requires_cert
        # skips its check for site-local hostnames).
        "protocol" => "tcp",
        "subscription_id" => sub.id
      }
    end

    # site-local local_hostname is "localhost:<port>" or
    # "127.0.0.1:<port>" (ServiceSubscription#site_local?). The
    # forwarder always binds the loopback interface -- never the
    # literal string "localhost" -- so normalize that case, preserving
    # the port. The "127.0.0.1:<port>" case already needs no change.
    def listen_address(local_hostname)
      host, port = local_hostname.to_s.split(":", 2)
      host = "127.0.0.1" if host == "localhost"
      "#{host}:#{port}"
    end

    # backend_vip is the SDWAN overlay VIP, normally an unbracketed
    # IPv6 ULA (see ServiceRouteWriter's backend rendering, which
    # leaves it unbracketed for Traefik's loadBalancer "address"
    # field). The Go side parses "backend" with net.SplitHostPort,
    # which requires bracket-quoting a literal IPv6 host -- so this
    # writer brackets it (a deliberate divergence from
    # ServiceRouteWriter, which has no such requirement).
    def backend_address(vip, port)
      host = vip.to_s
      host = "[#{host}]" if host.include?(":") && !host.start_with?("[")
      "#{host}:#{port}"
    end

    # Writes to a sibling temp file then renames into place, so the
    # daemon (which may be reading the file concurrently on its own
    # schedule) never observes a truncated/partial JSON document.
    # Same directory as the target so the rename is an atomic POSIX
    # rename(2), not a cross-filesystem copy.
    def atomic_write(contents)
      dir = File.dirname(@config_path)
      tmp_path = File.join(dir, ".#{File.basename(@config_path)}.tmp-#{Process.pid}-#{SecureRandom.hex(4)}")
      File.write(tmp_path, contents)
      File.rename(tmp_path, @config_path)
    ensure
      File.delete(tmp_path) if tmp_path && File.exist?(tmp_path)
    end
  end
end
