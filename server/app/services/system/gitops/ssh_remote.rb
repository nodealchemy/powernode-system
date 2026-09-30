# frozen_string_literal: true

require "uri"

module System
  module Gitops
    # IMP-1e5db5e6aefb — the endpoint a GitOps SSH remote connects to: host,
    # port and user, read off the two URL shapes git accepts for ssh.
    #
    #   ssh://[user@]host[:port]/path   (host may be a bracketed IPv6 literal)
    #   [user@]host:path                (scp-style; no "://", port is 22)
    #
    # ssh-keyscan needs the host and port; the sync's known_hosts alias is
    # keyed on the repository instead (RepositoryHostKey.alias_for), so a URL
    # respelling never orphans a recorded key. Returns nil for anything that
    # is not an ssh remote or does not parse cleanly, so a malformed URL can
    # never become an argv element: the host must match HOST_FORMAT and the
    # port must be a real port.
    #
    # .ssh? is the same test: an ssh remote is one this module can pin. The
    # git-builtin spellings git+ssh:// and ssh+git:// are deliberately not
    # parsed (no legacy forms) — git would route them to the PATH ssh on its
    # own, outside the pin — so they, like an unparseable host, are refused
    # by the model at registration and by the sync before git runs.
    module SshRemote
      Endpoint = Struct.new(:host, :port, :user, keyword_init: true)

      DEFAULT_PORT = 22
      # A DNS name, IPv4 literal or (from a bracketed ssh:// authority) IPv6
      # literal. No leading dash: the host is passed to ssh-keyscan as its
      # own argument and must never read as an option.
      HOST_FORMAT = /\A[A-Za-z0-9][A-Za-z0-9.:-]*\z/
      SCP_FORMAT  = /\A(?:(?<user>[A-Za-z0-9._-]+)@)?(?<host>[^@:\/\s]+):(?<path>.*)\z/

      module_function

      def ssh?(url)
        !parse(url).nil?
      end

      # Endpoint or nil. Never raises.
      def parse(url)
        return nil unless url.is_a?(String) && url.present?

        endpoint = url.start_with?("ssh://") ? parse_uri(url) : parse_scp(url)
        return nil unless endpoint && endpoint.host.to_s.match?(HOST_FORMAT)
        return nil unless endpoint.port.is_a?(Integer) && endpoint.port.between?(1, 65_535)

        endpoint
      end

      def parse_uri(url)
        uri = URI.parse(url)
        return nil if uri.host.blank?

        # URI keeps the brackets on an IPv6 literal; known_hosts and
        # ssh-keyscan want the bare address.
        host = uri.host.delete_prefix("[").delete_suffix("]")
        # URI.parse refuses an out-of-range port with InvalidURIError; a
        # zero port parses, so it is left to the range check in .parse.
        Endpoint.new(host: host, port: uri.port || DEFAULT_PORT, user: uri.user.presence)
      rescue URI::InvalidURIError, URI::InvalidComponentError
        nil
      end

      def parse_scp(url)
        return nil if url.include?("://")

        match = url.match(SCP_FORMAT)
        return nil unless match

        Endpoint.new(host: match[:host], port: DEFAULT_PORT, user: match[:user])
      end
    end
  end
end
