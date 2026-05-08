# frozen_string_literal: true

require "faraday"
require "json"

module System
  module Providers
    module ProCloud
      # Thin Vultr API v2 client. Wraps Faraday with bearer-token auth,
      # JSON encoding/decoding, and a small surface limited to the
      # operations ProCloudProvider exercises.
      #
      # Errors are surfaced as typed exceptions so the calling adapter
      # can map them onto the BaseProvider error family rather than
      # leaking Faraday internals.
      class ApiClient
        DEFAULT_BASE_URL = "https://api.vultr.com"
        API_PREFIX = "/v2"
        DEFAULT_TIMEOUT  = 60
        OPEN_TIMEOUT     = 10

        class Error < StandardError
          attr_reader :status, :body

          def initialize(message, status: nil, body: nil)
            super(message)
            @status = status
            @body = body
          end
        end

        class AuthenticationError < Error; end
        class RateLimitError < Error; end
        class NotFoundError < Error; end
        class ServerError < Error; end

        def initialize(api_key:, base_url: DEFAULT_BASE_URL, logger: nil)
          raise ArgumentError, "api_key is required" if api_key.nil? || api_key.to_s.strip.empty?
          @api_key = api_key
          @base_url = base_url
          @logger = logger || (defined?(Rails) ? Rails.logger : nil)
        end

        # POST /v2/instances
        # @param body [Hash] required keys :region, :plan, :os_id; optional :label,
        #   :hostname, :user_data, :sshkey_id, :tags, :enable_ipv6
        # @return [Hash] parsed JSON `instance` payload
        def create_instance(body)
          response = request(:post, "#{API_PREFIX}/instances", body: body)
          extract!(response, key: "instance")
        end

        # DELETE /v2/instances/:id
        # @return [true] on success or already-gone (404 swallowed by caller as no-op)
        def delete_instance(instance_id)
          response = request(:delete, "#{API_PREFIX}/instances/#{instance_id}")
          # Vultr returns 204 No Content on success.
          handle_status!(response)
          true
        end

        # POST /v2/instances/:id/start
        def start_instance(instance_id)
          response = request(:post, "#{API_PREFIX}/instances/#{instance_id}/start")
          handle_status!(response)
          true
        end

        # POST /v2/instances/:id/halt
        def stop_instance(instance_id)
          response = request(:post, "#{API_PREFIX}/instances/#{instance_id}/halt")
          handle_status!(response)
          true
        end

        # GET /v2/instances/:id
        # @return [Hash] parsed `instance` payload
        def get_instance(instance_id)
          response = request(:get, "#{API_PREFIX}/instances/#{instance_id}")
          extract!(response, key: "instance")
        end

        private

        attr_reader :api_key, :base_url, :logger

        def connection
          @connection ||= Faraday.new(url: base_url) do |f|
            f.request :json
            f.headers["Authorization"] = "Bearer #{api_key}"
            f.headers["Accept"]        = "application/json"
            f.options.timeout      = DEFAULT_TIMEOUT
            f.options.open_timeout = OPEN_TIMEOUT
            f.adapter Faraday.default_adapter
          end
        end

        def request(method, path, body: nil, query: {})
          connection.public_send(method, path) do |req|
            req.params.update(query) if query && !query.empty?
            req.body = body if body
          end
        rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
          raise ServerError.new("Vultr request failed: #{e.class} - #{e.message}")
        end

        # Map HTTP status to typed error families. 2xx returns silently.
        def handle_status!(response)
          status = response.status
          return if status.between?(200, 299)

          body = parse_body(response)
          message = error_message(body) || "Vultr API returned HTTP #{status}"

          case status
          when 401, 403
            raise AuthenticationError.new(message, status: status, body: body)
          when 404
            raise NotFoundError.new(message, status: status, body: body)
          when 429
            raise RateLimitError.new(message, status: status, body: body)
          when 500..599
            raise ServerError.new(message, status: status, body: body)
          else
            raise Error.new(message, status: status, body: body)
          end
        end

        # Pull a top-level key (e.g., "instance") from the parsed body
        # after asserting a 2xx status.
        def extract!(response, key:)
          handle_status!(response)
          body = parse_body(response)
          return {} if body.nil?
          body.is_a?(Hash) ? (body[key] || body) : body
        end

        def parse_body(response)
          raw = response.body
          return raw if raw.is_a?(Hash) || raw.is_a?(Array)
          return nil if raw.nil? || raw.to_s.strip.empty?
          JSON.parse(raw.to_s)
        rescue JSON::ParserError
          nil
        end

        def error_message(body)
          return nil unless body.is_a?(Hash)
          body["error"] || body["message"]
        end
      end
    end
  end
end
