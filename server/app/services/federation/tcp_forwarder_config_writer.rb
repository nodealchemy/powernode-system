# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"

module Federation
  # Subscriber-side writer: generates the on-node config for the
  # powernode-tcp-forwarder agent daemon (Go package
  # extensions/system/agent/internal/tcpfwd) from active
  # System::Federation::ServiceSubscription rows that ServiceRouteWriter
  # deliberately excludes -- SITE-LOCAL ones (never go through Traefik)
  # AND, as of increment 4's cutover, any TCP-PROTOCOL subscription
  # regardless of site-local-ness (Traefik's HostSNI rule can never
  # match plaintext TCP, so tcp-protocol subs never had a working
  # Traefik path to begin with -- see ServiceRouteWriter's class
  # comment + P4.6.7/increment 4).
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
  # the agent side loads it at startup as of increment 4 (see
  # agent/internal/tcpfwd/config.go's DefaultConfigPath, wired into
  # agent/internal/runtime/service.go's Run()).
  #
  # Empty-set semantics: zero active eligible subscriptions still
  # produces {"forwards": []} (config.go#Validate accepts an empty
  # list) rather than deleting/omitting the file. The agent's service
  # loop tolerates a MISSING file (skips starting the daemon -- idle
  # steady state for a node the platform never configured), but
  # writing an explicit empty config keeps "platform manages this
  # node, zero forwards right now" distinguishable from "never
  # configured", and a malformed file still surfaces loudly via the
  # agent's OnError path.
  #
  # Listen-address fork (increment 4, NOT plan-specified -- flagged in
  # the increment's report): site-local local_hostname already embeds
  # a port ("localhost:5432"), so listen_address can use it verbatim.
  # A non-site-local tcp-protocol subscription's local_hostname is a
  # BARE hostname with no port (it was written for Host()/HostSNI()
  # rules, which don't take a port) -- there is no plan or runbook
  # text describing what such a subscription's tcpfwd bind address
  # should be. This writer's conservative choice: pair local_hostname
  # verbatim with the subscription's own backend_port (both fields
  # already stored on the row; no wildcard/0.0.0.0 bind invented). See
  # listen_address for the exact logic and the report's recommendation
  # for a follow-up decision.
  #
  # Plan reference: Decentralized Federation §L.5 + P4.6.7.
  class TcpForwarderConfigWriter
    class WriteError < StandardError; end

    # Canonical on-node path the powernode-tcp-forwarder daemon reads
    # from (wired into the agent's service loop in increment 4). MUST
    # stay byte-for-byte identical to the Go side's
    # tcpfwd.DefaultConfigPath (agent/internal/tcpfwd/config.go) --
    # two independent implementations of the same on-disk contract,
    # with no shared build-time check tying them together. Override
    # via CONFIG_PATH_ENV_VAR for non-standard installs/tests.
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
      subs = active_forwarder_subs
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

    # Site-local subs (never touch Traefik) OR tcp-protocol subs
    # (increment 4 cutover -- ServiceRouteWriter excludes these too;
    # exactly one writer runs per subscription, matching
    # ServiceRouteWriter#active_traefik_subs's exclusion).
    def active_forwarder_subs
      ::System::Federation::ServiceSubscription
        .where(account: @account, status: "active")
        .select { |sub| sub.site_local? || sub.protocol == "tcp" }
    end

    def render_forward(sub)
      {
        "listen" => listen_address(sub),
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
    # "127.0.0.1:<port>" (ServiceSubscription#site_local?) -- the port
    # is already embedded, so the split below yields it directly. The
    # forwarder always binds the loopback interface -- never the
    # literal string "localhost" -- so normalize that case, preserving
    # the port. The "127.0.0.1:<port>" case already needs no change.
    #
    # A non-site-local tcp-protocol subscription's local_hostname has
    # NO embedded port (it's a bare hostname meant for Host()/HostSNI()
    # rules, which are port-less) -- split yields a nil port, so we
    # fall back to the subscription's own backend_port. See this
    # class's doc comment ("Listen-address fork") for why this is the
    # conservative, plan-unspecified choice rather than an invented
    # wildcard bind.
    def listen_address(sub)
      host, port = sub.local_hostname.to_s.split(":", 2)
      host = "127.0.0.1" if host == "localhost"
      port ||= sub.backend_port
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
