# frozen_string_literal: true

require "faraday"
require "json"

module System
  module Providers
    module Proxmox
      # Faraday-backed REST client for the Proxmox VE API.
      #
      # Encapsulates:
      #   - API token authentication (`PVEAPIToken=<user@realm!tokenid>=<secret>`)
      #   - TLS verification toggle (self-signed PVE certs are common in homelab)
      #   - JSON request/response handling
      #   - UPID task polling for async operations
      #   - URL-component encoding for path segments containing `:`, `@`, `!`
      #   - Error mapping (401 → AuthenticationError, 403 → AuthenticationError,
      #     404 → ResourceNotFoundError, 429 → RateLimitError)
      #
      # === API token caveats ===
      # Tokens with Privilege Separation ON must have explicit ACL grants on
      # paths — granting roles to the underlying user does NOT propagate.
      # When the token has no grants, PVE silently returns `{"data": {}}` or
      # `{"data": null}` rather than 403. The caller MUST probe perms via
      # `/access/permissions` before trusting empty responses as "no resources".
      class Client
        DEFAULT_CONNECT_TIMEOUT  = 10
        DEFAULT_READ_TIMEOUT     = 60
        DEFAULT_TASK_TIMEOUT     = 300   # seconds
        DEFAULT_TASK_POLL_EVERY  = 2     # seconds
        TASK_TERMINAL_STATUS     = "stopped"

        class Error < StandardError; end
        class AuthError < Error; end
        class NotFoundError < Error; end
        class RateLimitError < Error; end
        class TaskFailedError < Error
          attr_reader :exit_status, :log_tail
          def initialize(message, exit_status:, log_tail: [])
            super(message)
            @exit_status = exit_status
            @log_tail = log_tail
          end
        end
        class TaskTimeoutError < Error; end

        attr_reader :endpoint, :token_id, :verify_ssl

        # @param endpoint [String] PVE API base, e.g. "https://pve.example.com:8006"
        # @param token_id [String] "user@realm!tokenname" (e.g. "root@pam!powernode")
        # @param token_secret [String] UUID secret
        # @param verify_ssl [Boolean]
        # @param connect_timeout [Integer]
        # @param read_timeout [Integer]
        def initialize(endpoint:, token_id:, token_secret:, verify_ssl: true,
                       connect_timeout: DEFAULT_CONNECT_TIMEOUT,
                       read_timeout: DEFAULT_READ_TIMEOUT)
          @endpoint = endpoint.to_s.sub(%r{/+\z}, "")
          @token_id = token_id
          @token_secret = token_secret
          @verify_ssl = verify_ssl
          @connect_timeout = connect_timeout
          @read_timeout = read_timeout
        end

        # ------------------------------------------------------------------
        # HTTP verbs — each returns the parsed `data` field from PVE responses,
        # raising on transport / auth / not-found / rate-limit errors.
        # ------------------------------------------------------------------

        def get(path, params = nil)
          request(:get, path, params: params)
        end

        def post(path, body = nil)
          request(:post, path, body: body)
        end

        def put(path, body = nil)
          request(:put, path, body: body)
        end

        def delete(path, params = nil)
          request(:delete, path, params: params)
        end

        # ------------------------------------------------------------------
        # UPID handling — PVE async operations return a UPID string; the
        # caller polls /tasks/{upid}/status until status == "stopped".
        # ------------------------------------------------------------------

        # Encodes a UPID for use as a URL path segment.
        # UPIDs look like:
        #   UPID:dna:000D6722:1867630E:6A0D37CC:qmstart:100:admin@pam!powernode:
        # The `:`, `@`, `!` and trailing characters all need escaping.
        def encode_upid(upid)
          # %2F-safe and friendly to the underlying CGI escape rules
          CGI.escape(upid)
        end

        # @param node [String] PVE node name (e.g. "dna")
        # @param upid [String] task UPID returned from a write call
        # @param timeout [Integer] max seconds to wait
        # @param poll_every [Integer] seconds between polls
        # @return [Hash] final status payload (with :exitstatus == "OK" on success)
        # @raise [TaskFailedError] if the task reports a non-OK exit
        # @raise [TaskTimeoutError] if the task doesn't complete in time
        def wait_task(node:, upid:, timeout: DEFAULT_TASK_TIMEOUT, poll_every: DEFAULT_TASK_POLL_EVERY)
          deadline = monotonic_now + timeout
          encoded = encode_upid(upid)
          loop do
            status = get("/api2/json/nodes/#{node}/tasks/#{encoded}/status")
            if status["status"] == TASK_TERMINAL_STATUS
              exit_status = status["exitstatus"]
              if exit_status == "OK"
                return status
              else
                log_tail = fetch_task_log_tail(node: node, upid: upid)
                raise TaskFailedError.new(
                  "PVE task #{status['type']} on #{node} failed: #{exit_status}",
                  exit_status: exit_status,
                  log_tail: log_tail
                )
              end
            end
            raise TaskTimeoutError, "Timed out after #{timeout}s waiting for #{upid}" if monotonic_now > deadline
            sleep(poll_every)
          end
        end

        # Fetch the last N lines of a task log. Useful for surfacing
        # actionable error context to callers when a task fails.
        def fetch_task_log_tail(node:, upid:, lines: 20)
          encoded = encode_upid(upid)
          log = get("/api2/json/nodes/#{node}/tasks/#{encoded}/log")
          (log || []).last(lines).map { |entry| entry["t"] }.compact
        rescue StandardError
          []
        end

        # ------------------------------------------------------------------
        # Privilege probe — call BEFORE trusting empty list responses as
        # "the cluster is empty". When ACL grants are missing, PVE returns
        # silently-empty data on resource queries, which is indistinguishable
        # from a genuinely empty cluster without this check.
        # ------------------------------------------------------------------

        # @return [Hash{String=>Hash}] map of path → privileges
        def effective_permissions
          get("/api2/json/access/permissions") || {}
        end

        # @return [Boolean] true if the token has at least one ACL grant
        def has_any_grants?
          !effective_permissions.empty?
        end

        # ------------------------------------------------------------------

        private

        def monotonic_now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        def request(verb, path, params: nil, body: nil)
          response = connection.public_send(verb) do |req|
            req.url(path)
            req.params.update(params) if params && !params.empty?
            if body
              # PVE expects form-urlencoded for write operations (NOT JSON).
              # Faraday's `url_encoded` middleware handles this when we set body as Hash.
              req.body = body
            end
          end

          handle_response(response)
        rescue Faraday::ConnectionFailed => e
          raise Error, "PVE connection failed: #{e.message}"
        rescue Faraday::TimeoutError => e
          raise Error, "PVE request timed out: #{e.message}"
        end

        def handle_response(response)
          case response.status
          when 200..299
            parsed = response.body
            parsed = JSON.parse(parsed) if parsed.is_a?(String) && !parsed.empty?
            parsed.is_a?(Hash) ? parsed["data"] : parsed
          when 401, 403
            raise AuthError, extract_error_message(response, "Unauthorized")
          when 404
            raise NotFoundError, extract_error_message(response, "Not found")
          when 429
            raise RateLimitError, extract_error_message(response, "Rate limited")
          else
            raise Error, "PVE #{response.status}: #{extract_error_message(response, 'API error')}"
          end
        end

        def extract_error_message(response, fallback)
          body = response.body
          body = JSON.parse(body) if body.is_a?(String) && !body.empty?
          return fallback unless body.is_a?(Hash)

          if body["errors"].is_a?(Hash)
            body["errors"].map { |k, v| "#{k}: #{v}" }.join("; ")
          elsif body["message"]
            body["message"].to_s.strip
          else
            fallback
          end
        rescue JSON::ParserError
          fallback
        end

        def connection
          @connection ||= Faraday.new(url: @endpoint, ssl: { verify: @verify_ssl }) do |f|
            f.request :url_encoded
            f.response :json, content_type: /\bjson$/
            f.headers["Authorization"] = "PVEAPIToken=#{@token_id}=#{@token_secret}"
            f.headers["Accept"] = "application/json"
            f.options.timeout = @read_timeout
            f.options.open_timeout = @connect_timeout
            f.adapter Faraday.default_adapter
          end
        end
      end
    end
  end
end
