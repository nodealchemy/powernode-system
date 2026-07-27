# frozen_string_literal: true

require "faraday"
require "faraday/multipart"
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
        # Multipart uploads stream the whole file body inside a single request,
        # so they need a far longer read timeout than a normal API call — a
        # multi-GB disk image can take minutes even on a fast LAN.
        DEFAULT_UPLOAD_TIMEOUT   = 1_800 # seconds
        TASK_TERMINAL_STATUS     = "stopped"
        # How many consecutive "no such task" polls to tolerate before giving up —
        # covers the brief window where a just-returned UPID isn't yet queryable.
        TASK_NOT_READY_MAX_RETRIES = 15

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

        # Multipart file upload to a PVE storage (POST .../storage/{storage}/upload).
        #
        # Unlike download-url (where PVE fetches a URL itself), this pushes the
        # bytes from us to PVE over the same token-authenticated, dev->PVE
        # direction the rest of the API uses — so it works for source bytes that
        # live on storage PVE has no way to reach (e.g. the platform's local
        # FileStorage). `content` is the PVE content type: "iso" | "vztmpl" |
        # "import" (import = foreign disk image, PVE 8.1+/9.x).
        #
        # @param io [IO] an open, rewound, binary-mode readable of the file bytes
        # @return [String] the UPID of the resulting async task (poll via wait_task)
        def upload_file(node:, storage:, filename:, io:, content: "import",
                        checksum: nil, checksum_algorithm: nil, timeout: DEFAULT_UPLOAD_TIMEOUT)
          payload = {
            "content"  => content,
            "filename" => Faraday::Multipart::FilePart.new(io, "application/octet-stream", filename)
          }
          payload["checksum"] = checksum if checksum
          payload["checksum-algorithm"] = checksum_algorithm if checksum_algorithm

          response = upload_connection(timeout: timeout)
                     .post("/api2/json/nodes/#{node}/storage/#{storage}/upload", payload)
          handle_response(response)
        rescue Faraday::ConnectionFailed => e
          raise Error, "PVE connection failed: #{e.message}"
        rescue Faraday::TimeoutError => e
          raise Error, "PVE upload timed out: #{e.message}"
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

        # The node a UPID's task actually runs on — its second field, which is
        # authoritative and self-describing.
        #
        # This is NOT always the node the request targeted. PVE runs a storage
        # UPLOAD as an `imgcopy` task on the node that RECEIVES the API call (the
        # endpoint host), then copies the bytes to the target node's storage. So
        # uploading to /nodes/rna/storage/local/upload against a dna endpoint
        # returns UPID:dna:...:imgcopy:, and polling /nodes/rna/tasks/<that>
        # answers "no such task" — correctly, because the task belongs to dna.
        #
        # Observed on PVE 9.2.3 while provisioning the first instance onto a node
        # other than the API endpoint. It stayed invisible for as long as every
        # provision happened to target the endpoint host itself.
        def upid_node(upid)
          m = /\AUPID:([^:]+):/.match(upid.to_s)
          m && m[1].presence
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
          # Poll where the task actually LIVES, not where the request was aimed
          # (see upid_node). `node` remains the fallback for a malformed UPID so
          # this cannot be worse than the previous behaviour.
          node = upid_node(upid) || node
          not_ready = 0
          loop do
            begin
              status = get("/api2/json/nodes/#{node}/tasks/#{encoded}/status")
            rescue Error => e
              # A just-returned UPID isn't always immediately queryable: PVE can
              # briefly answer 400 "no such task" before the worker registers the
              # task. Tolerate a bounded burst of that at the start rather than
              # failing the whole operation; any other error (auth/rate-limit/…)
              # or persistence past the grace window propagates unchanged.
              raise unless task_not_yet_registered?(e)
              not_ready += 1
              raise if not_ready > TASK_NOT_READY_MAX_RETRIES
              raise TaskTimeoutError, "Timed out after #{timeout}s waiting for #{upid}" if monotonic_now > deadline
              sleep(poll_every)
              next
            end
            not_ready = 0
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

        # True for the transient PVE 400 "no such task" a freshly-returned UPID
        # can produce before the task registers — safe to keep polling on.
        def task_not_yet_registered?(error)
          error.message.to_s.match?(/no such task/i)
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

        # Separate connection for multipart uploads: the :multipart middleware
        # must be registered (it isn't on the JSON/url_encoded `connection`), and
        # the read timeout is much larger to accommodate streaming a whole disk
        # image. Not memoized — each upload gets a fresh, correctly-sized conn.
        def upload_connection(timeout:)
          Faraday.new(url: @endpoint, ssl: { verify: @verify_ssl }) do |f|
            f.request :multipart
            f.request :url_encoded
            f.response :json, content_type: /\bjson$/
            f.headers["Authorization"] = "PVEAPIToken=#{@token_id}=#{@token_secret}"
            f.headers["Accept"] = "application/json"
            f.options.timeout = timeout
            f.options.open_timeout = @connect_timeout
            f.adapter Faraday.default_adapter
          end
        end
      end
    end
  end
end
