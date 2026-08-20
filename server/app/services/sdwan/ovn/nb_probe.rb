# frozen_string_literal: true

require "socket"
require "json"
require "ipaddr"

module Sdwan
  module Ovn
    # IMP-57e9a90598ee — the control-plane half of the OVN activation oracle.
    #
    # Sdwan::OvnDeployment's nb_db_endpoint is an OPERATOR-ASSERTED string.
    # Nothing in this platform provisions ovn-northd or the OVN Northbound /
    # Southbound databases; the row records where an operator says they live.
    # So the only honest way to move a deployment out of "pending" is to go
    # look, and the only observation that means anything is one that could not
    # have been produced by the row's own existence.
    #
    # This probe opens a TCP socket to the endpoint and speaks OVSDB's
    # `list_dbs` JSON-RPC method (RFC 7047 §4.1.1). A reply naming
    # "OVN_Northbound" can only come from a running OVSDB server holding the
    # OVN Northbound schema — not from a create call succeeding, not from a
    # timer, not from an open port belonging to something else.
    #
    # THREE OUTCOMES, NEVER TWO. This mirrors the oracle contract the agent's
    # SubsystemStatus carries (agent/internal/sdwan/state.go):
    #
    #   :confirmed    we asked, and the answering server hosts OVN_Northbound.
    #   :failed       we asked, and got a refusal, a timeout, garbage, or an
    #                 OVSDB server that does NOT host OVN_Northbound. A
    #                 MEASURED negative.
    #   :not_measured we could not ask at all — blank endpoint, a scheme this
    #                 probe cannot speak (ssl:, unix:), or an endpoint it
    #                 cannot parse. NOT a health verdict in either direction;
    #                 a consumer that sees it must leave state alone.
    #
    # SCOPE, stated plainly: this measures reachability FROM THE CONTROL
    # PLANE. The chassis that actually use the NB DB are elsewhere on the
    # SDWAN overlay, and they can disagree. That is why the agent's own NB
    # replay observation (ObservedOvnNbState, ingested on the heartbeat)
    # outranks this probe wherever both have measured — see
    # DeploymentReconciler.
    class NbProbe
      # Every OVSDB server hosting the OVN northbound schema names it exactly
      # this in a list_dbs reply. It is the schema name, not a configurable.
      NB_DATABASE = "OVN_Northbound"

      DEFAULT_TIMEOUT_SECONDS  = 3
      DEFAULT_INTERVAL_SECONDS = 60

      # The endpoint is an OPERATOR-WRITABLE string and the probe opens raw
      # sockets from the control plane, so it refuses targets that could only
      # be internal-surface probing rather than an OVN NB DB on the overlay:
      # loopback, link-local, unspecified, and multicast — plus any
      # operator-configured control-plane CIDRs (the
      # "<SETTING_PREFIX>.probe_denied_cidrs" SiteSetting, comma-separated).
      # A denied target is :not_measured, never :failed — we refused to look,
      # we did not measure anything.
      BUILTIN_DENIED_NETWORKS = %w[
        127.0.0.0/8 ::1/128 0.0.0.0/32 ::/128
        169.254.0.0/16 fe80::/10 224.0.0.0/4 ff00::/8
      ].map { |cidr| IPAddr.new(cidr) }.freeze

      # Deployment-wide SiteSetting keys: "<SETTING_PREFIX>.<name>".
      SETTING_PREFIX = "system.sdwan.ovn"
      # Per-account override keys on Account#settings (flat, matching that
      # column's existing single-level convention).
      ACCOUNT_SETTING_PREFIX = "sdwan_ovn"

      # One probe outcome. Immutable; `state` is the only discriminator, and
      # the three predicates below are the only supported way to branch on it
      # — there is deliberately no `healthy?` that collapses :failed and
      # :not_measured together.
      class Result
        STATES = %i[confirmed failed not_measured].freeze

        attr_reader :state, :databases, :error, :reason, :probed_at

        def initialize(state:, databases: nil, error: nil, reason: nil, probed_at: nil)
          raise ArgumentError, "unknown state #{state.inspect}" unless STATES.include?(state)

          @state     = state
          @databases = databases
          @error     = error
          @reason    = reason
          @probed_at = probed_at || Time.current
        end

        def self.confirmed(databases:) = new(state: :confirmed, databases: databases)
        def self.failed(error:, databases: nil) = new(state: :failed, error: error, databases: databases)
        def self.not_measured(reason:) = new(state: :not_measured, reason: reason)

        def confirmed?    = state == :confirmed
        def failed?       = state == :failed
        def not_measured? = state == :not_measured
      end

      class << self
        # Probe with a short-lived cache so the fleet's heartbeats (every
        # heavyweight instance, every 30s) collapse into at most one socket
        # open per interval per deployment. A cache MISS probes; the cache
        # never manufactures a verdict of its own.
        def probe_cached(deployment)
          endpoint = deployment.nb_db_endpoint
          key = "sdwan/ovn/nb_probe/#{deployment.id}/#{Digest::SHA256.hexdigest(endpoint.to_s)}"
          cached = Rails.cache.read(key)
          return cached if cached.is_a?(Result)

          result = probe(endpoint, timeout: timeout_seconds(deployment.account))
          Rails.cache.write(key, result, expires_in: interval_seconds(deployment.account).seconds)
          result
        end

        # denied_networks is injectable so specs exercising the OVSDB exchange
        # against a loopback fake can pass [] — production callers take the
        # default (builtins + the operator denylist).
        def probe(endpoint, timeout: DEFAULT_TIMEOUT_SECONDS, denied_networks: default_denied_networks)
          return Result.not_measured(reason: "blank_endpoint") if endpoint.blank?

          scheme = endpoint.to_s.split(":", 2).first
          case scheme
          when "ssl"
            # The control plane holds no client certificate for the
            # operator's OVSDB, so a TLS probe would fail for a reason that
            # says nothing about the deployment. Refusing to guess is the
            # point.
            return Result.not_measured(reason: "tls_probe_unsupported")
          when "unix"
            # A unix socket path on the host running ovsdb-server, which is
            # not this host.
            return Result.not_measured(reason: "unix_socket_not_reachable_from_control_plane")
          end

          host, port = parse_endpoint(endpoint)
          return Result.not_measured(reason: "unparseable_endpoint") if host.nil?

          # Resolve first and vet EVERY address the name maps to, then connect
          # to a vetted literal — never re-resolve between the check and the
          # connect. A resolution failure is a measured negative (the operator
          # asserted a name that does not resolve).
          begin
            addresses = Addrinfo.getaddrinfo(host, port, nil, :STREAM).map(&:ip_address).uniq
          rescue SocketError => e
            return Result.failed(error: "#{e.class.name}: #{e.message}")
          end
          if addresses.empty? || addresses.any? { |a| denied_address?(a, denied_networks) }
            return Result.not_measured(reason: "endpoint_target_denied")
          end

          list_dbs(addresses.first, port, timeout)
        end

        # Parses OVN's connection-string forms into [host, port]. Accepts a
        # comma-separated cluster list and probes its first member — reaching
        # any one member proves the NB DB is up, which is all this oracle
        # claims. Returns nil on anything it cannot read.
        def parse_endpoint(endpoint)
          first = endpoint.to_s.split(",").first.to_s.strip
          body  = first.sub(/\A(tcp|ssl):/, "")

          # Bracketed IPv6 literal: [fd00::1]:6641
          if (m = body.match(/\A\[(?<host>.+)\]:(?<port>\d+)\z/))
            return [ m[:host], m[:port].to_i ]
          end

          # host:port with no colons in the host (IPv4 or DNS name).
          if (m = body.match(/\A(?<host>[^:\s]+):(?<port>\d+)\z/))
            return [ m[:host], m[:port].to_i ]
          end

          nil
        end

        def timeout_seconds(account)
          setting_seconds(account, "probe_timeout_seconds", DEFAULT_TIMEOUT_SECONDS)
        end

        def interval_seconds(account)
          setting_seconds(account, "probe_interval_seconds", DEFAULT_INTERVAL_SECONDS)
        end

        # BUILTIN_DENIED_NETWORKS plus the operator-configured control-plane
        # CIDRs. Unparseable configured entries are skipped (a typo in the
        # denylist must not open the probe up).
        def default_denied_networks
          extra = ::SiteSetting.get("#{SETTING_PREFIX}.probe_denied_cidrs").to_s.split(",").filter_map do |cidr|
            IPAddr.new(cidr.strip)
          rescue IPAddr::Error, ArgumentError
            Rails.logger.warn("[Sdwan::Ovn::NbProbe] skipping unparseable probe_denied_cidrs entry #{cidr.strip.inspect}")
            nil
          end
          BUILTIN_DENIED_NETWORKS + extra
        end

        private

        def denied_address?(address, denied_networks)
          ip = IPAddr.new(address)
          ip = ip.native if ip.ipv6? && ip.ipv4_mapped?
          denied_networks.any? do |net|
            net.include?(ip)
          rescue IPAddr::Error
            false # family mismatch — this network cannot contain this address
          end
        rescue IPAddr::Error, ArgumentError
          true # an address we cannot even read is not one we will connect to
        end

        # Per-account first, then the deployment-wide SiteSetting, then the
        # constant — the SdwanServiceHealthSensor precedent for an
        # account-tunable threshold on a multi-tenant control plane.
        def setting_seconds(account, suffix, fallback)
          raw = account&.settings&.dig("#{ACCOUNT_SETTING_PREFIX}_#{suffix}").presence ||
                ::SiteSetting.get("#{SETTING_PREFIX}.#{suffix}")
          value = raw.to_i
          value.positive? ? value : fallback
        end

        def list_dbs(host, port, timeout)
          socket = Socket.tcp(host, port, connect_timeout: timeout)
          begin
            socket.write({ id: "powernode-nb-probe", method: "list_dbs", params: [] }.to_json)
            raw = read_reply(socket, timeout)
          ensure
            socket.close
          end

          databases = extract_databases(raw)
          if databases.nil?
            return Result.failed(error: "endpoint did not return a readable OVSDB list_dbs reply")
          end

          if databases.include?(NB_DATABASE)
            Result.confirmed(databases: databases)
          else
            Result.failed(
              databases: databases,
              error: "endpoint answers OVSDB but does not host #{NB_DATABASE} " \
                     "(databases: #{databases.join(', ')})"
            )
          end
        rescue StandardError => e
          # A measured negative: we opened (or tried to open) the socket and
          # this is what happened. Distinct from :not_measured, which means
          # we never got as far as trying.
          Result.failed(error: "#{e.class.name}: #{e.message}")
        end

        # OVSDB replies are newline-free JSON objects streamed on the socket.
        # Read until the accumulated buffer parses, capped so a chatty or
        # hostile endpoint cannot hold the heartbeat open.
        def read_reply(socket, timeout)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
          buffer = +""
          while buffer.bytesize < 64 * 1024
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            break if remaining <= 0
            break unless socket.wait_readable(remaining)

            chunk = socket.read_nonblock(4096, exception: false)
            break if chunk.nil? || chunk == :wait_readable

            buffer << chunk
            return buffer if json_complete?(buffer)
          end
          buffer
        end

        def json_complete?(buffer)
          JSON.parse(buffer)
          true
        rescue JSON::ParserError
          false
        end

        def extract_databases(raw)
          parsed = JSON.parse(raw.to_s)
          return nil unless parsed.is_a?(Hash)

          result = parsed["result"]
          return nil unless result.is_a?(Array)

          result.map(&:to_s)
        rescue JSON::ParserError
          nil
        end
      end
    end
  end
end
